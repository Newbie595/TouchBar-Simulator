//
//  TouchBarSimulatorService.m
//  TouchBarSimulatorService
//
//  Created by Jeremy on 8/15/20.
//

#import <AppKit/AppKit.h>
#import <MetalKit/MetalKit.h>
#import <CoreImage/CoreImage.h>
#import <dlfcn.h>
#import "TouchBarSimulatorService.h"
#import "DFRFoundation.h"

// Recent macOS SDKs mark CGDisplayStreamStart/Stop unavailable. DFRFoundation
// still hands us a CGDisplayStreamRef, so resolve the legacy entry points at
// runtime and report failure if a future macOS removes them entirely.
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

    // First remove the window's border/padding, then scale from the current
    // view size to the simulator's 1004 x 30 coordinate space. Scaling window
    // coordinates before conversion displaced clicks after resizing.
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
    // The display callback owns the pending IOSurface. Transfer that ownership
    // to this draw so a newer frame cannot overwrite it before Metal is done.
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
        // The GPU may still be reading this frame after commit returns.
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

    // The stream and simulator are short-lived: sleep can invalidate both even
    // while this view controller remains loaded in the remote service.
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
    // Invalidate callbacks before stopping: a final "stopped" frame may arrive
    // asynchronously and must not restart a stream during sleep or shutdown.
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
    // Hide the last frame so an old Touch Bar layout cannot look interactive.
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
            // Idle/blank frames are valid notifications but have no IOSurface.
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
    // A stream can report a successful start but never deliver a frame after
    // wake. Retry only until its first complete frame; static content later is
    // normal and must not trigger a watchdog restart.
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
    // The Touch Bar service can become ready after the workspace wake event.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self && generation == self.streamGeneration) [self startTouchBarStream];
    });
}
@end
