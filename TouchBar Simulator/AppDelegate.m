//
//  AppDelegate.m
//  TouchBar Simulator
//
//  Created by Jeremy on 8/15/20.
//

#import <ViewBridge/ViewBridge.h>
#import <IOSurface/IOSurface.h>
#import <dlfcn.h>
#import <os/log.h>
#import "AppDelegate.h"

// The public SDK deliberately omits these Touch Bar and display-stream entry
// points. Resolve them at runtime so a future macOS can fail gracefully.
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
    // In the reproduced failure WindowServer returns a valid 2008x60 surface
    // filled entirely with black while the hardware still shows its control
    // strip. A successful CGDisplayStreamStart and frame callback are therefore
    // insufficient: accept the stream only once real pixels are present.
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
        // If the private API changes its pixel layout, don't discard frames
        // solely because this diagnostic cannot understand their format.
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
    // Do not send invisible clicks into the hardware while the stream is down.
    if (!self.layer.contents) return;
    if (self.bounds.size.width <= 0 || self.bounds.size.height <= 0) return;
    static TBSPostTouchBarEventFunction postEvent = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *framework = TBSPrivateFramework(@"DFRFoundation");
        postEvent = framework ? dlsym(framework, "DFRFoundationPostEventWithMouseActivity") : NULL;
    });
    if (!postEvent) return;

    // Map the resized window back to the Touch Bar's 1004 x 30 point space.
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
    // A manual reconnect lets the user recover without force-quitting if a
    // future macOS changes when its private Touch Bar stream becomes ready.
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
    // A wake notification can precede the restored login session. Debounce
    // all three so the final reconnect happens after WindowServer is ready.
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
        // On this Mac, the independent DFRTouchBarSimulator in the XPC service
        // can diverge from the real hardware. The host process receives the
        // real SLSDFR display; the XPC service receives all-black surfaces.
        [self installPhysicalView];
        [self startPhysicalStream];
    } else {
        // Preserve the original second-generation simulated Touch Bar for
        // Macs that have no built-in Touch Bar.
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
    // Invalidate queued callbacks before stopping. A stale frame or "stopped"
    // callback from the old stream must not revive the pre-sleep picture.
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

    // A successful start can still deliver no image after wake. Static Touch
    // Bar content later is normal, so only watch for the first complete frame.
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
            // A newer wake/retry may already have replaced this connection.
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

    // The fallback ViewBridge connection can also become stale while asleep.
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
