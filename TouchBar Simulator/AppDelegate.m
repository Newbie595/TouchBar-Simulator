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
#import <ServiceManagement/ServiceManagement.h>
#import "AppDelegate.h"

typedef NS_ENUM(NSInteger, TBSDockingMode) {
    TBSDockingModeFloating,
    TBSDockingModeTop,
    TBSDockingModeBottom,
};

static NSString *const TBSDockingModeKey = @"TBSDockingMode";
static NSString *const TBSDockingPaddingKey = @"TBSDockingPadding";
static NSString *const TBSWindowOpacityKey = @"TBSWindowOpacity";
static NSString *const TBSShowOnAllDesktopsKey = @"TBSShowOnAllDesktops";
static NSString *const TBSAutoHideKey = @"TBSAutoHide";
static NSString *const TBSFloatingFrameKey = @"TBSFloatingFrame";

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
@property (copy) void (^dockingHandler)(NSInteger mode);
@property (assign) TBSDockingMode dockingMode;
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
    // 右键提供与状态栏相同的停靠操作，便于窗口本身直接切换位置。
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Touch Bar"];
    for (NSInteger mode = TBSDockingModeFloating; mode <= TBSDockingModeBottom; mode++) {
        NSString *title = @[@"浮动", @"置顶", @"置底"][(NSUInteger)mode];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                     action:@selector(selectDockingFromMenu:)
                                              keyEquivalent:@""];
        item.target = self;
        item.tag = mode;
        item.state = mode == self.dockingMode ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:item];
    }
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *refresh = [[NSMenuItem alloc] initWithTitle:@"重新连接 Touch Bar"
                                                   action:@selector(refreshTouchBar:)
                                            keyEquivalent:@""];
    refresh.target = self;
    [menu addItem:refresh];
    return menu;
}

- (void)selectDockingFromMenu:(NSMenuItem *)item {
    if (self.dockingHandler) self.dockingHandler(item.tag);
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

@interface AppDelegate () <NSMenuDelegate>

@property (strong) IBOutlet NSPanel *window;
@property (strong) NSStatusItem *statusItem;
@property (strong) NSMenu *statusMenu;
@property (assign) NSWindowStyleMask floatingStyleMask;
@property (assign) TBSDockingMode dockingMode;
@property (assign) CGFloat dockingPadding;
@property (assign) BOOL applyingDocking;
@property (assign) BOOL autoHide;
@property (strong) NSTimer *autoHideTimer;
@property (assign) NSTimeInterval lastAutoShowTime;
@property (assign) NSUInteger sessionRecoveryGeneration;
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

    // 窗口位置和外观属于应用本身；切换显示流时不重建窗口。
    self.floatingStyleMask = self.window.styleMask;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.dockingMode = (TBSDockingMode)[defaults integerForKey:TBSDockingModeKey];
    if (self.dockingMode < TBSDockingModeFloating || self.dockingMode > TBSDockingModeBottom) {
        self.dockingMode = TBSDockingModeFloating;
    }
    self.dockingPadding = MIN(120, MAX(0, [defaults doubleForKey:TBSDockingPaddingKey]));
    self.window.alphaValue = MIN(1, MAX(0.5, [defaults objectForKey:TBSWindowOpacityKey] ?
                                           [defaults doubleForKey:TBSWindowOpacityKey] : 1));
    self.autoHide = [defaults boolForKey:TBSAutoHideKey];
    [self configureStatusItem];
    [self applyDesktopBehavior];
    [self applyDockingMode];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowDidMoveOrResize:)
                                                 name:NSWindowDidMoveNotification object:self.window];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowDidMoveOrResize:)
                                                 name:NSWindowDidResizeNotification object:self.window];
    
    NSNotificationCenter *workspaceNotifications = [NSWorkspace sharedWorkspace].notificationCenter;
    for (NSNotificationName name in @[NSWorkspaceWillSleepNotification,
                                      NSWorkspaceScreensDidSleepNotification,
                                      NSWorkspaceSessionDidResignActiveNotification]) {
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
    [workspaceNotifications addObserver:self selector:@selector(sessionDidBecomeActive:)
                                  name:NSWorkspaceSessionDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(screenParametersDidChange:)
                                                 name:NSApplicationDidChangeScreenParametersNotification object:nil];
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

- (void)configureStatusItem {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSImage *image = nil;
    if (@available(macOS 11.0, *)) {
        image = [NSImage imageWithSystemSymbolName:@"rectangle.on.rectangle"
                         accessibilityDescription:@"Touch Bar Simulator"];
    }
    if (image) self.statusItem.button.image = image;
    else self.statusItem.button.title = @"TB";
    self.statusItem.button.toolTip = @"Touch Bar Simulator (Newbie595)";
    self.statusMenu = [[NSMenu alloc] initWithTitle:@"Touch Bar Simulator"];
    self.statusMenu.delegate = self;
    self.statusItem.menu = self.statusMenu;
}

- (NSMenuItem *)addMenuItem:(NSString *)title action:(SEL)action checked:(BOOL)checked {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.state = checked ? NSControlStateValueOn : NSControlStateValueOff;
    [self.statusMenu addItem:item];
    return item;
}

- (void)addSliderWithValue:(CGFloat)value minimum:(CGFloat)minimum maximum:(CGFloat)maximum
                   action:(SEL)action {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 30)];
    NSSlider *slider = [[NSSlider alloc] initWithFrame:NSMakeRect(18, 5, 204, 20)];
    slider.minValue = minimum;
    slider.maxValue = maximum;
    slider.doubleValue = value;
    slider.target = self;
    slider.action = action;
    [container addSubview:slider];
    item.view = container;
    [self.statusMenu addItem:item];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu != self.statusMenu) return;
    [menu removeAllItems];
    [self addMenuItem:@"停靠位置" action:NULL checked:NO].enabled = NO;
    [self addMenuItem:@"浮动" action:@selector(selectFloating:) checked:self.dockingMode == TBSDockingModeFloating].indentationLevel = 1;
    [self addMenuItem:@"置顶" action:@selector(selectTop:) checked:self.dockingMode == TBSDockingModeTop].indentationLevel = 1;
    [self addMenuItem:@"置底" action:@selector(selectBottom:) checked:self.dockingMode == TBSDockingModeBottom].indentationLevel = 1;
    if (self.dockingMode != TBSDockingModeFloating) {
        [self addMenuItem:@"边距" action:NULL checked:NO].enabled = NO;
        [self addSliderWithValue:self.dockingPadding minimum:0 maximum:120 action:@selector(changePadding:)];
    }
    [self addMenuItem:@"不透明度" action:NULL checked:NO].enabled = NO;
    [self addSliderWithValue:self.window.alphaValue minimum:0.5 maximum:1 action:@selector(changeOpacity:)];
    [menu addItem:NSMenuItem.separatorItem];
    [self addMenuItem:@"显示或隐藏窗口" action:@selector(toggleWindow:) checked:NO];
    [self addMenuItem:@"重新连接 Touch Bar" action:@selector(reconnectTouchBar:) checked:NO];
    [self addMenuItem:@"截取实体触控栏" action:@selector(captureTouchBar:) checked:NO];
    [menu addItem:NSMenuItem.separatorItem];
    [self addMenuItem:@"在所有桌面显示" action:@selector(toggleAllDesktops:)
              checked:[NSUserDefaults.standardUserDefaults boolForKey:TBSShowOnAllDesktopsKey]];
    [self addMenuItem:@"靠边时自动隐藏／显示" action:@selector(toggleAutoHide:) checked:self.autoHide].enabled =
        self.dockingMode != TBSDockingModeFloating;
    if (@available(macOS 13.0, *)) {
        [self addMenuItem:@"登录时启动" action:@selector(toggleLaunchAtLogin:)
                  checked:SMAppService.mainAppService.status == SMAppServiceStatusEnabled];
    }
    [menu addItem:NSMenuItem.separatorItem];
    [self addMenuItem:@"退出 Touch Bar Simulator" action:@selector(quitApplication:) checked:NO];
}

- (void)saveFloatingFrame {
    if (self.dockingMode == TBSDockingModeFloating && !self.applyingDocking) {
        [NSUserDefaults.standardUserDefaults setObject:self.window.stringWithSavedFrame
                                                forKey:TBSFloatingFrameKey];
    }
}

- (void)applyDesktopBehavior {
    BOOL allDesktops = [NSUserDefaults.standardUserDefaults boolForKey:TBSShowOnAllDesktopsKey];
    self.window.collectionBehavior = NSWindowCollectionBehaviorTransient |
        NSWindowCollectionBehaviorIgnoresCycle |
        (allDesktops ? NSWindowCollectionBehaviorCanJoinAllSpaces : NSWindowCollectionBehaviorMoveToActiveSpace);
}

- (void)applyDockingMode {
    self.applyingDocking = YES;
    NSSize contentSize = self.window.contentView.bounds.size;
    if (self.dockingMode == TBSDockingModeFloating) {
        self.window.styleMask = self.floatingStyleMask;
        [self.window setContentSize:contentSize];
        NSString *frame = [NSUserDefaults.standardUserDefaults stringForKey:TBSFloatingFrameKey];
        if (frame.length > 0) [self.window setFrameFromString:frame];
    } else {
        self.window.styleMask = NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel |
                                NSWindowStyleMaskResizable;
        [self.window setContentSize:contentSize];
        [self repositionDockedWindow];
    }
    self.applyingDocking = NO;
    self.physicalView.dockingMode = self.dockingMode;
    [self updateAutoHideTimer];
    [self.window orderFront:nil];
}

- (void)repositionDockedWindow {
    if (self.dockingMode == TBSDockingModeFloating) return;
    NSScreen *screen = self.window.screen ?: NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    if (!screen) return;
    NSRect visible = screen.visibleFrame;
    NSRect frame = self.window.frame;
    frame.origin.x = NSMidX(visible) - frame.size.width / 2;
    frame.origin.y = self.dockingMode == TBSDockingModeTop ?
        NSMaxY(visible) - frame.size.height - self.dockingPadding :
        NSMinY(visible) + self.dockingPadding;
    [self.window setFrameOrigin:frame.origin];
}

- (void)selectDockingMode:(TBSDockingMode)mode {
    if (mode == self.dockingMode) return;
    [self saveFloatingFrame];
    self.dockingMode = mode;
    [NSUserDefaults.standardUserDefaults setInteger:mode forKey:TBSDockingModeKey];
    [self applyDockingMode];
}

- (void)selectFloating:(id)sender { [self selectDockingMode:TBSDockingModeFloating]; }
- (void)selectTop:(id)sender { [self selectDockingMode:TBSDockingModeTop]; }
- (void)selectBottom:(id)sender { [self selectDockingMode:TBSDockingModeBottom]; }

- (void)changePadding:(NSSlider *)sender {
    self.dockingPadding = sender.doubleValue;
    [NSUserDefaults.standardUserDefaults setDouble:self.dockingPadding forKey:TBSDockingPaddingKey];
    [self repositionDockedWindow];
}

- (void)changeOpacity:(NSSlider *)sender {
    self.window.alphaValue = sender.doubleValue;
    [NSUserDefaults.standardUserDefaults setDouble:sender.doubleValue forKey:TBSWindowOpacityKey];
}

- (void)toggleWindow:(id)sender {
    if (self.window.isVisible) [self.window orderOut:nil];
    else {
        // 用户主动显示窗口时保持可见，避免自动隐藏计时器马上将它收起。
        if (self.autoHide) {
            self.autoHide = NO;
            [NSUserDefaults.standardUserDefaults setBool:NO forKey:TBSAutoHideKey];
            [self updateAutoHideTimer];
        }
        self.lastAutoShowTime = NSDate.timeIntervalSinceReferenceDate;
        [self.window orderFront:nil];
    }
}

- (void)reconnectTouchBar:(id)sender {
    if (self.hasPhysicalTouchBar) {
        self.physicalStreamRetryCount = 0;
        [self stopPhysicalStream];
        [self startPhysicalStream];
    } else {
        self.remoteViewRetryCount = 0;
        [self installRemoteView];
    }
}

- (void)captureTouchBar:(id)sender {
    // 与 Command-Shift-6 相同，让 macOS 自己保存实体触控栏快照。
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, 0x58, true);
    CGEventRef up = CGEventCreateKeyboardEvent(NULL, 0x58, false);
    if (down && up) {
        CGEventSetFlags(down, kCGEventFlagMaskCommand | kCGEventFlagMaskShift);
        CGEventSetFlags(up, kCGEventFlagMaskCommand | kCGEventFlagMaskShift);
        CGEventPost(kCGHIDEventTap, down);
        CGEventPost(kCGHIDEventTap, up);
    }
    if (down) CFRelease(down);
    if (up) CFRelease(up);
}

- (void)toggleAllDesktops:(id)sender {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:![defaults boolForKey:TBSShowOnAllDesktopsKey] forKey:TBSShowOnAllDesktopsKey];
    [self applyDesktopBehavior];
}

- (void)toggleAutoHide:(id)sender {
    self.autoHide = !self.autoHide;
    [NSUserDefaults.standardUserDefaults setBool:self.autoHide forKey:TBSAutoHideKey];
    [self updateAutoHideTimer];
    if (!self.autoHide) [self.window orderFront:nil];
}

- (void)updateAutoHideTimer {
    [self.autoHideTimer invalidate];
    self.autoHideTimer = nil;
    if (!self.autoHide || self.dockingMode == TBSDockingModeFloating) return;
    self.lastAutoShowTime = NSDate.timeIntervalSinceReferenceDate;
    self.autoHideTimer = [NSTimer scheduledTimerWithTimeInterval:0.2 target:self
                                                        selector:@selector(checkAutoHide:)
                                                        userInfo:nil repeats:YES];
}

- (void)checkAutoHide:(NSTimer *)timer {
    NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
    if (!screen) return;
    NSPoint mouse = NSEvent.mouseLocation;
    NSRect visible = screen.visibleFrame;
    BOOL atEdge = mouse.x >= NSMinX(visible) && mouse.x <= NSMaxX(visible) &&
        (self.dockingMode == TBSDockingModeTop ? mouse.y >= NSMaxY(visible) - 2 :
                                                   mouse.y <= NSMinY(visible) + 2);
    if (!self.window.isVisible && atEdge) {
        [self repositionDockedWindow];
        self.lastAutoShowTime = NSDate.timeIntervalSinceReferenceDate;
        [self.window orderFront:nil];
    } else if (self.window.isVisible && !NSPointInRect(mouse, NSInsetRect(self.window.frame, -4, -4)) &&
               NSDate.timeIntervalSinceReferenceDate - self.lastAutoShowTime > 0.6) {
        [self.window orderOut:nil];
    }
}

- (void)toggleLaunchAtLogin:(id)sender API_AVAILABLE(macos(13.0)) {
    SMAppService *service = SMAppService.mainAppService;
    NSError *error = nil;
    BOOL success = service.status == SMAppServiceStatusEnabled ?
        [service unregisterAndReturnError:&error] : [service registerAndReturnError:&error];
    if (!success) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"无法更改登录启动设置";
        alert.informativeText = error.localizedDescription ?: @"请先将应用移到“应用程序”文件夹。";
        [alert runModal];
    }
}

- (void)windowDidMoveOrResize:(NSNotification *)notification {
    if (self.applyingDocking) return;
    if (self.dockingMode == TBSDockingModeFloating) [self saveFloatingFrame];
    else if ([notification.name isEqualToString:NSWindowDidResizeNotification]) [self repositionDockedWindow];
}

- (void)screenParametersDidChange:(NSNotification *)notification {
    [self repositionDockedWindow];
}

- (void)quitApplication:(id)sender { [NSApp terminate:nil]; }

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
    self.physicalView.dockingMode = self.dockingMode;
    self.physicalView.dockingHandler = ^(NSInteger mode) {
        __strong typeof(weakSelf) self = weakSelf;
        [self selectDockingMode:(TBSDockingMode)mode];
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
    // 私有接口有时持续返回黑帧。前几次快速重试，之后改为每 30 秒重试；
    // 不再永久停在失败画面，也不需要定时重启整个应用。
    self.physicalStreamRetryCount = MIN(self.physicalStreamRetryCount + 1, 6);
    NSTimeInterval delay = self.physicalStreamRetryCount < 6 ? 2 : 30;
    if (self.physicalStreamRetryCount == 6) {
        os_log_error(OS_LOG_DEFAULT, "Physical Touch Bar stream still blank; continuing slow retries");
        self.connectionLabel.stringValue = @"实体 Touch Bar 暂无画面，正在自动重连…";
    }
    NSUInteger nextGeneration = self.physicalStreamGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
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
    self.sessionRecoveryGeneration += 1;
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

- (void)sessionDidBecomeActive:(NSNotification *)notification {
    // WindowServer 可能先报告会话已解锁，随后才把实体触控栏从锁屏布局切回桌面。
    // 唤醒时立即重连一次，再在短暂延迟后重连一次，避免首帧仍是“使用触控 ID 解锁”。
    NSUInteger generation = ++self.sessionRecoveryGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self.sessionRecoveryGeneration || self.workspaceSleeping) return;
        os_log(OS_LOG_DEFAULT, "Touch Bar recovery after session became active");
        [self reconnectTouchBar:nil];
    });
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return NO;
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    [self stopPhysicalStream];
    [self.autoHideTimer invalidate];
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (self.dockingMode == TBSDockingModeFloating) [self saveFloatingFrame];
    NSString *floatingFrame = [NSUserDefaults.standardUserDefaults stringForKey:TBSFloatingFrameKey];
    if (floatingFrame) [NSUserDefaults.standardUserDefaults setObject:floatingFrame forKey:@"savedWindowFrame"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self.remoteView removeFromSuperview];
    self.remoteView = nil;
}


@end
