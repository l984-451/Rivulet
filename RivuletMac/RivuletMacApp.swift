// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI
import Sentry

@main
struct RivuletMacApp: App {
    @StateObject private var plex: PlexSession
    @StateObject private var playback = MacPlaybackController()

    init() {
        #if DEBUG
        MacDebugSeed.seedSession()
        #endif
        HostPlatform.installAppKit()
        ClientHost.prefetchImage = { _ = await MacArtworkCache.shared.image(for: $0) }
        // Order matters: identity and migration must land before anything
        // touches PlexAuthManager.shared (the session does) or builds a request.
        // A laptop joins other people's networks; a LAN address there may be anyone.
        PlexAuthManager.prefersSecureLocalConnections = true
        SkipLengthKeys.migrateLegacyKeys()
        // "Mac", not the computer's name: the same entry the iOS app on a Mac shows on plex.tv,
        // and a name like "Bain’s MacBook Pro" puts a non-ASCII quote in a request header.
        PlexAPI.platform = "macOS"
        PlexAPI.deviceName = "Mac"
        // The Mac library grid lists titles, as on iOS.
        MediaProviderRegistry.plexIncludesCollections = false
        MediaProviderRegistry.shared.populateFromCurrentAuth()
        let session = PlexSession()
        session.installProfileHooks()
        _plex = StateObject(wrappedValue: session)
        _ = NetworkPathMonitor.shared
        // The Live TV store re-keys old URL-named M3U favorites when it starts. That must finish
        // before the first sync pass, or a playlist URL with its login could be uploaded as a channel id.
        _ = LiveTVDataStore.shared
        CloudSync.shared.start()
        LiveTVDataStore.shared.startBackgroundPreload()

        #if !DEBUG
        // Deferred and gated like tvOS and iOS: never in DEBUG, nothing to start without a DSN.
        Task.detached(priority: .utility) {
            guard !Secrets.sentryDSN.isEmpty else { return }
            try? await Task.sleep(for: .seconds(3))
            await SentryStartup.start(platform: .macOS)
        }
        #endif
    }

    var body: some Scene {
        Window("Rivulet", id: "main") {
            MacRootView()
                .environmentObject(plex)
                .environmentObject(plex.browse)
                .environmentObject(playback)
                .frame(minWidth: 1000, minHeight: 640)
        }
        // One window: one player surface, and a rivulet:// link has one place to land.
        .defaultSize(width: 1280, height: 800)
        .commands {
            MacShellCommands(browse: plex.browse)
            MacPlaybackCommands(playback: playback)
        }

        Settings {
            MacSettingsView()
                .environmentObject(plex)
                .environmentObject(plex.browse)
                .environmentObject(playback)
        }

        Window("What's New", id: MacWhatsNewWindow.id) {
            MacWhatsNewView(versions: [MacChangelog.entries.first?.version ?? MacChangelog.currentVersion])
        }
        .windowResizability(.contentSize)
    }
}
