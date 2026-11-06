//
//  MaaAppKit.h
//  MaaPlugin
//
//  Mac Catalyst ships no AppKit SDK, but AppKit is always present in a Catalyst
//  process (the window itself is an NSWindow / UINSWindow). These C entry points
//  are implemented in MaaAppKit.m, which declares the two AppKit classes it
//  needs locally; Swift just calls the functions, so there is no runtime class
//  or selector lookup on that side.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *_Nullable MaaAppKitWindowTitle(void);
FOUNDATION_EXPORT void MaaAppKitSetWindowTitle(NSString *title);

NS_ASSUME_NONNULL_END
