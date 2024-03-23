//
//  main.m
//  GmuxBrightness
//
//  Created by Andrey Filipenkov on 23.03.2024.
//

#import "AppDelegate.h"

@import Cocoa;

#include <stdio.h>

int main(int argc, const char* argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Pass path to chipsec.kext on the command line");
        return 1;
    }

    [NSApplication sharedApplication];
    __auto_type appDelegate = [AppDelegate new];
    NSApp.delegate = appDelegate;

    return NSApplicationMain(argc, argv);
}
