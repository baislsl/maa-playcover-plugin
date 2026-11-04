//
//  PlaySettingsShim.swift
//  MaaPlugin
//
//  `PlaySettings.shared` as expected by the vendored Core/MaaTools.swift and
//  Core/ArknightsMetalCapture.swift.
//
//  The plugin never adds keys to PlayCover's settings: installing the dylib is
//  the opt-in, and every plugin switch is read from the environment so that
//  nothing depends on modifying PlayCover's plist. The plist is still consulted
//  for the one key PlayCover itself owns and the plugin genuinely needs — the
//  configured window size, used to decide the protocol size/orientation.
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

    private static func environmentInt(_ name: String) -> Int? {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
        return Int(raw)
    }

    /// Whether to start the server. Installing the dylib is already an explicit
    /// opt-in, so this defaults to on; `MAATOOLS_ENABLE=0` turns it off.
    lazy var maaTools: Bool = Self.environmentBool("MAATOOLS_ENABLE") ?? true

    /// Port the server binds. `MAATOOLS_PORT` overrides the default so several
    /// builds can coexist without touching any settings file.
    lazy var maaToolsPort: Int = {
        if let port = Self.environmentInt("MAATOOLS_PORT"), (1 ... 65535).contains(port) {
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

    /// Metal drawable capture switch, off unless `MAATOOLS_METAL=1`. Note that
    /// `ArknightsMetalCapture` only installs hooks for the bundle identifiers
    /// listed there, which is Arknights only in the vendored revision.
    lazy var enableMetalCapture: Bool = Self.environmentBool("MAATOOLS_METAL") ?? false
}
