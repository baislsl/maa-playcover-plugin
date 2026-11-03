//
//  PlaySettingsShim.swift
//  MaaPlugin
//
//  `PlaySettings.shared` as expected by the vendored Hguandl/MaaTools.swift and
//  Hguandl/ArknightsMetalCapture.swift.
//
//  PlayTools reads per-app settings from the exact same file, so layering this
//  onto the plist keeps the plugin honouring PlayCover's UI without an XPC
//  channel: anything PlayCover (or the MaaTools fork) writes for the app is
//  visible here.
//
//  Upstream PlayCover has no MaaTools page, so every key is optional and the
//  defaults below apply when the key is absent. Environment variables override
//  the plist, which makes the plugin usable without touching PlayCover at all.
//

import Foundation

final class PlaySettings {
    static let shared = PlaySettings()

    /// Same location PlayTools uses. `NSHomeDirectory()` would point into the
    /// app sandbox, so resolve the real home directory through the password
    /// database instead (PlayTools hardcodes `/Users/<user>` for the same
    /// reason).
    private static var settingsURL: URL {
        let home = getpwuid(getuid())?.pointee.pw_dir.map { String(cString: $0) }
            ?? "/Users/\(NSUserName())"
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Containers/io.playcover.PlayCover")
            .appendingPathComponent("App Settings")
            .appendingPathComponent("\(bundleIdentifier).plist")
    }

    private let settings: [String: Any]

    private init() {
        if let data = try? Data(contentsOf: Self.settingsURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let dictionary = plist as? [String: Any] {
            settings = dictionary
        } else {
            settings = [:]
        }
    }

    private static func environmentBool(_ name: String) -> Bool? {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
        switch raw.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    /// MaaTools switch. The MaaTools fork stores this in the per-app settings;
    /// upstream PlayCover has no such key, and installing the dylib is already
    /// an explicit opt-in, so default to enabled.
    lazy var maaTools: Bool = Self.environmentBool("MAATOOLS_ENABLE")
        ?? settings["maaTools"] as? Bool
        ?? true

    /// Port the server binds. `MAATOOLS_PORT` wins so the plugin can run
    /// side-by-side with another MaaTools build without editing settings.
    lazy var maaToolsPort: Int = {
        if let raw = ProcessInfo.processInfo.environment["MAATOOLS_PORT"],
           let port = Int(raw), (1 ... 65535).contains(port) {
            return port
        }
        if let port = settings["maaToolsPort"] as? Int, (1 ... 65535).contains(port) {
            return port
        }
        return 1717
    }()

    /// Window size PlayCover has configured for this app, in points.
    ///
    /// This is the most stable orientation signal available at launch: the live
    /// window frame is still animating for the first moments and PlayTools may
    /// report a portrait `nativeBounds` for a landscape game, so using the
    /// configured size avoids choosing the wrong orientation during startup.
    lazy var windowSize: CGSize? = {
        guard let width = settings["windowWidth"] as? Int,
              let height = settings["windowHeight"] as? Int,
              width > 0, height > 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }()

    /// Metal drawable capture switch. Kept opt-in exactly like the fork's
    /// `AppSettingsData.enableMetalCapture` default; note that
    /// `ArknightsMetalCapture` only installs hooks for the bundle identifiers
    /// listed there, which is Arknights only in the vendored revision.
    lazy var enableMetalCapture: Bool = Self.environmentBool("MAATOOLS_METAL")
        ?? settings["enableMetalCapture"] as? Bool
        ?? false
}
