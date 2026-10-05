// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI
import UIKit

@main
struct RivuletiOSApp: App {
    @StateObject private var plex: IOSPlexSession

    init() {
        // Order matters: identity and migration must land before anything
        // touches PlexAuthManager.shared (the session does) or builds a request.
        // The manager reads Keychain and UserDefaults in its init, and PlexAPI
        // values are baked into every header.
        Self.migrateLegacyIOSSession()
        PlexAPI.platform = "iOS"
        PlexAPI.deviceName = UIDevice.current.model   // "iPhone" / "iPad"
        let session = IOSPlexSession()
        session.installProfileHooks()
        _plex = StateObject(wrappedValue: session)
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
            await SentryStartup.start(platform: .iOS)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            IOSRootView()
                .environmentObject(plex)
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
