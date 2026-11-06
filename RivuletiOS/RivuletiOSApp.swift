// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI
import UIKit

@main
struct RivuletiOSApp: App {
    @UIApplicationDelegateAdaptor(IOSAppDelegate.self) private var appDelegate
    @StateObject private var plex: IOSPlexSession

    init() {
        // Order matters: identity and migration must land before anything
        // touches PlexAuthManager.shared (the session does) or builds a request.
        // The manager reads Keychain and UserDefaults in its init, and PlexAPI
        // values are baked into every header.
        // A phone joins other people's networks; a LAN address there may be anyone.
        PlexAuthManager.prefersSecureLocalConnections = true
        Self.migrateLegacyIOSSession()
        SkipLengthKeys.migrateLegacyKeys()
        #if DEBUG
        IOSScreenshotMode.seedSession()
        #endif
        // Designed for iPad on a Mac is this same binary, so without the check
        // plex.tv lists a Mac as an iPad. Shared code never asks; the host does.
        let isMac = ProcessInfo.processInfo.isiOSAppOnMac
        PlexAPI.platform = isMac ? "macOS" : "iOS"
        PlexAPI.deviceName = isMac ? "Mac" : UIDevice.current.model   // "iPhone" / "iPad"
        // The iOS library grid lists titles; tvOS also lists a library's collections.
        MediaProviderRegistry.plexIncludesCollections = false
        // The signed-in Jellyfin and Emby servers, rebuilt from their stored accounts.
        MediaProviderRegistry.shared.populateFromCurrentAuth()
        let session = IOSPlexSession()
        session.installProfileHooks()
        _plex = StateObject(wrappedValue: session)
        // Start the path monitor now; its first reading arrives after a delay.
        _ = NetworkPathMonitor.shared
        // The Live TV store re-keys old URL-named M3U favorites when it starts. That must finish before the
        // first sync pass, or a playlist URL with its login could be uploaded as a channel id.
        _ = LiveTVDataStore.shared
        // The iOS views read their synced keys live (@AppStorage), so no reload hook is needed.
        CloudSync.shared.start()
        // Recreates the background session and resumes unfinished downloads.
        IOSDownloadCenter.shared.start()
        IOSDownloadActivity.shared.start()
        // Folds the old single-source settings into the shared store, then
        // warms the guide so the Live TV tab opens with data.
        Task {
            await LiveTVDataStore.shared.migrateLegacyIOSSource(defaults: .standard)
            LiveTVDataStore.shared.startBackgroundPreload()
        }

        #if !DEBUG
        // Deferred and gated exactly like tvOS: the SDK is never started in
        // DEBUG, an empty DSN means Secrets.swift was never filled in locally
        // so there is nothing to start, and the 3s wait keeps the SDK's
        // swizzling and session-tracking cost off the launch path. Trade-off is
        // the same too: a crash inside the first ~3s is not captured.
        Task.detached(priority: .utility) {
            guard !Secrets.sentryDSN.isEmpty else { return }
            try? await Task.sleep(for: .seconds(3))
            await SentryStartup.start(platform: isMac ? .macOS : .iOS)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            IOSRootView()
                .environmentObject(plex)
                .environmentObject(plex.browse)
                .environmentObject(IOSDownloadCenter.shared)
        }
    }

    /// One-time migration from the POC's own session keys to the shared
    /// PlexAuthManager keys, so TestFlight users signed in before the
    /// duplicate Plex client was deleted stay signed in.
    ///
    /// Must run before `PlexAuthManager.shared` is first touched: its init
    /// reads these exact keys, and its fresh-install detection CLEARS Keychain
    /// tokens that arrive without the `plexHasPersistedSession` sentinel.
    private static func migrateLegacyIOSSession() {
        let defaults = UserDefaults.standard
        guard let legacyToken = KeychainHelper.get("iosPlexAuthToken"),
              KeychainHelper.get("plexAuthToken") == nil else {
            return
        }
        KeychainHelper.set(legacyToken, forKey: "plexAuthToken")
        if let serverToken = KeychainHelper.get("iosPlexServerToken") {
            KeychainHelper.set(serverToken, forKey: "selectedServerToken")
        }
        if let url = defaults.string(forKey: "iosPlexServerURL") {
            defaults.set(url, forKey: "selectedServerURL")
        }
        if let name = defaults.string(forKey: "iosPlexServerName") {
            defaults.set(name, forKey: "selectedServerName")
        }
        defaults.set(true, forKey: "plexHasPersistedSession")
        KeychainHelper.delete("iosPlexAuthToken")
        KeychainHelper.delete("iosPlexServerToken")
        defaults.removeObject(forKey: "iosPlexServerURL")
        defaults.removeObject(forKey: "iosPlexServerName")
    }
}
