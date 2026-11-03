//
//  MaaPluginDebug.swift
//  MaaPlugin
//
//  Opt-in diagnostics: nothing is written unless `MAATOOLS_DEBUG=1` is present
//  in the game's environment. Like the rest of the plugin, it has to cope with
//  the app sandbox — a PlayCover game cannot write `/tmp` — so the log location
//  is probed in order and the resolved path is printed once via NSLog:
//
//    1. `$MAATOOLS_LOG_DIR/maaplugin-<bundle-id>.log` (manual override)
//    2. `/tmp/maaplugin-<bundle-id>.log`              (unsandboxed hosts)
//    3. `<real home>/Downloads/maaplugin-<bundle-id>.log` — PlayCover grants
//       games `files.downloads.read-write`, so this works inside the sandbox
//    4. `<real home>/Library/Containers/io.playcover.PlayCover/MaaPluginLogs/`
//       — permitted by the sandbox exception PlayCover grants its games
//    5. `NSTemporaryDirectory()`                       (last resort)
//

import Foundation

enum MaaPluginDebug {
    static let enabled = ProcessInfo.processInfo.environment["MAATOOLS_DEBUG"] == "1"

    private static let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
    private static var resolvedPath: String?

    static var logPath: String {
        if let resolvedPath { return resolvedPath }
        let path = candidatePaths().first ?? "/tmp/maaplugin-\(bundleID).log"
        resolvedPath = path
        NSLog("[MaaPlugin] log: %@", path)
        return path
    }

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "[\(timeFormatter.string(from: Date()))] \(message())\n"
        guard let data = line.data(using: .utf8) else { return }

        let path = logPath
        if append(data, to: path) { return }
        for candidate in candidatePaths() where candidate != path {
            if append(data, to: candidate) {
                resolvedPath = candidate
                NSLog("[MaaPlugin] log moved to %@", candidate)
                return
            }
        }
        NSLog("[MaaPlugin] %@", line.trimmingCharacters(in: .newlines))
    }

    private static let maxBytes = 1_000_000
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static func candidatePaths() -> [String] {
        var paths: [String] = []
        if let override = ProcessInfo.processInfo.environment["MAATOOLS_LOG_DIR"] {
            paths.append((override as NSString).appendingPathComponent("maaplugin-\(bundleID).log"))
        }
        paths.append("/tmp/maaplugin-\(bundleID).log")
        paths.append("\(realHomeDirectory())/Downloads/maaplugin-\(bundleID).log")
        paths.append("\(realHomeDirectory())/Library/Containers/io.playcover.PlayCover/MaaPluginLogs/maaplugin-\(bundleID).log")
        paths.append((NSTemporaryDirectory() as NSString).appendingPathComponent("maaplugin-\(bundleID).log"))
        return paths
    }

    /// `NSHomeDirectory()` is the sandbox container; PlayCover's shared
    /// directory lives under the real home.
    private static func realHomeDirectory() -> String {
        if let home = getpwuid(getuid())?.pointee.pw_dir.map({ String(cString: $0) }) {
            return home
        }
        return "/Users/\(NSUserName())"
    }

    private static func append(_ data: Data, to path: String) -> Bool {
        let manager = FileManager.default
        let directory = (path as NSString).deletingLastPathComponent
        try? manager.createDirectory(atPath: directory, withIntermediateDirectories: true)

        if let attributes = try? manager.attributesOfItem(atPath: path),
           let size = attributes[.size] as? Int, size > maxBytes {
            try? manager.removeItem(atPath: path)
        }

        guard let handle = FileHandle(forWritingAtPath: path)
            ?? FileHandle(forWritingAtPath: {
                manager.createFile(atPath: path, contents: nil)
                return path
            }()) else {
            return false
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }
}

/// C entry point for the Objective-C touch code, if it ever needs to log.
@_cdecl("MaaPluginDebugLogC")
public func MaaPluginDebugLogC(_ message: UnsafePointer<CChar>) {
    MaaPluginDebug.log(String(cString: message))
}
