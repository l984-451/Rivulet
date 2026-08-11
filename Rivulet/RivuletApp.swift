// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  RivuletApp.swift
//  Rivulet
//
//  Created by Bain Gurley on 11/28/25.
//

import SwiftUI
import SwiftData
import Sentry

// MARK: - App Delegate

class RivuletAppDelegate: NSObject, UIApplicationDelegate {

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        Task {
            await DeepLinkHandler.shared.handle(url: url)
        }
        return true
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([any UIUserActivityRestoring]?) -> Void) -> Bool {
        guard let ratingKey = userActivity.userInfo?["ratingKey"] as? String,
              !ratingKey.isEmpty else { return false }

        switch userActivity.activityType {
        case "com.rivulet.viewMedia":
            Task {
                await DeepLinkHandler.shared.handle(
                    url: URL(string: "rivulet://detail?ratingKey=\(ratingKey)")!
                )
            }
            return true
        case "com.rivulet.playMedia":
            Task {
                await DeepLinkHandler.shared.handle(
                    url: URL(string: "rivulet://play?ratingKey=\(ratingKey)")!
                )
            }
            return true
        default:
            return false
        }
    }
}

// MARK: - App

@main
struct RivuletApp: App {
    @UIApplicationDelegateAdaptor(RivuletAppDelegate.self) var appDelegate

    init() {
        StartupTimer.arm()
        StartupTimer.mark("RivuletApp.init")
        // Default the Home hero ON for fresh installs (and any user who hasn't
        // explicitly toggled it). The home reads this via UserDefaults.bool(),
        // which returns false for an unset key, so register the default here
        // before any read. An explicit user choice still wins.
        UserDefaults.standard.register(defaults: ["showHomeHero": true])

        // PlexAuthManager owns identity and lives in RivuletCore; the content
        // store it hands off to is per platform. Set BEFORE any sign-in can
        // run: without the first hook the sidebar's conditional TabSection
        // latches to "empty" on a fresh sign-in, and without the second, a
        // sign-out leaves the previous server's hubs on screen.
        PlexAuthManager.onAuthenticated = { await PlexDataStore.shared.loadLibrariesIfNeeded() }
        PlexAuthManager.onSignedOut = { PlexDataStore.shared.reset() }
        PlexUserProfileManager.onProfileChanged = { await PlexDataStore.shared.onProfileSwitched() }
        PlexUserProfileManager.onInitialProfileSelected = { LibrarySettingsManager.shared.onProfileSwitched() }

        #if !DEBUG
        // Sentry start is DEFERRED off the launch window. Starting it in init()
        // fired envelope/session uploads to sentry.io before the network nexus
        // was ready — every cold launch spammed `NECP [22: Invalid argument]`
        // / `-1000 bad URL` failures (visible in release device logs) AND paid
        // its swizzling + session-tracking cost on the critical path. A few
        // seconds later the network is up, the uploads succeed, and the launch
        // window is clean. Trade-off: a crash in the first ~3s is not captured
        // (rare; acceptable given the launch-perf + log-noise win).
        Task.detached(priority: .utility) {
            // No DSN configured (Secrets.swift is local-only) — skip Sentry
            // entirely rather than initializing a dead SDK. SentryBridge stays
            // inactive so breadcrumb/capture calls no-op instead of spamming
            // "SDK is disabled" fatals.
            guard !Secrets.sentryDSN.isEmpty else { return }
            try? await Task.sleep(for: .seconds(3))
            await Self.startSentry()
        }
        #endif

        // NowPlayingService disabled — AVPlayerViewController handles Now Playing natively.
        // NowPlayingService.shared.initialize()

        // Emit the AppLaunch perf event so launch time, memory, and scroll
        // smoothness can be correlated in Instruments traces.
        Task { @MainActor in
            Perf.event(.appLaunch, message: "init")
        }
    }

    #if !DEBUG
    /// Starts Sentry. MUST be main-actor isolated: `SentrySDK.start` builds the
    /// SDK's dependency container, which reads `UIApplication.applicationState`
    /// and installs swizzling + session / app-hang tracking. Called from the
    /// deferred `Task.detached` above it tripped the Main Thread Checker twice on
    /// every device launch ("UI API called on a background thread"). Only the
    /// start call is hoisted — the 3s deferral that keeps launch logs clean stays.
    @MainActor
    private static func startSentry() {
        SentryStartup.start(platform: .tvOS)

        // Seed the App Hang triage scope so the very first hang event after
        // launch already carries a screen tag. Updated thereafter via
        // AppHangContext as the user navigates and plays. See RIVULET-41.
        // Already on the main actor here, so no hop.
        AppHangContext.setScreen("launch")
    }
    #endif

    var sharedModelContainer: ModelContainer = {
        // Runs BEFORE init()'s body (Swift initializes stored properties first),
        // so this is the earliest app code on the launch path and a prime suspect
        // for the ~2.2s that used to sit unattributed between init and the
        // sidebar's first task. Opening a 7-model store is not free.
        StartupTimer.mark("sharedModelContainer build start")
        defer { StartupTimer.mark("sharedModelContainer build end") }
        let schema = Schema([
            ServerConfiguration.self,
            PlexServer.self,
            IPTVSource.self,
            Channel.self,
            FavoriteChannel.self,
            WatchProgress.self,
            EPGProgram.self,
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(MediaProviderRegistry.shared)
                .environment(MusicProviderRegistry.shared)
                .environment(MetadataSourceRegistry.shared)
        }
        .modelContainer(sharedModelContainer)
    }
}
