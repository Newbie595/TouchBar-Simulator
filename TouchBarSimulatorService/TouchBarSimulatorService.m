//
//  TouchBarSimulatorService.m
//  TouchBarSimulatorService
//
//  Jeremy 于 2020-08-15 创建。
//

#import <AppKit/AppKit.h>
#import <MetalKit/MetalKit.h>
#import <CoreImage/CoreImage.h>
#import <dlfcn.h>
#import "TouchBarSimulatorService.h"
#import "DFRFoundation.h"

// 新版 macOS SDK 将 CGDisplayStreamStart/Stop 标记为不可用，
// 但 DFRFoundation 仍会返回 CGDisplayStreamRef。运行时解析旧接口；
// 如果将来系统彻底移除它们，就返回错误供恢复逻辑处理。
static CGError TBSDisplayStreamCall(const char *symbol, CGDisplayStreamRef stream) {
    CGError (*function)(CGDisplayStreamRef) = dlsym(RTLD_DEFAULT, symbol);
    return function ? function(stream) : kCGErrorFailure;
}

typedef struct {
    simd_float2 inSize;
    simd_float2 outSize;
} UpscalerArgs;


@interface TouchBarSimulatorStreamView : NSView
@property (assign) DFRTouchBarSimulator *simulator;
@end

@implementation TouchBarSimulatorStreamView

- (void)mouseEvent:(NSEvent *)event {
    if (!self.simulator) return;

    // 先扣除窗口边框，再将视图坐标缩放到模拟器的 1004×30 点坐标系。
    // 如果先缩放窗口坐标，调整窗口大小后点击位置会偏移。
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];
    NSSize size = self.bounds.size;
    if (size.width <= 0 || size.height <= 0) return;
    location.x = location.x * 1004.0 / size.width;
    location.y = location.y * 30.0 / size.height;

    DFRTouchBarSimulatorPostEventWithMouseActivity(self.simulator, event.type, location);
}

- (void)mouseDown:(NSEvent *)event {
    [self mouseEvent:event];
}

- (void)mouseUp:(NSEvent *)event {
    [self mouseEvent:event];
}

- (void)mouseDragged:(NSEvent *)event {
    [self mouseEvent:event];
}

- (void)mouseEntered:(NSEvent *)event {
    [self mouseEvent:event];
}

- (void)mouseMoved:(NSEvent *)event {
    [self mouseEvent:event];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    self.wantsLayer = YES;
    self.layer.backgroundColor = NSColor.clearColor.CGColor;
    return self;
}

@end

@interface TouchBarSimulatorService () <MTKViewDelegate>
@property CGDisplayStreamRef touchBarStream;
@property DFRTouchBarSimulator *simulator;
@property (nonatomic, strong) TouchBarSimulatorStreamView *streamView;
@property (nonatomic,strong) MTKView *mtlView;
@property (nonatomic,strong) id<MTLDevice> device;
@property (nonatomic,strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic,strong) MTLRenderPipelineDescriptor *renderPipelineDesc;
@property (nonatomic, strong) id<MTLFunction> upscaler;
@property (nonatomic, strong) id<MTLFunction> filter;
@property (nonatomic, strong) id<MTLFunction> applySmoothing;
@property IOSurfaceRef surface;
@property (assign) NSUInteger streamGeneration;
@property (assign) NSUInteger streamRetryCount;
@property (assign) BOOL viewVisible;
@property (assign) BOOL workspaceSleeping;
@property (assign) BOOL waitingForFirstFrame;
@end

@implementation TouchBarSimulatorService

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)drawableSize {}

- (void)drawInMTKView:(MTKView *)view {
    // 显示回调暂时持有待绘制的 IOSurface。绘制时接管所有权，
    // 避免 Metal 处理完成前被更新的画面覆盖。
    IOSurfaceRef surface = NULL;
    @synchronized (self) {
        surface = _surface;
        _surface = NULL;
    }
    if (!surface) return;
    
    size_t surfaceWidth = IOSurfaceGetWidth(surface);
    size_t surfaceHeight = IOSurfaceGetHeight(surface);

    MTLTextureDescriptor *newTextureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:surfaceWidth height:surfaceHeight mipmapped:NO];
    [newTextureDescriptor setUsage:MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite];
    
    
    id<MTLTexture> newTexture = [_device newTextureWithDescriptor:newTextureDescriptor iosurface:surface plane:0];
    if (!newTexture || !view.currentDrawable || !view.currentRenderPassDescriptor) {
        CFRelease(surface);
        return;
    }
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    if (!commandBuffer) {
        CFRelease(surface);
        return;
    }

    id<MTLComputeCommandEncoder> commandEncoder = [commandBuffer computeCommandEncoder];

    id<MTLComputePipelineState> pipelineState = [_device newComputePipelineStateWithFunction:_filter error:nil];
    [commandEncoder setComputePipelineState:pipelineState];
    [commandEncoder setTexture:newTexture atIndex:0];
    MTLSize threadGroupCount = MTLSizeMake(8, 6, 1);
    MTLSize threadGroups = MTLSizeMake(surfaceWidth / threadGroupCount.width, surfaceHeight / threadGroupCount.height, 1);
    [commandEncoder dispatchThreadgroups:threadGroups threadsPerThreadgroup:threadGroupCount];

    pipelineState = [_device newComputePipelineStateWithFunction:_applySmoothing error:nil];
    [commandEncoder setComputePipelineState:pipelineState];
    [commandEncoder setTexture:newTexture atIndex:0];
    [commandEncoder setTexture:newTexture atIndex:1];
    threadGroupCount = MTLSizeMake(8, 6, 1);
    threadGroups = MTLSizeMake(surfaceWidth / threadGroupCount.width, surfaceHeight / threadGroupCount.height, 1);
    [commandEncoder dispatchThreadgroups:threadGroups threadsPerThreadgroup:threadGroupCount];

//    float outWidth = surfaceWidth * 2;// _mtlView.frame.size.width * 4;
//    float outHeight = surfaceHeight * 2;//_mtlView.frame.size.height * 4;
//
//    UpscalerArgs args = {
//        .inSize = { (float)surfaceWidth, (float)surfaceHeight },
//        .outSize = { outWidth, outHeight },
//    };
//
//    MTLTextureDescriptor *finalTextureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:outWidth height:outHeight mipmapped:NO];
//    [finalTextureDescriptor setUsage:MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite];
//    finalTextureDescriptor.width = outWidth;
//    finalTextureDescriptor.height = outHeight;
//    finalTextureDescriptor.storageMode = MTLStorageModePrivate;
//    id<MTLTexture> finalTexture = [_device newTextureWithDescriptor:finalTextureDescriptor];
//
//    pipelineState = [_device newComputePipelineStateWithFunction:_upscaler error:nil];
//    commandEncoder = [commandBuffer computeCommandEncoder];
//    [commandEncoder setComputePipelineState:pipelineState];
//    [commandEncoder setTexture:newTexture atIndex:0];
//    [commandEncoder setTexture:finalTexture atIndex:1];
//    [commandEncoder setBytes:&args length:sizeof(UpscalerArgs) atIndex:0];
//    threadGroupCount = MTLSizeMake(8, 6, 1);
//    threadGroups = MTLSizeMake(outWidth / threadGroupCount.width, outHeight / threadGroupCount.height, 1);
//    [commandEncoder dispatchThreadgroups:threadGroups threadsPerThreadgroup:threadGroupCount];
    
    [commandEncoder endEncoding];

    id <MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:_mtlView.currentRenderPassDescriptor];
    id <MTLRenderPipelineState> state = [_device newRenderPipelineStateWithDescriptor:_renderPipelineDesc error:NULL];
    [renderEncoder setRenderPipelineState:state];
    [renderEncoder setFragmentTexture:newTexture atIndex:0];
    [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [renderEncoder endEncoding];
    [commandBuffer presentDrawable:_mtlView.currentDrawable];
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completedBuffer) {
        (void)completedBuffer;
        // 提交命令后 GPU 可能仍在读取此帧，完成回调中再释放。
        CFRelease(surface);
    }];
    [commandBuffer commit];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.device = MTLCreateSystemDefaultDevice();
    
    self.mtlView = [[MTKView alloc] initWithFrame:self.view.frame device:self.device];
    self.mtlView.layer.backgroundColor = NSColor.clearColor.CGColor;
    self.mtlView.layer.opaque = NO;
    self.mtlView.clearColor = MTLClearColorMake(0, 0, 0, 0);
    self.mtlView.delegate = self;
    self.mtlView.framebufferOnly = NO;
    self.mtlView.autoResizeDrawable = YES;
    self.mtlView.enableSetNeedsDisplay = YES;
    self.mtlView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;

    self.commandQueue = [self.device newCommandQueue];
    self.mtlView.frame = NSMakeRect(0, 0, 1004, 30);
    [self.view addSubview:_mtlView];
    
    [_mtlView setTranslatesAutoresizingMaskIntoConstraints:NO];
    [_mtlView addConstraint:[NSLayoutConstraint
                                      constraintWithItem:_mtlView
                                      attribute:NSLayoutAttributeHeight
                                      relatedBy:NSLayoutRelationEqual
                                      toItem:_mtlView
                                      attribute:NSLayoutAttributeWidth
                                      multiplier:(_mtlView.frame.size.height / _mtlView.frame.size.width)
                                      constant:0]];
    
    MTKView *mv = self.mtlView;
    NSDictionary *dict = NSDictionaryOfVariableBindings(mv);
    NSArray *constraintsArray = [NSLayoutConstraint constraintsWithVisualFormat:@"H:|-0-[mv]-0-|"
                                                                        options:0
                                                                        metrics:nil
                                                                          views:dict];

    [self.view addConstraints:constraintsArray];
    [NSLayoutConstraint activateConstraints:constraintsArray];
    [self.view layoutSubtreeIfNeeded];

    id <MTLLibrary> lib = [_device newDefaultLibraryWithBundle:[NSBundle bundleForClass:[TouchBarSimulatorService class]] error:nil];
    _renderPipelineDesc = [MTLRenderPipelineDescriptor new];
    _renderPipelineDesc.rasterSampleCount = 1;
    _renderPipelineDesc.alphaToCoverageEnabled = YES;
    _renderPipelineDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    _renderPipelineDesc.vertexFunction = [lib newFunctionWithName:@"vertexShader"];
    _renderPipelineDesc.fragmentFunction = [lib newFunctionWithName:@"fragmentShader"];
    

    _upscaler = [lib newFunctionWithName:@"BicubicMain"];
    _filter = [lib newFunctionWithName:@"removeBlackColor"];
    _applySmoothing = [lib newFunctionWithName:@"smoothEdges"];

    
    self.streamView = [[TouchBarSimulatorStreamView alloc] initWithFrame:NSMakeRect(0, 0, 1004, 30)];
    [self.view addSubview:self.streamView];
    self.streamView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    // 即使远端视图控制器仍在运行，休眠也可能让显示流和模拟器失效。
    // 因此将它们视为需要按需重建的短期资源。
    NSNotificationCenter *workspaceNotifications = [NSWorkspace sharedWorkspace].notificationCenter;
    [workspaceNotifications addObserver:self selector:@selector(workspaceWillSleep:)
                                  name:NSWorkspaceWillSleepNotification object:nil];
    [workspaceNotifications addObserver:self selector:@selector(workspaceDidWake:)
                                  name:NSWorkspaceDidWakeNotification object:nil];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    self.viewVisible = YES;
    self.streamRetryCount = 0;
    [self startTouchBarStream];
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    self.viewVisible = NO;
    [self stopTouchBarStream];
}

- (void)dealloc {
    [[NSWorkspace sharedWorkspace].notificationCenter removeObserver:self];
    [self stopTouchBarStream];
}

- (void)stopTouchBarStream {
    // 停止前先让旧回调失效；异步到达的停止帧不能在休眠或退出时重启显示流。
    self.streamGeneration += 1;
    self.waitingForFirstFrame = NO;
    if (self.touchBarStream) {
        TBSDisplayStreamCall("CGDisplayStreamStop", self.touchBarStream);
        CFRelease(self.touchBarStream);
        self.touchBarStream = NULL;
    }
    self.streamView.simulator = nil;
    if (self.simulator) {
        DFRTouchBarSimulatorInvalidate(self.simulator);
        self.simulator = nil;
    }
    @synchronized (self) {
        if (_surface) {
            CFRelease(_surface);
            _surface = NULL;
        }
    }
    // 隐藏最后一帧，避免旧触控栏布局看起来仍可点击。
    self.mtlView.hidden = YES;
}

- (void)scheduleStreamRetryForGeneration:(NSUInteger)generation {
    if (generation != self.streamGeneration || self.workspaceSleeping || !self.viewVisible) return;
    [self stopTouchBarStream];
    if (self.streamRetryCount++ >= 5) {
        NSLog(@"Touch Bar stream did not recover after five retries");
        return;
    }
    NSUInteger nextGeneration = self.streamGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self && nextGeneration == self.streamGeneration) [self startTouchBarStream];
    });
}

- (void)startTouchBarStream {
    if (!self.viewVisible || self.workspaceSleeping || self.touchBarStream) return;
    self.simulator = DFRTouchBarSimulatorCreate(DFRTouchBarSecondGeneration, nil,
                                               DFRTouchBarSecondGeneration);
    DFRTouchBar *touchBar = self.simulator ? DFRTouchBarSimulatorGetTouchBar(self.simulator) : nil;
    if (!touchBar) {
        NSLog(@"Touch Bar simulator is unavailable");
        [self scheduleStreamRetryForGeneration:self.streamGeneration];
        return;
    }
    self.streamView.simulator = self.simulator;
    NSUInteger generation = self.streamGeneration;
    self.waitingForFirstFrame = YES;
    __weak typeof(self) weakSelf = self;
    self.touchBarStream = DFRTouchBarCreateDisplayStream(touchBar, 0, dispatch_get_main_queue(),
        ^(CGDisplayStreamFrameStatus status, uint64_t displayTime,
          IOSurfaceRef _Nullable frameSurface, CGDisplayStreamUpdateRef _Nullable updateRef) {
            (void)displayTime;
            (void)updateRef;
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || generation != self.streamGeneration) return;
            if (status == kCGDisplayStreamFrameStatusStopped) {
                [self scheduleStreamRetryForGeneration:generation];
                return;
            }
            // 空闲或空白帧属于正常通知，但不包含可绘制的 IOSurface。
            if (status != kCGDisplayStreamFrameStatusFrameComplete || !frameSurface) return;
            @synchronized (self) {
                IOSurfaceRef previous = self->_surface;
                self->_surface = (IOSurfaceRef)CFRetain(frameSurface);
                if (previous) CFRelease(previous);
            }
            self.waitingForFirstFrame = NO;
            self.streamRetryCount = 0;
            self.mtlView.hidden = NO;
            self.mtlView.needsDisplay = YES;
        });
    CGError startError = self.touchBarStream ?
        TBSDisplayStreamCall("CGDisplayStreamStart", self.touchBarStream) : kCGErrorFailure;
    if (startError != kCGErrorSuccess) {
        NSLog(@"Touch Bar display stream failed to start (CGError %d)", startError);
        [self scheduleStreamRetryForGeneration:generation];
        return;
    }
    // 唤醒后显示流可能报告启动成功，却始终不送来完整画面。
    // 只在首帧到达前重试；后续画面静止属于正常情况。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self && generation == self.streamGeneration && self.waitingForFirstFrame) {
            NSLog(@"Touch Bar display stream delivered no frame after start");
            [self scheduleStreamRetryForGeneration:generation];
        }
    });
}

- (void)workspaceWillSleep:(NSNotification *)notification {
    self.workspaceSleeping = YES;
    [self stopTouchBarStream];
}

- (void)workspaceDidWake:(NSNotification *)notification {
    self.workspaceSleeping = NO;
    self.streamRetryCount = 0;
    [self stopTouchBarStream];
    NSUInteger generation = self.streamGeneration;
    __weak typeof(self) weakSelf = self;
    // 触控栏服务可能在工作区唤醒通知之后才完成恢复，稍后再启动。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self && generation == self.streamGeneration) [self startTouchBarStream];
    });
}
@end
