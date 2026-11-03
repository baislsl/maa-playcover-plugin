//
//  MaaPlugin-Bridging-Header.h
//  MaaPlugin
//
//  PlayTools' own files are compiled against its umbrella header, which pulls in
//  UIKit; that is why Hguandl/MaaTools.swift can reference UIApplication and
//  UIWindowScene without an `import UIKit` of its own. Mirror that here so the
//  vendored file stays byte-identical, and expose the vendored Metal hooks.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "Hguandl/MetalCaptureHook.h"
