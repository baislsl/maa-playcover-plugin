//
//  MaaPluginEntry.swift
//  MaaPlugin
//
//  Entry point called by PluginBootstrap.m's constructor.
//
//  Mirrors PlayTools' PlayCover.swift: touch `ArknightsMetalCapture.installation`
//  during launch so the Metal hooks are installed when the user enabled the
//  option, then hand control to the vendored MaaTools server.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "io.playcover.MaaPlugin", category: "MaaPlugin")

@_cdecl("MaaPluginStart")
public func MaaPluginStart() {
    Task { @MainActor in
        let settings = PlaySettings.shared
        MaaPluginDebug.log("start: log=\(MaaPluginDebug.logPath) port=\(settings.maaToolsPort) maaTools=\(settings.maaTools) metal=\(settings.enableMetalCapture)")
        logger.notice("""
            Starting MaaTools plugin: bundle=\(Bundle.main.bundleIdentifier ?? "?", privacy: .public) \
            port=\(settings.maaToolsPort, privacy: .public) \
            maaTools=\(settings.maaTools, privacy: .public) \
            metalCapture=\(settings.enableMetalCapture, privacy: .public)
            """)

        guard settings.maaTools else {
            logger.notice("MaaTools is disabled in settings; not starting the server")
            return
        }

        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        let screen = windows.first?.windowScene?.screen
        MaaPluginDebug.log("""
            screen: bounds=\(String(describing: screen?.bounds)) \
            native=\(String(describing: screen?.nativeBounds)) \
            scale=\(String(describing: screen?.nativeScale)) \
            windows=\(windows.map(\.frame))
            """)

        if ArknightsMetalCapture.installation == true {
            logger.notice("Installed Metal capture hooks")
        }

        if Toucher.isAvailable {
            MaaPluginDebug.log("touch: PTFakeMetaTouch found in PlayTools")
        } else {
            logger.error("PTFakeMetaTouch not found: PlayTools is not injected, touches will be ignored")
        }

        MaaTools.shared.initialize()
    }
}
