//
//  MaaAppKit.m
//  MaaPlugin
//
//  AppKit has no Mac Catalyst SDK, so the two classes used here are declared
//  locally. This translation unit imports Foundation only (never UIKit), which
//  keeps these declarations from clashing with the AppKit module that UIKit
//  drags in elsewhere. The symbols are bound at runtime against the AppKit that
//  is already loaded in the process (`-undefined dynamic_lookup`).
//

#import "MaaAppKit.h"

@interface NSApplication : NSObject

+ (NSApplication *)sharedApplication;

@property (readonly, copy) NSArray *windows;

@end

@interface NSWindow : NSObject

@property (copy) NSString *title;

@end

static NSWindow *_Nullable mainWindow(void) {
    NSArray *windows = NSApplication.sharedApplication.windows;
    return windows.count > 0 ? windows[0] : nil;
}

NSString *_Nullable MaaAppKitWindowTitle(void) {
    return mainWindow().title;
}

void MaaAppKitSetWindowTitle(NSString *title) {
    mainWindow().title = title;
}
