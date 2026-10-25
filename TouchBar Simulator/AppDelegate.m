//
//  AppDelegate.m
//  TouchBar Simulator
//
//  Created by Jeremy on 8/15/20.
//

#import <ViewBridge/ViewBridge.h>
#import <unistd.h>
#import "AppDelegate.h"

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
@property (assign) BOOL sessionWasInactive;
@property (assign) BOOL restartPending;
@property (assign) NSUInteger sessionGeneration;
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

    // 只在本应用亲历锁屏或屏幕休眠后重启，避免登录启动时形成重启循环。
    NSNotificationCenter *notifications = NSWorkspace.sharedWorkspace.notificationCenter;
    [notifications addObserver:self selector:@selector(sessionDidResignActive:)
                         name:NSWorkspaceSessionDidResignActiveNotification object:nil];
    [notifications addObserver:self selector:@selector(sessionDidResignActive:)
                         name:NSWorkspaceScreensDidSleepNotification object:nil];
    [notifications addObserver:self selector:@selector(sessionDidBecomeActive:)
                         name:NSWorkspaceSessionDidBecomeActiveNotification object:nil];
    
    NSRemoteView *remoteView = [[NSRemoteView alloc] initWithFrame: CGRectMake(0, 0, 1004, 30)];
    [remoteView setSynchronizesImplicitAnimations:NO];
    [remoteView setServiceName:@"com.github.jslegendre.TouchBarSimulatorService"];
    [remoteView setServiceSubclassName:@"TouchBarSimulatorService"];
    [remoteView advanceToRunPhaseIfNeeded:^(NSError *err){
        dispatch_async(dispatch_get_main_queue(), ^(){
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

- (void)sessionDidResignActive:(NSNotification *)notification {
    self.sessionWasInactive = YES;
    self.restartPending = NO;
    self.sessionGeneration += 1;
}

- (void)sessionDidBecomeActive:(NSNotification *)notification {
    if (!self.sessionWasInactive || self.restartPending) return;
    self.sessionWasInactive = NO;
    self.restartPending = YES;
    NSUInteger generation = ++self.sessionGeneration;

    // 等解锁界面的显示状态切回桌面，再启动新进程。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        if (generation != self.sessionGeneration || self.sessionWasInactive) return;
        [self restartAfterUnlock];
    });
}

- (void)restartAfterUnlock {
    // 辅助进程等待旧进程退出，避免新旧 XPC 实例同时连接 Touch Bar。
    // 应用路径作为独立参数传入 shell，不拼进命令文本。
    NSTask *helper = [NSTask new];
    helper.launchPath = @"/bin/sh";
    helper.arguments = @[@"-c",
                         @"while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open -n -a \"$2\"",
                         @"touchbar-relauncher",
                         [NSString stringWithFormat:@"%d", getpid()],
                         NSBundle.mainBundle.bundlePath];
    NSError *error = nil;
    if (![helper launchAndReturnError:&error]) {
        NSLog(@"无法在解锁后重新启动 Touch Bar Simulator：%@", error);
        self.restartPending = NO;
        return;
    }
    NSLog(@"会话解锁后正在重新启动 Touch Bar Simulator");
    [NSApp terminate:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    [[NSUserDefaults standardUserDefaults] setObject:self.window.stringWithSavedFrame forKey:@"savedWindowFrame"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [(NSRemoteViewController *)self.window.contentViewController disconnect];
}


@end
