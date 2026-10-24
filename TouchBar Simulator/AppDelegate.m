//
//  AppDelegate.m
//  TouchBar Simulator
//
//  Jeremy 于 2020-08-15 创建。
//

#import <ViewBridge/ViewBridge.h>
#import <IOSurface/IOSurface.h>
#import <dlfcn.h>
#import <os/log.h>
#import "AppDelegate.h"

// 公共 SDK 未声明这些触控栏与显示流接口。运行时解析私有符号，
// 以便系统版本移除接口时记录错误，而不是在启动阶段直接崩溃。
typedef CGDisplayStreamRef (*TBSCreatePhysicalStreamFunction)(int, dispatch_queue_t,
                                                              CGDisplayStreamFrameAvailableHandler);
typedef CGError (*TBSDisplayStreamFunction)(CGDisplayStreamRef);
typedef void (*TBSPostTouchBarEventFunction)(NSEventType, CGPoint);

static void *TBSPrivateFramework(NSString *name) {
    NSString *path = [NSString stringWithFormat:@"/System/Library/PrivateFrameworks/%@.framework/%@", name, name];
    return dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
}

static TBSDisplayStreamFunction TBSStreamFunction(const char *name) {
    return dlsym(RTLD_DEFAULT, name);
}

static BOOL TBSFirstFrameContainsVisiblePixels(IOSurfaceRef surface) {
    // 故障复现时，WindowServer 返回的 2008×60 画面全部为黑色，
    // 但实体触控栏仍显示控制区。显示流启动成功、收到帧都不足以证明恢复；
    // 必须等到首帧出现非黑色像素，才把它作为可用画面。
    if (IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL) != kIOReturnSuccess) return YES;
    size_t width = IOSurfaceGetWidth(surface);
    size_t height = IOSurfaceGetHeight(surface);
    size_t bytesPerRow = IOSurfaceGetBytesPerRow(surface);
    size_t bytesPerElement = IOSurfaceGetBytesPerElement(surface);
    const uint8_t *base = IOSurfaceGetBaseAddress(surface);
    BOOL visible = NO;
    if (base && bytesPerElement >= 3 && bytesPerRow >= width * bytesPerElement) {
        for (size_t y = 0; y < height && !visible; y += 4) {
            for (size_t x = 0; x < width; x += 8) {
                const uint8_t *pixel = base + y * bytesPerRow + x * bytesPerElement;
                if (pixel[0] || pixel[1] || pixel[2]) { visible = YES; break; }
            }
        }
    } else {
        // 如果私有接口改变像素格式，不要仅因当前检查方法无法识别格式就丢弃画面。
        visible = YES;
    }
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    return visible;
}

@interface TBSPhysicalTouchBarView : NSView
@property (copy) void (^refreshHandler)(void);
@end

@implementation TBSPhysicalTouchBarView

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)postTouchBarEvent:(NSEvent *)event {
    // 显示流断开时不向实体触控栏发送用户看不见的点击。
    if (!self.layer.contents) return;
    if (self.bounds.size.width <= 0 || self.bounds.size.height <= 0) return;
    static TBSPostTouchBarEventFunction postEvent = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *framework = TBSPrivateFramework(@"DFRFoundation");
        postEvent = framework ? dlsym(framework, "DFRFoundationPostEventWithMouseActivity") : NULL;
    });
    if (!postEvent) return;

    // 将缩放后的窗口坐标换算回触控栏的 1004×30 点坐标系。
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    point.x *= 1004.0 / self.bounds.size.width;
    point.y *= 30.0 / self.bounds.size.height;
    if (event.type == NSEventTypeLeftMouseDown) {
        os_log(OS_LOG_DEFAULT, "Physical Touch Bar click at (%.1f, %.1f), Accessibility trusted: %{public}s",
               point.x, point.y, AXIsProcessTrusted() ? "YES" : "NO");
    }
    postEvent(event.type, point);
}

- (void)mouseDown:(NSEvent *)event { [self postTouchBarEvent:event]; }
- (void)mouseUp:(NSEvent *)event { [self postTouchBarEvent:event]; }
- (void)mouseDragged:(NSEvent *)event { [self postTouchBarEvent:event]; }
- (void)mouseEntered:(NSEvent *)event { [self postTouchBarEvent:event]; }
- (void)mouseMoved:(NSEvent *)event { [self postTouchBarEvent:event]; }

- (NSMenu *)menuForEvent:(NSEvent *)event {
    // 如果系统恢复私有显示流的时机发生变化，用户可以手动重连，
    // 不必强制退出整个应用。
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Touch Bar"];
    NSMenuItem *refresh = [[NSMenuItem alloc] initWithTitle:@"重新连接 Touch Bar"
                                                   action:@selector(refreshTouchBar:)
                                            keyEquivalent:@""];
    refresh.target = self;
    [menu addItem:refresh];
    return menu;
}

- (void)refreshTouchBar:(id)sender {
    if (self.refreshHandler) self.refreshHandler();
}

@end

@interface TBSimulatorPanel : NSPanel
@end

@implementation TBSimulatorPanel

- (BOOL)canBecomeKeyWindow {
    return NO;
}

- (BOOL)isResizable {
    return YES;
}

@end

@interface AppDelegate ()

@property (strong) IBOutlet NSPanel *window;
@property (strong) NSRemoteView *remoteView;
@property (assign) NSUInteger remoteViewGeneration;
@property (assign) NSUInteger remoteViewRetryCount;
@property (assign) BOOL hasPhysicalTouchBar;
@property (assign) BOOL workspaceSleeping;
@property CGDisplayStreamRef physicalStream;
@property (strong) TBSPhysicalTouchBarView *physicalView;
@property (strong) NSTextField *connectionLabel;
@property (assign) NSUInteger physicalStreamGeneration;
@property (assign) NSUInteger physicalStreamRetryCount;
@property (assign) BOOL waitingForFirstFrame;
@property (assign) BOOL loggedBlankFirstFrame;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {

    self.window.contentView.layer.backgroundColor = NSColor.clearColor.CGColor;

    self.window.contentAspectRatio = NSMakeSize(1014, 40);
    self.window.movableByWindowBackground = NO;
    self.window.contentView.wantsLayer = YES;
    self.window.level = kCGFloatingWindowLevel;
    
    NSString *savedWindowFrame = [[NSUserDefaults standardUserDefaults] objectForKey:@"savedWindowFrame"];
    if (savedWindowFrame) {
        [self.window setFrameFromString:savedWindowFrame];
    }
    
    NSNotificationCenter *workspaceNotifications = [NSWorkspace sharedWorkspace].notificationCenter;
    for (NSNotificationName name in @[NSWorkspaceWillSleepNotification,
                                      NSWorkspaceScreensDidSleepNotification]) {
        [workspaceNotifications addObserver:self selector:@selector(workspaceWillSleep:)
                                      name:name object:nil];
    }
    // 唤醒通知可能早于登录会话恢复。将三类通知合并处理，
    // 在 WindowServer 准备好后执行最后一次重连。
    for (NSNotificationName name in @[NSWorkspaceDidWakeNotification,
                                      NSWorkspaceScreensDidWakeNotification,
                                      NSWorkspaceSessionDidBecomeActiveNotification]) {
        [workspaceNotifications addObserver:self selector:@selector(workspaceDidWake:)
                                      name:name object:nil];
    }
    int (*getStatus)(void) = NULL;
    void *dfr = TBSPrivateFramework(@"DFRFoundation");
    if (dfr) getStatus = dlsym(dfr, "DFRGetStatus");
    self.hasPhysicalTouchBar = getStatus && (getStatus() & 0x01);
    if (self.hasPhysicalTouchBar) {
        // XPC 服务中的 DFRTouchBarSimulator 是独立实例，画面可能与实体栏不同。
        // 本机实测：主进程能取得实体画面，XPC 服务却只收到全黑画面。
        [self installPhysicalView];
        [self startPhysicalStream];
    } else {
        // 没有实体触控栏的 Mac 继续使用原有的第二代模拟触控栏。
        [self installRemoteView];
    }
}

- (void)installPhysicalView {
    NSView *contentView = self.window.contentView;
    self.physicalView = [[TBSPhysicalTouchBarView alloc] initWithFrame:NSInsetRect(contentView.bounds, 5, 5)];
    self.physicalView.wantsLayer = YES;
    self.physicalView.layer.contentsGravity = kCAGravityResize;
    self.physicalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.physicalView.hidden = NO;
    __weak typeof(self) weakSelf = self;
    self.physicalView.refreshHandler = ^{
        __strong typeof(weakSelf) self = weakSelf;
        self.physicalStreamRetryCount = 0;
        [self stopPhysicalStream];
        [self startPhysicalStream];
    };
    [contentView addSubview:self.physicalView];

    self.connectionLabel = [NSTextField labelWithString:@"正在连接实体 Touch Bar…"];
    self.connectionLabel.font = [NSFont systemFontOfSize:12];
    self.connectionLabel.textColor = NSColor.secondaryLabelColor;
    self.connectionLabel.alignment = NSTextAlignmentCenter;
    self.connectionLabel.frame = NSInsetRect(contentView.bounds, 5, 5);
    self.connectionLabel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [contentView addSubview:self.connectionLabel positioned:NSWindowBelow relativeTo:self.physicalView];
}

- (void)stopPhysicalStream {
    // 停止显示流前先让旧回调失效；旧帧或停止回调不能恢复休眠前的画面。
    self.physicalStreamGeneration += 1;
    self.waitingForFirstFrame = NO;
    self.loggedBlankFirstFrame = NO;
    if (self.physicalStream) {
        TBSDisplayStreamFunction stopStream = TBSStreamFunction("CGDisplayStreamStop");
        if (stopStream) stopStream(self.physicalStream);
        CFRelease(self.physicalStream);
        self.physicalStream = NULL;
    }
    self.physicalView.layer.contents = nil;
    self.physicalView.hidden = NO;
    self.connectionLabel.hidden = NO;
}

- (void)schedulePhysicalStreamRetryForGeneration:(NSUInteger)generation {
    if (generation != self.physicalStreamGeneration || self.workspaceSleeping) return;
    [self stopPhysicalStream];
    if (self.physicalStreamRetryCount++ >= 5) {
        os_log_error(OS_LOG_DEFAULT, "Physical Touch Bar stream did not recover after five retries");
        self.connectionLabel.stringValue = @"实体 Touch Bar 连接失败，解锁或重新打开后重试";
        return;
    }
    NSUInteger nextGeneration = self.physicalStreamGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self && nextGeneration == self.physicalStreamGeneration) [self startPhysicalStream];
    });
}

- (void)startPhysicalStream {
    if (!self.hasPhysicalTouchBar || self.workspaceSleeping || self.physicalStream) return;
    static TBSCreatePhysicalStreamFunction createStream = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *skyLight = TBSPrivateFramework(@"SkyLight");
        createStream = skyLight ? dlsym(skyLight, "SLSDFRDisplayStreamCreate") : NULL;
    });
    TBSDisplayStreamFunction startStream = TBSStreamFunction("CGDisplayStreamStart");
    if (!createStream || !startStream) {
        os_log_error(OS_LOG_DEFAULT, "Physical Touch Bar display stream functions unavailable");
        [self schedulePhysicalStreamRetryForGeneration:self.physicalStreamGeneration];
        return;
    }

    NSUInteger generation = self.physicalStreamGeneration;
    self.waitingForFirstFrame = YES;
    self.loggedBlankFirstFrame = NO;
    __weak typeof(self) weakSelf = self;
    self.physicalStream = createStream(0, dispatch_get_main_queue(),
        ^(CGDisplayStreamFrameStatus status, uint64_t time, IOSurfaceRef surface,
          CGDisplayStreamUpdateRef update) {
            (void)time; (void)update;
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || generation != self.physicalStreamGeneration) return;
            if (status == kCGDisplayStreamFrameStatusStopped) {
                [self schedulePhysicalStreamRetryForGeneration:generation];
                return;
            }
            if (status != kCGDisplayStreamFrameStatusFrameComplete || !surface) return;
            if (self.waitingForFirstFrame) {
                if (!TBSFirstFrameContainsVisiblePixels(surface)) {
                    if (!self.loggedBlankFirstFrame) {
                        os_log_error(OS_LOG_DEFAULT, "Physical Touch Bar stream returned a blank first frame; waiting before retry");
                        self.loggedBlankFirstFrame = YES;
                    }
                    return;
                }
                os_log(OS_LOG_DEFAULT, "Physical Touch Bar stream received its first visible frame");
            }
            self.waitingForFirstFrame = NO;
            self.physicalStreamRetryCount = 0;
            self.physicalView.layer.contents = (__bridge id)surface;
            self.physicalView.hidden = NO;
            self.connectionLabel.hidden = YES;
        });
    CGError error = self.physicalStream ? startStream(self.physicalStream) : kCGErrorFailure;
    if (error != kCGErrorSuccess) {
        os_log_error(OS_LOG_DEFAULT, "Physical Touch Bar stream failed to start (CGError %d)", error);
        [self schedulePhysicalStreamRetryForGeneration:generation];
        return;
    }

    // 唤醒后显示流可能启动成功却没有有效画面。只检查首帧；
    // 后续内容保持静止属于正常情况，不应因此反复重启。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self && generation == self.physicalStreamGeneration && self.waitingForFirstFrame) {
            os_log_error(OS_LOG_DEFAULT, "Physical Touch Bar stream delivered no frame after start");
            [self schedulePhysicalStreamRetryForGeneration:generation];
        }
    });
}

- (void)installRemoteView {
    self.remoteViewGeneration += 1;
    NSUInteger generation = self.remoteViewGeneration;

    [self.remoteView removeFromSuperview];
    NSRemoteView *remoteView = [[NSRemoteView alloc] initWithFrame:CGRectMake(0, 0, 1004, 30)];
    self.remoteView = remoteView;
    [remoteView setSynchronizesImplicitAnimations:NO];
    [remoteView setServiceName:@"com.github.Newbie595.TouchBarSimulatorService"];
    [remoteView setServiceSubclassName:@"TouchBarSimulatorService"];
    [remoteView advanceToRunPhaseIfNeeded:^(NSError *err){
        dispatch_async(dispatch_get_main_queue(), ^(){
            // 后续唤醒或重试可能已经替换此连接，忽略过期回调。
            if (generation != self.remoteViewGeneration) return;
            if (err) {
                NSLog(@"Touch Bar view service connection failed: %@", err);
                if (self.remoteViewRetryCount++ < 3) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        if (generation == self.remoteViewGeneration) [self installRemoteView];
                    });
                }
                return;
            }

            self.remoteViewRetryCount = 0;
            NSView *contentView = self.window.contentView;
            [contentView addSubview:remoteView];

            [remoteView setTranslatesAutoresizingMaskIntoConstraints:NO];
            [remoteView setShouldMaskToBounds:NO];
            [[remoteView layer] setAllowsEdgeAntialiasing:YES];

            NSDictionary *dict = NSDictionaryOfVariableBindings(remoteView);
            NSArray *constraintsArray = [NSLayoutConstraint constraintsWithVisualFormat:@"H:|-5-[remoteView]-5-|"
                                                                                options:0
                                                                                metrics:nil
                                                                                  views:dict];

            constraintsArray = [constraintsArray arrayByAddingObjectsFromArray:
                                [NSLayoutConstraint constraintsWithVisualFormat:@"V:|-5-[remoteView]-5-|"
                                                                       options:0
                                                                       metrics:nil
                                                                         views:dict]];
            [contentView addConstraints:constraintsArray];
            [NSLayoutConstraint activateConstraints:constraintsArray];

            [contentView layoutSubtreeIfNeeded];
            
        });
    }];
}

- (void)workspaceWillSleep:(NSNotification *)notification {
    self.workspaceSleeping = YES;
    if (self.hasPhysicalTouchBar) [self stopPhysicalStream];
}

- (void)workspaceDidWake:(NSNotification *)notification {
    os_log(OS_LOG_DEFAULT, "Touch Bar recovery requested by %{public}@", notification.name);
    self.workspaceSleeping = NO;
    if (self.hasPhysicalTouchBar) {
        self.physicalStreamRetryCount = 0;
        self.connectionLabel.stringValue = @"正在重新连接实体 Touch Bar…";
        [self stopPhysicalStream];
        NSUInteger generation = self.physicalStreamGeneration;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (self && generation == self.physicalStreamGeneration) [self startPhysicalStream];
        });
        return;
    }

    // 备用的 ViewBridge 连接在休眠后也可能失效，需要重新建立。
    self.remoteView.hidden = YES;
    self.remoteViewGeneration += 1;
    NSUInteger generation = self.remoteViewGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != self.remoteViewGeneration) return;
        self.remoteViewRetryCount = 0;
        [self installRemoteView];
    });
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    [self stopPhysicalStream];
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    [[NSUserDefaults standardUserDefaults] setObject:self.window.stringWithSavedFrame forKey:@"savedWindowFrame"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self.remoteView removeFromSuperview];
    self.remoteView = nil;
}


@end
