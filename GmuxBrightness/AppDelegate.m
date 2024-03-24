//
//  AppDelegate.m
//  GmuxBrightness
//
//  Created by Andrey Filipenkov on 23.03.2024.
//

#import "AppDelegate.h"

@import CoreGraphics;

#include <fcntl.h>
#include <sys/ioctl.h>


#define GMUX_PORT_BASE 0x700
#define GMUX_PORT_BRIGHTNESS 0x74

#define CHIPSEC_DEVICE "/dev/chipsec"

#define KARABINER_APPLE_DISPLAY_BRIGHTNESS_INCREMENT_KEYCODE 0x90 // apple_display_brightness_increment
#define KARABINER_APPLE_DISPLAY_BRIGHTNESS_DECREMENT_KEYCODE 0x91 // apple_display_brightness_decrement

// https://github.com/chipsec/chipsec/blob/1.10.6/drivers/osx/chipsec/chipsec_ioctl.h
#define CHIPSEC_RDIO 0x7
#define CHIPSEC_WRIO 0x8
#define CHIPSEC_IOCTL_BASE 'p'
#define CHIPSEC_IOC_RDIO _IOWR(CHIPSEC_IOCTL_BASE, CHIPSEC_RDIO, io_msg_t)
#define CHIPSEC_IOC_WRIO _IOWR(CHIPSEC_IOCTL_BASE, CHIPSEC_WRIO, io_msg_t)

typedef struct _io_msg_t {
    uint64_t port;
    uint64_t size;
    uint64_t value;
} io_msg_t;


@interface AppDelegate ()

@property (nonatomic, assign) NSUInteger currentBrightnessIndex;
@property (nonatomic, copy) NSArray<NSNumber*>* brightnessLevels;

@property (nonatomic, assign) CFMachPortRef tapPort;
@property (nonatomic, assign) CFRunLoopSourceRef tapPortSource;

@property (nonatomic, assign) int chipsecDeviceFd;
@property (nonatomic, strong) NSStatusItem* statusItem;

- (void)setBrightnessIndex:(NSUInteger)newBrightnessIndex;

@end


CGEventRef tapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void* userInfo) {
    __auto_type self = (__bridge AppDelegate*)userInfo;

    if (type != kCGEventKeyDown) {
        CGEventTapEnable(self.tapPort, true);
        return event;
    }

    switch (CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode)) {
        case KARABINER_APPLE_DISPLAY_BRIGHTNESS_INCREMENT_KEYCODE:
            if (self.currentBrightnessIndex < self.brightnessLevels.count - 1) {
                [self setBrightnessIndex:self.currentBrightnessIndex + 1];
            }
            break;
        case KARABINER_APPLE_DISPLAY_BRIGHTNESS_DECREMENT_KEYCODE:
            if (self.currentBrightnessIndex > 0) {
                [self setBrightnessIndex:self.currentBrightnessIndex - 1];
            }
            break;
        default:
            break;
    }
    return event;
}


@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)aNotification {
    // values obtained from MacBookPro6,2
    self.brightnessLevels = @[
        @0,
        @2897,
        @3460,
        @4345,
        @5391,
        @6759,
        @8368,
        @10540,
        @13356,
        @16333,
        @20115,
        @24862,
        @30655,
        @37977,
        @46989,
        @58334,
        @72575,
        @82311, // max, can also be obtained from I/O port 0x770
    ];

    [self loadChipsecKext:YES completion:^(NSTask* _Nonnull task) {
        if (task.terminationStatus == 0) {
            [self performInitialSetup];
            return;
        }

        __auto_type errorOutputData = [[task.standardError fileHandleForReading] readDataToEndOfFileAndReturnError:NULL];
        __auto_type errorOutput = [[NSString alloc] initWithData:errorOutputData encoding:NSUTF8StringEncoding];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showKextAlertWithErrorText:errorOutput];
            [NSApp terminate:nil];
        });
    }];

    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.image = [NSImage imageWithSystemSymbolName:@"sun.max" accessibilityDescription:nil];

    self.statusItem.menu = [[NSMenu alloc] initWithTitle:@""];
    [self.statusItem.menu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@""];
}

- (void)applicationWillTerminate:(NSNotification*)aNotification {
    [self loadChipsecKext:NO completion:nil];

    if (self.tapPortSource) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), self.tapPortSource, kCFRunLoopCommonModes);
        CFRelease(self.tapPortSource);
    }
    if (self.tapPort)
        CFRelease(self.tapPort);
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication*)app {
    return YES;
}

#pragma mark - Private

- (void)loadChipsecKext:(BOOL)shouldLoad completion:(nullable void(^)(NSTask* _Nonnull task))completionHandler {
    __auto_type task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/kmutil"];
    task.arguments = @[
        shouldLoad ? @"load" : @"unload",
        @"-p",
        NSProcessInfo.processInfo.arguments[1],
    ];
    task.terminationHandler = completionHandler;
    task.standardError = completionHandler ? [NSPipe new] : nil;
    [task launchAndReturnError:NULL];
}

- (void)showKextAlertWithErrorText:(NSString*)errorText {
    __auto_type alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleCritical;
    alert.messageText = @"Error calling kmutil. Are you running the app as root?";
    alert.informativeText = errorText;
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (void)setCurrentBrightnessIndex:(NSUInteger)newIndex {
    if (_currentBrightnessIndex == newIndex)
        return;
    _currentBrightnessIndex = newIndex;

    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusItem.button.title = [NSString stringWithFormat:@"%lu/%lu", newIndex, self.brightnessLevels.count - 1];
    });
}

#pragma mark Initial setup

- (void)performInitialSetup {
    self.chipsecDeviceFd = open(CHIPSEC_DEVICE, O_RDWR | O_APPEND);
    [self setInitialBrightness];
    [self setupKeyTap];

    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(displayDidWake)
                                                           name:NSWorkspaceScreensDidWakeNotification object:nil];
}

- (void)setupKeyTap {
    self.tapPort = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                    CGEventMaskBit(kCGEventKeyDown), tapCallback, (__bridge void*)(self));
    if (!self.tapPort)
        return;

    self.tapPortSource = CFMachPortCreateRunLoopSource(NULL, self.tapPort, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), self.tapPortSource, kCFRunLoopCommonModes);
}

- (void)setInitialBrightness {
    const __auto_type lastBrightnessIndex = self.brightnessLevels.count - 1;
    const __auto_type currentBrightness = [self currentBrightness];

    const __auto_type detectedIndex = [self.brightnessLevels indexOfObjectPassingTest:^BOOL(NSNumber* _Nonnull obj, NSUInteger idx, BOOL* _Nonnull stop) {
        if (idx == lastBrightnessIndex)
            return YES;
        return obj.unsignedIntegerValue <= currentBrightness && currentBrightness < self.brightnessLevels[idx + 1].unsignedIntegerValue;;
    }];
    switch (detectedIndex) {
        case 0:
            // don't consider screen to be turned off
            self.currentBrightnessIndex = 1;
            break;
        case NSNotFound:
            self.currentBrightnessIndex = lastBrightnessIndex;
            break;
        default:
            self.currentBrightnessIndex = detectedIndex;
            break;
    }
}

#pragma mark ioctl

- (uint64_t)sendIoctlRequest:(unsigned long)request withValue:(uint64_t)value {
    io_msg_t io = {.port = GMUX_PORT_BASE + GMUX_PORT_BRIGHTNESS, .size = 4, .value = value};
    ioctl(self.chipsecDeviceFd, request, &io);
    return io.value;
}

- (void)setBrightnessIndex:(NSUInteger)newBrightnessIndex {
    self.currentBrightnessIndex = newBrightnessIndex;
    const __auto_type brightness = self.brightnessLevels[self.currentBrightnessIndex].unsignedIntValue;
    [self sendIoctlRequest:CHIPSEC_IOC_WRIO withValue:brightness];
}

- (uint64_t)currentBrightness {
    return [self sendIoctlRequest:CHIPSEC_IOC_RDIO withValue:0];
}

#pragma mark - Notifications

- (void)displayDidWake {
    // restore last brightness
    [self setBrightnessIndex:self.currentBrightnessIndex];
}

@end
