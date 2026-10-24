//
//  AppDelegate.m
//  TouchBar Simulator
//
//  Created by Jeremy on 8/15/20.
//

#import <ViewBridge/ViewBridge.h>
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
@property (strong) NSRemoteView *remoteView;
@property (assign) NSUInteger remoteViewGeneration;
@property (assign) NSUInteger remoteViewRetryCount;
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
    
    // The view service may have been disconnected while the display was asleep.
    // Recreate the connection after wake instead of leaving a frozen remote view.
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                           selector:@selector(workspaceDidWake:)
                                                               name:NSWorkspaceDidWakeNotification
                                                             object:nil];
    [self installRemoteView];
}

- (void)installRemoteView {
    self.remoteViewGeneration += 1;
    NSUInteger generation = self.remoteViewGeneration;

    [self.remoteView removeFromSuperview];
    NSRemoteView *remoteView = [[NSRemoteView alloc] initWithFrame:CGRectMake(0, 0, 1004, 30)];
    self.remoteView = remoteView;
    [remoteView setSynchronizesImplicitAnimations:NO];
    [remoteView setServiceName:@"com.github.jslegendre.TouchBarSimulatorService"];
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

- (void)workspaceDidWake:(NSNotification *)notification {
    // Give the WindowServer and the XPC service a moment to restore their displays.
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
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    [[NSUserDefaults standardUserDefaults] setObject:self.window.stringWithSavedFrame forKey:@"savedWindowFrame"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self.remoteView removeFromSuperview];
    self.remoteView = nil;
}


@end
