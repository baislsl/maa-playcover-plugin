//
//  AKInterfaceShim.swift
//  MaaPlugin
//
//  Stands in for `AKInterface.shared` — in PlayTools that is the instance of
//  AKInterface.bundle's `Plugin` implementation, which is built for macOS and
//  therefore uses AppKit (`NSApplication.shared.windows`).
//
//  A user plugin is built for Mac Catalyst, where AppKit is unavailable at
//  compile time, so window discovery is reimplemented on top of UIKit +
//  CGWindowList, and the title is written to the real NSWindow through the
//  Objective-C runtime (AppKit *is* loaded in a Catalyst process; addressing it
//  dynamically avoids the unavailable-at-compile-time restriction).
//
//  The capture flow — ScreenCaptureKit gate, sourceRect maths, CGWindowList
//  fallback — follows hguandl/PlayTools@6497f81 `AKPlugin.swift`.
//

import CoreGraphics
import Foundation
import OSLog
import ScreenCaptureKit
import UIKit

@MainActor
final class AKInterface {
    /// `MaaTools.swift` reaches this through optional chaining.
    static var shared: AKInterface? = AKInterface()

    /// Upper bound for a single ScreenCaptureKit grab. A window that is
    /// occluded, minimised or on another Space can leave
    /// `SCScreenshotManager` waiting for a frame that never comes, which used to
    /// wedge the whole connection until MaaEnd was restarted.
    private static let captureTimeout: TimeInterval = 1.5

    private let logger = Logger(subsystem: "io.playcover.MaaPlugin", category: "AKInterface")

    /// Mirrors `AKPluginLoader`'s gate in the fork: current-process
    /// ScreenCaptureKit capture is only used from iOS 18.2 (macOS 15.2) on.
    let sckAvailable: Bool

    // Window geometry is re-read from the window server only when the UIKit
    // window or its bounds change; the per-frame path must stay cheap.
    private weak var cachedWindow: UIWindow?
    private var cachedWindowBounds: CGRect = .zero
    private var cachedWindowID: CGWindowID?
    private var cachedFrame: CGRect = .zero
    private var cachedContent: CGRect = .zero
    private var cachedMetrics: (size: CGSize, scale: CGFloat)?
    // Enumerating shareable content is the expensive part of a grab, and the
    // window set rarely changes; caching it removed most of the per-frame cost
    // (and the spurious >1.5 s grabs that froze the stream).
    private var cachedShareable: AnyObject? // SCShareableContent, unavailable below 18.2
    private var cachedShareableAt: CFAbsoluteTime = 0
    private var lastGeometryCheck: CFAbsoluteTime = 0
    private var pendingFrame: CGRect = .zero
    private var pendingFrameSince: CFAbsoluteTime = 0
    private var pendingNative: CGSize = .zero
    private var pendingNativeSince: CFAbsoluteTime = 0
    private var lastLoggedGeometry = ""

    /// Last successfully captured frame. A capture that times out (occluded or
    /// minimised window) falls back to this instead of failing the request, which
    /// used to leave MaaEnd waiting on a frame that never arrived.
    private var lastFrame: CGImage?

    private static var titleRetryTask: Task<Void, Never>?

    private init() {
        if #available(macCatalyst 18.2, *) {
            sckAvailable = true
        } else {
            sckAvailable = false
        }
    }

    // MARK: - Window lookup

    private var keyWindow: UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }

    /// Frontmost window owned by this process, as reported by the window server.
    private func windowID() -> CGWindowID? {
        guard let infoList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
            as? [[CFString: Any]] else {
            logger.error("Cannot enumerate the windows of the app")
            return nil
        }
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        let candidates = infoList.filter { info in
            (info[kCGWindowOwnerPID] as? NSNumber)?.int32Value == pid
                && (info[kCGWindowLayer] as? NSNumber)?.intValue == 0
        }
        let largest = candidates.max { lhs, rhs in
            Self.windowArea(lhs) < Self.windowArea(rhs)
        }
        guard let number = largest?[kCGWindowNumber] as? NSNumber else {
            logger.error("Cannot find any window of the app")
            return nil
        }
        return CGWindowID(number.uint32Value)
    }

    private static func windowArea(_ info: [CFString: Any]) -> CGFloat {
        guard let dictionary = info[kCGWindowBounds] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dictionary) else {
            return 0
        }
        return bounds.width * bounds.height
    }

    private func windowBounds(windowID: CGWindowID) -> CGRect? {
        let infoList = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID)
        for info in infoList as? [[CFString: Any]] ?? [] {
            guard let number = info[kCGWindowNumber] as? NSNumber,
                  number.int32Value == Int32(windowID) else {
                continue
            }
            if let dictionary = info[kCGWindowBounds] as? NSDictionary {
                return CGRect(dictionaryRepresentation: dictionary)
            }
        }
        return nil
    }

    /// Window frame and content area in screen points.
    ///
    /// `UIWindow.bounds` is expressed in the app's (possibly scaled) iOS
    /// coordinate space, so only its aspect ratio is reused: the window server
    /// frame supplies the real size and the title bar is whatever sits above
    /// that content area.
    private func geometry() -> (id: CGWindowID, frame: CGRect, content: CGRect)? {
        guard let window = keyWindow else { return nil }
        let now = CFAbsoluteTimeGetCurrent()
        if cachedWindow === window, cachedWindowBounds == window.bounds,
           let id = cachedWindowID, now - lastGeometryCheck < 1.0 {
            return (id, cachedFrame, cachedContent)
        }
        lastGeometryCheck = now

        guard let id = windowID() else { return nil }
        let frame = windowBounds(windowID: id) ?? .zero
        let uiBounds = window.bounds

        var content = CGRect(origin: .zero, size: uiBounds.size)
        if frame.width > 0, frame.height > 0, uiBounds.width > 0, uiBounds.height > 0 {
            let height = min(frame.width * uiBounds.height / uiBounds.width, frame.height)
            content = CGRect(x: frame.minX, y: frame.maxY - height,
                             width: frame.width, height: height)
        }

        cachedWindow = window
        cachedWindowBounds = uiBounds
        cachedWindowID = id
        cachedFrame = frame
        cachedContent = content
        cachedMetrics = nil
        let description = "id=\(id) frame=\(frame) uiBounds=\(uiBounds) content=\(content)"
        if description != lastLoggedGeometry {
            lastLoggedGeometry = description
            MaaPluginDebug.log("geometry: \(description)")
        }
        return (id, frame, content)
    }

    var windowFrame: CGRect {
        geometry()?.frame ?? keyWindow?.frame ?? .zero
    }

    var windowContentRect: CGRect {
        geometry()?.content ?? keyWindow?.bounds ?? .zero
    }

    /// Pixel size of the game surface plus the factor that converts those pixels
    /// back into window points.
    ///
    /// PlayTools swizzles `UIScreen.nativeBounds` to the simulated device
    /// resolution (`PlayScreen.nativeBounds`). With `inverseScreenValues` on it
    /// reports that resolution portrait-first even for a landscape window, and
    /// `MaaTools` uses this size as the screenshot size — feeding it a portrait
    /// size stretched every frame vertically. Reconcile the orientation with the
    /// window here, and derive the touch scale from the same numbers so that
    /// `TUCH` coordinates still map back to window points.
    var screenMetrics: (size: CGSize, scale: CGFloat)? {
        guard let geometry = geometry(), let window = keyWindow,
              window.bounds.width > 0, window.bounds.height > 0 else {
            return nil
        }
        if let cachedMetrics {
            return cachedMetrics
        }

        let screen = window.windowScene?.screen
        let nativeScale = screen?.nativeScale ?? 1
        var native = screen?.nativeBounds.size ?? .zero
        if native.width <= 0 || native.height <= 0 {
            native = CGSize(width: window.bounds.width * nativeScale,
                            height: window.bounds.height * nativeScale)
        }

        // PlayTools installs its UIScreen swizzle a moment after the plugin
        // starts, so the first reads can still be the raw display size. Never
        // lock the protocol size from a value that is still moving.
        let now = CFAbsoluteTimeGetCurrent()
        if native != pendingNative {
            pendingNative = native
            pendingNativeSince = now
            MaaPluginDebug.log("screen metrics: native=\(native) settling")
            return nil
        }
        guard now - pendingNativeSince >= 1.0 else {
            MaaPluginDebug.log("screen metrics: waiting for native bounds to settle")
            return nil
        }

        // Orientation: prefer the size PlayCover has configured for this app —
        // the live window frame is still settling right after launch, and a
        // portrait decision there is what used to leave every frame stretched.
        let reference: CGSize
        if let configured = PlaySettings.shared.windowSize {
            reference = configured
        } else if let stable = stableWindowFrame(geometry.frame) {
            reference = stable.size
        } else {
            MaaPluginDebug.log("screen metrics: window frame not stable yet, deferring")
            return nil
        }
        if (native.width >= native.height) != (reference.width >= reference.height) {
            MaaPluginDebug.log("screen metrics: swapping \(native) to match \(reference)")
            native = CGSize(width: native.height, height: native.width)
        }

        // Last line of defence: the game's own coordinate space is what touches
        // are hit-tested in, so a landscape UI can never legitimately get a
        // portrait protocol size (that is exactly the stretched picture).
        let uiLandscape = window.bounds.width >= window.bounds.height
        if (native.width >= native.height) != uiLandscape {
            MaaPluginDebug.log("screen metrics: overriding \(native) to match uiBounds \(window.bounds.size)")
            native = CGSize(width: native.height, height: native.width)
        }

        // TUCH coordinates arrive in `native` space and must land in UIKit points.
        let scale = native.width / window.bounds.width
        guard scale > 0, scale.isFinite else { return nil }

        if abs(native.width / native.height - reference.width / reference.height) > 0.02 {
            MaaPluginDebug.log("""
                screen metrics: aspect mismatch native=\(native.width)x\(native.height) \
                window=\(reference.width)x\(reference.height)
                """)
        }
        MaaPluginDebug.log("screen metrics: native=\(native) reference=\(reference) uiBounds=\(window.bounds.size) scale=\(scale)")
        cachedMetrics = (native, scale)
        return (native, scale)
    }

    /// Returns the frame once it has been unchanged for a second, so callers do
    /// not act on the transient size PlayCover uses while opening the window.
    private func stableWindowFrame(_ frame: CGRect) -> CGRect? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let now = CFAbsoluteTimeGetCurrent()
        if frame != pendingFrame {
            pendingFrame = frame
            pendingFrameSince = now
            return nil
        }
        return now - pendingFrameSince >= 1.0 ? frame : nil
    }

    // MARK: - Title

    /// `MaaTools.initialize()` waits for this to become non-nil before it starts
    /// the server, so fall back to the app's display name once a window exists.
    var windowTitle: String? {
        get {
            if let title = Self.appKitWindowTitle(), !title.isEmpty {
                return title
            }
            guard let scene = keyWindow?.windowScene else { return nil }
            if let title = scene.title, !title.isEmpty {
                return title
            }
            return Self.displayName
        }
        set {
            guard let newValue else { return }
            Self.publish(title: newValue)
        }
    }

    /// Writes the title to the real `NSWindow` and keeps re-applying it for a
    /// while: PlayCover may re-set the window title on activation/relaunch of
    /// its own state, which used to erase the `[localhost:port]` suffix.
    private static func publish(title: String) {
        titleRetryTask?.cancel()
        titleRetryTask = Task { @MainActor in
            for attempt in 0 ..< 30 {
                if currentAppKitTitle() != title {
                    applyTitle(title, attempt: attempt)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            MaaPluginDebug.log("title: stopped watching after 30 s")
        }
    }

    private static func currentAppKitTitle() -> String? {
        appKitWindow()?.value(forKey: "title") as? String
    }

    private static func applyTitle(_ title: String, attempt: Int) {
        guard let window = appKitWindow() else {
            MaaPluginDebug.log("title: no NSWindow (NSApplication present: \(NSClassFromString("NSApplication") != nil))")
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.title = title
            return
        }
        let before = window.value(forKey: "title") as? String
        window.setValue(title, forKey: "title")
        let after = window.value(forKey: "title") as? String
        MaaPluginDebug.log("title: attempt=\(attempt) '\(before ?? "nil")' -> '\(after ?? "nil")' window=\(type(of: window))")
    }

    private static var displayName: String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? (Bundle.main.bundleIdentifier ?? "")
    }

    /// The app's `NSWindow`, resolved through the ObjC runtime because AppKit is
    /// unavailable to Mac Catalyst code at compile time.
    private static func appKitWindow() -> NSObject? {
        guard let cls = NSClassFromString("NSApplication") else { return nil }
        let selector = NSSelectorFromString("sharedApplication")
        guard let method = class_getClassMethod(cls, selector) else { return nil }
        typealias Shared = @convention(c) (AnyObject, Selector) -> AnyObject
        let application = unsafeBitCast(method_getImplementation(method), to: Shared.self)(cls, selector)
        guard let windows = (application as? NSObject)?.value(forKey: "windows") as? [NSObject] else {
            return nil
        }
        return windows.first
    }

    private static func appKitWindowTitle() -> String? {
        appKitWindow()?.value(forKey: "title") as? String
    }

    // MARK: - Capture

    nonisolated private func cgWindowImage(_ geometry: (id: CGWindowID, frame: CGRect, content: CGRect)) -> CGImage? {
        var bounds = geometry.frame
        let size = geometry.content.size
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        guard size.height <= bounds.height else {
            return nil
        }
        let titlebarHeight = bounds.height - size.height
        bounds.origin.y += titlebarHeight
        bounds.size = size
        return CGWindowListCreateImage(bounds, .optionIncludingWindow, geometry.id,
                                       [.bestResolution, .boundsIgnoreFraming, .shouldBeOpaque])
    }

    @available(macCatalyst 18.2, *)
    private func shareableWindow(_ windowID: CGWindowID) async throws -> SCWindow? {
        let now = CFAbsoluteTimeGetCurrent()
        if let content = cachedShareable as? SCShareableContent, now - cachedShareableAt < 5,
           let window = content.windows.first(where: { $0.windowID == windowID }) {
            return window
        }
        let content = try await SCShareableContent.currentProcess
        cachedShareable = content
        cachedShareableAt = now
        return content.windows.first(where: { $0.windowID == windowID })
    }

    @available(macCatalyst 18.2, *)
    private func captureImage(_ windowID: CGWindowID,
                              content: CGRect) async throws -> CGImage? {
        guard let window = try await shareableWindow(windowID) else {
            logger.error("Cannot find the shareable content of the window")
            MaaPluginDebug.log("capture: window \(windowID) missing from shareable content")
            cachedShareable = nil
            return nil
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let info = SCShareableContent.info(for: filter)

        // `sourceRect` is relative to the *whole window* (title bar included),
        // not to the screen. Two things follow:
        //   * the origin must be window-relative (using the screen frame origin
        //     shifted the region off the window and left black borders);
        //   * SCK's `contentRect` covers the frame, i.e. the title bar too, so
        //     the region has to be offset down by the title bar height or the
        //     captured picture carries PlayCover's title bar with it.
        let windowSize = info.contentRect.size
        let contentSize = CGSize(width: min(content.size.width, windowSize.width),
                                 height: min(content.size.height, windowSize.height))
        guard contentSize.width >= 1, contentSize.height >= 1 else {
            logger.error("Invalid content size \(String(describing: contentSize), privacy: .public)")
            return nil
        }
        let titleBarHeight = max(0, windowSize.height - contentSize.height)
        MaaPluginDebug.log("capture: window=\(windowSize) content=\(contentSize) titleBar=\(titleBarHeight)")

        // Capture at the content's own pixel size. Asking SCK for a larger
        // output does *not* upscale: it pins the picture to the top left and
        // leaves the rest black. MaaTools rescales to `SIZE` while drawing, so a
        // native-size grab is both correct and cheaper.
        let scale = CGFloat(info.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = max(1, Int(ceil(contentSize.width * scale)))
        config.height = max(1, Int(ceil(contentSize.height * scale)))
        config.sourceRect = CGRect(x: 0, y: titleBarHeight,
                                   width: contentSize.width, height: contentSize.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.shouldBeOpaque = true
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    func windowImage() async -> CGImage? {
        guard let geometry = geometry() else {
            MaaPluginDebug.log("capture: no window geometry, returning cached frame")
            return lastFrame
        }
        if #available(macCatalyst 18.2, *), sckAvailable {
            let start = CFAbsoluteTimeGetCurrent()
            let image = await raceCapture(seconds: Self.captureTimeout) { [weak self] in
                guard let self else { return nil }
                return try? await self.captureImage(geometry.id, content: geometry.content)
            }
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            if let image {
                lastFrame = image
                if elapsed > 500 { MaaPluginDebug.log(String(format: "capture: slow SCK %.0f ms", elapsed)) }
                MaaPluginDebug.log(String(format: "capture: SCK %.0f ms -> %dx%d", elapsed, image.width, image.height))
                return image
            }
            MaaPluginDebug.log(String(format: "capture: SCK %.0f ms gave up", elapsed))
        }

        let start = CFAbsoluteTimeGetCurrent()
        let image = await raceCapture(seconds: Self.captureTimeout) { [weak self, geometry] in
            guard let self else { return nil }
            return await Task.detached { self.cgWindowImage(geometry) }.value
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        if let image {
            lastFrame = image
            if elapsed > 500 { MaaPluginDebug.log(String(format: "capture: slow CG %.0f ms", elapsed)) }
            MaaPluginDebug.log(String(format: "capture: CG %.0f ms -> %dx%d", elapsed, image.width, image.height))
            return image
        }

        MaaPluginDebug.log(String(format: "capture: CG %.0f ms gave up; replaying cached frame", elapsed))
        return lastFrame
    }

    /// Races one capture against a deadline. The abandoned capture keeps running
    /// in the background; it is detached, not blocked on, so a wedged capture can
    /// no longer freeze the control connection.
    private func raceCapture(seconds: TimeInterval,
                             operation: @escaping @MainActor () async -> CGImage?) async -> CGImage? {
        await withTaskGroup(of: CGImage?.self) { group in
            group.addTask { @MainActor in
                await operation()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - Lifecycle

    func terminateApplication() {
        exit(EXIT_SUCCESS)
    }
}
