//
//  ToucherShim.swift
//  MaaPlugin
//
//  `Toucher.touchcam` with the same signature and phase handling as PlayTools'
//  Toucher.swift, which is what the vendored Core/MaaTools.swift calls.
//
//  PlayTools' implementation also drives its debug overlay and optional touch
//  logging; neither exists in a plugin, so only the injection path is kept.
//
//  Touches are delivered through the `PTFakeMetaTouch` class that the injected
//  PlayTools.framework already provides. PlayTools ships no Swift module (its
//  `Modules` directory is empty), so there is nothing to `import` or link
//  against; the class is an Objective-C class and therefore reachable through
//  the runtime, exactly like `dlsym("_OBJC_CLASS_$_PTFakeMetaTouch")` would be.
//  The lookup is resolved once and cached.
//

import UIKit

final class Toucher {
    static weak var keyWindow: UIWindow?
    static weak var keyView: UIView?

    /// Whether PlayTools' touch injector is present in this process.
    static var isAvailable: Bool { PTFakeMetaTouchBridge.isAvailable }

    /// Same semantics as PlayTools: on `.began` a touch id is allocated, on
    /// `.ended` it is released (set to nil), and `point` is in window
    /// coordinates, i.e. already divided by the screen scale by the caller.
    static func touchcam(point: CGPoint, phase: UITouch.Phase, tid: inout Int?,
                         actionName _: String, keyName _: String) {
        if phase == .began {
            if tid != nil {
                return
            }
            tid = -1
            keyWindow = currentKeyWindow()
            keyView = keyWindow?.hitTest(point, with: nil)
        } else if tid == nil {
            return
        }

        guard let window = keyWindow, let view = keyView else {
            MaaPluginDebug.log("touchcam: no window/view for phase \(phase.rawValue)")
            tid = nil
            return
        }

        tid = PTFakeMetaTouchBridge.fakeTouch(id: tid ?? -1,
                                              point: point,
                                              phase: phase,
                                              window: window,
                                              view: view)

        if tid ?? -1 < 0 {
            tid = nil
        }
    }

    private static func currentKeyWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }
}

/// Runtime bridge to PlayTools' `PTFakeMetaTouch`
/// (`+fakeTouchId:AtPoint:withTouchPhase:inWindow:onView:`).
private enum PTFakeMetaTouchBridge {
    private static let className = "PTFakeMetaTouch"
    private static let selector = NSSelectorFromString("fakeTouchId:AtPoint:withTouchPhase:inWindow:onView:")
    private static var didLogMissingClass = false

    private typealias Function = @convention(c) (AnyObject, Selector, Int, CGPoint, Int, UIWindow, UIView) -> Int

    /// `NSClassFromString` is the lookup the Objective-C runtime is meant to be
    /// used with, but it is not free, so resolve the IMP once and keep it.
    private static var cachedFunction: Function?
    private static var cachedClass: AnyObject?

    static var isAvailable: Bool {
        NSClassFromString(className) != nil
    }

    static func fakeTouch(id: Int, point: CGPoint, phase: UITouch.Phase,
                          window: UIWindow, view: UIView) -> Int {
        if let function = cachedFunction, let touchClass = cachedClass {
            return function(touchClass, selector, id, point, phase.rawValue, window, view)
        }

        guard let touchClass = NSClassFromString(className),
              let method = class_getClassMethod(touchClass, selector) else {
            if !didLogMissingClass {
                didLogMissingClass = true
                NSLog("[MaaPlugin] PTFakeMetaTouch is unavailable; is PlayTools injected into this app?")
            }
            return -1
        }

        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        cachedClass = touchClass
        cachedFunction = function
        MaaPluginDebug.log("touch bridge: resolved PTFakeMetaTouch")
        return function(touchClass, selector, id, point, phase.rawValue, window, view)
    }
}
