//
//  main.m
//  GmuxBrightness
//
//  Created by Andrey Filipenkov on 23.03.2024.
//

#import "AppDelegate.h"

@import Cocoa;

int main(int argc, const char* argv[]) {
    [NSApplication sharedApplication];
    __auto_type appDelegate = [AppDelegate new];
    NSApp.delegate = appDelegate;

    return NSApplicationMain(argc, argv);
}
