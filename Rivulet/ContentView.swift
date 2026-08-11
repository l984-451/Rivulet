// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ContentView.swift
//  Rivulet
//
//  Created by Bain Gurley on 11/28/25.
//

import SwiftUI
import SwiftData
import Combine
import os.log
import UIKit

private let splashLog = Logger(subsystem: "com.rivulet.app", category: "Splash")

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var dataStore = PlexDataStore.shared
    @StateObject private var authManager = PlexAuthManager.shared
    @StateObject private var profileManager = PlexUserProfileManager.shared
    #if DEBUG
    @State private var showSplash = false
    #else
    @State private var showSplash = true
    #endif

    /// Caps how long the splash waits for the hero backdrop once the content is
    /// ready, so a slow image/network can't hold the splash up. Cancelled if the
    /// hero reports ready first. The 15s safety timeout below is the backstop.
    @State private var heroCapTask: Task<Void, Never>?
    private let heroWaitCap: Duration = .milliseconds(3500)

    var body: some View {
        TVSidebarView()
            .modifier(AutoPlayLauncherModifier())
            .overlay {
                if showSplash {
                    splashOverlay
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.4), value: showSplash)
        .onChange(of: authManager.hasCredentials) { _, hasCredentials in
            splashLog.info("hasCredentials changed to \(hasCredentials)")
            if !hasCredentials {
                splashLog.info("No credentials — dismissing splash")
                showSplash = false
            }
        }
        .onChange(of: dataStore.isHomeContentReady) { _, isReady in
            splashLog.info("isHomeContentReady changed to \(isReady), showSplash=\(self.showSplash)")
            if isReady {
                evaluateSplashDismissal(trigger: "content ready")
            }
        }
        .onChange(of: dataStore.isHomeHeroReady) { _, isReady in
            splashLog.info("isHomeHeroReady changed to \(isReady), showSplash=\(self.showSplash)")
            if isReady {
                evaluateSplashDismissal(trigger: "hero ready")
            }
        }
        .onChange(of: profileManager.isPresentingLaunchPicker) { _, isPresenting in
            // The launch picker path defers hub loading until after selection,
            // so isHomeContentReady never fires and the splash would otherwise
            // ride its full 15s timeout while the picker sits behind it. Drop
            // the splash immediately so the picker is the launch surface. This
            // only fires when the picker actually presents (picker-on-launch +
            // multiple profiles); every other launch is untouched.
            if isPresenting {
                splashLog.info("Launch profile picker presenting — dismissing splash")
                showSplash = false
            }
        }
        .task {
            // StartupTimer (not splashLog) so this lands on the same +Nms
            // timeline as the rest of the launch trace — the splash logs had no
            // elapsed prefix, which is why this stretch read as a blank 2.2s.
            StartupTimer.mark("ContentView .task entry (registries next)")
            // Bootstrap the agnostic media layer registries. Touching the
            // metadata registry initializes it (and registers TMDB). The
            // provider registry needs the active Plex auth state — populate
            // now and again whenever the URL/token changes via the onChange
            // observers below.
            _ = MetadataSourceRegistry.shared
            MediaProviderRegistry.shared.populateFromCurrentAuth()
            MusicProviderRegistry.shared.populateFromCurrentAuth()
            MusicQueue.shared.configure(registry: MusicProviderRegistry.shared)
            StartupTimer.mark("registries bootstrapped")

            splashLog.info("Splash task started — hasCredentials=\(self.authManager.hasCredentials)")
            if !authManager.hasCredentials {
                splashLog.info("No credentials on launch — dismissing splash immediately")
                showSplash = false
                return
            }
            // Safety timeout
            try? await Task.sleep(for: .seconds(15))
            if showSplash {
                splashLog.warning("Safety timeout reached (15s) — force dismissing splash")
                showSplash = false
            }
        }
        .onChange(of: authManager.selectedServerURL) { _, _ in
            MediaProviderRegistry.shared.populateFromCurrentAuth()
            MusicProviderRegistry.shared.populateFromCurrentAuth()
        }
        .onChange(of: authManager.selectedServerToken) { _, _ in
            MediaProviderRegistry.shared.populateFromCurrentAuth()
            MusicProviderRegistry.shared.populateFromCurrentAuth()
        }
        // Refresh the server-side library list on every transition
        // to .active so a library added or renamed on the Plex server
        // while Rivulet was backgrounded (or while the user was on the
        // tvOS Home Screen) surfaces without an app restart.
        // `loadLibrariesIfNeeded` returns early once the cache is
        // populated, so without this hook the cached list never
        // reconciles against current server state. Library visibility
        // is fail-open (a hidden-libraries deny-list), so a freshly
        // discovered library auto-appears in the sidebar.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await dataStore.refreshLibraries() }
            }
        }
    }

    /// The splash covers the home until it's *fully* settled: content ready AND
    /// the hero backdrop on screen (when the hero is enabled). Gating on the
    /// hero too is what stops it popping in a beat after the rows paint. If the
    /// hero is disabled there's nothing to wait for, so content-ready alone
    /// dismisses. When content is ready but the hero is still loading, arm a
    /// short cap so a slow image can't hold the splash up.
    private func evaluateSplashDismissal(trigger: String) {
        guard showSplash else { return }

        let heroEnabled = (UserDefaults.standard.object(forKey: "showHomeHero") as? Bool) ?? true
        let contentReady = dataStore.isHomeContentReady
        let heroReady = dataStore.isHomeHeroReady

        guard contentReady else { return }

        if !heroEnabled || heroReady {
            splashLog.info("Dismissing splash — \(trigger) (heroEnabled=\(heroEnabled), heroReady=\(heroReady))")
            heroCapTask?.cancel()
            heroCapTask = nil
            showSplash = false
            return
        }

        // Content is ready, hero is enabled but not yet on screen — wait for it,
        // but only up to the cap. Arm the cap once.
        if heroCapTask == nil {
            splashLog.info("Content ready, waiting for hero (cap \(self.heroWaitCap))")
            heroCapTask = Task { @MainActor in
                try? await Task.sleep(for: heroWaitCap)
                guard !Task.isCancelled, showSplash else { return }
                splashLog.info("Hero wait cap reached — dismissing splash without hero")
                showSplash = false
                heroCapTask = nil
            }
        }
    }

    private var splashOverlay: some View {
        ZStack {
            VStack(spacing: 24) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.white.opacity(0.6))

                ProgressView()
                    .tint(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, ignoresSafeAreaEdges: .all)
        .allowsHitTesting(true)
    }
}

// MARK: - AutoPlay Launcher (Debug Testing)

/// Reads RIVULET_AUTOPLAY env vars (passed via `xcrun devicectl`) and auto-launches playback.
/// Used for automated playback testing from the CLI.
private struct AutoPlayLauncherModifier: ViewModifier {
    @State private var hasLaunched = false

    func body(content: Content) -> some View {
        content
            .task {
                guard !hasLaunched else { return }
                let env = ProcessInfo.processInfo.environment
                guard env["RIVULET_AUTOPLAY"] == "1",
                      let ratingKey = env["RIVULET_AUTOPLAY_KEY"] else { return }

                let testDuration = TimeInterval(env["RIVULET_AUTOPLAY_DURATION"] ?? "45") ?? 45
                let skipLifecycle = env["RIVULET_AUTOPLAY_SKIP_LIFECYCLE"] == "1"
                let startOffset: TimeInterval? = env["RIVULET_AUTOPLAY_OFFSET"].flatMap { TimeInterval($0) }

                hasLaunched = true
                print("[AutoPlay] Starting: ratingKey=\(ratingKey) duration=\(testDuration)s skipLifecycle=\(skipLifecycle) offset=\(startOffset.map { String(format: "%.0f", $0) } ?? "none")")

                // Wait for auth to be ready
                let authManager = PlexAuthManager.shared
                let deadline = Date().addingTimeInterval(30)
                while authManager.selectedServerURL == nil || authManager.selectedServerToken == nil {
                    if Date() > deadline {
                        print("[AutoPlay] ERROR: Auth not ready after 30s, aborting")
                        return
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }

                guard let serverURL = authManager.selectedServerURL,
                      let authToken = authManager.selectedServerToken else {
                    print("[AutoPlay] ERROR: No server credentials")
                    return
                }

                // Fetch full metadata
                let networkManager = PlexNetworkManager.shared
                let metadata: PlexMetadata
                do {
                    metadata = try await networkManager.getFullMetadata(
                        serverURL: serverURL,
                        authToken: authToken,
                        ratingKey: ratingKey
                    )
                    print("[AutoPlay] Fetched: \(metadata.title ?? "Unknown") (\(metadata.type ?? "?"))")
                } catch {
                    print("[AutoPlay] ERROR: Failed to fetch metadata: \(error)")
                    return
                }

                // Log DV profile info
                let dvStream = metadata.Media?.first?.Part?.first?.Stream?.first(where: { $0.isDolbyVision })
                if let dvProfile = dvStream?.DOVIProfile {
                    print("[AutoPlay] DV Profile \(dvProfile), BL CompatID \(dvStream?.DOVIBLCompatID ?? -1)")
                }

                // Create viewModel and present player. Mirrors the real user
                // flow in TVSidebarView.presentPlayerForDeepLink so autoplay
                // exercises the same player UI (UniversalPlayerView +
                // PlayerContainerViewController) that users actually see.
                await MainActor.run {
                    let viewModel = UniversalPlayerViewModel(
                        metadata: metadata,
                        serverURL: serverURL,
                        authToken: authToken,
                        startOffset: startOffset,
                        shuffledQueue: [],
                        loadingArtImage: nil,
                        loadingThumbImage: nil
                    )

                    let playerVC = PlayerPresenter.makeViewController(viewModel: viewModel)

                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let rootVC = windowScene.windows.first?.rootViewController {
                        var topVC = rootVC
                        while let presented = topVC.presentedViewController {
                            topVC = presented
                        }
                        topVC.present(playerVC, animated: false)
                    }

                    // Schedule auto-stop after test duration
                    Task {
                        try? await Task.sleep(nanoseconds: UInt64(testDuration) * 1_000_000_000)
                        print("[AutoPlay] Test duration elapsed (\(testDuration)s), stopping")
                        viewModel.stopPlayback()
                        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                           let rootVC = windowScene.windows.first?.rootViewController {
                            rootVC.dismiss(animated: false)
                        }
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        print("[AutoPlay] Test complete, exiting")
                        exit(0)
                    }
                }
            }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [
            ServerConfiguration.self,
            PlexServer.self,
            IPTVSource.self,
            Channel.self,
            FavoriteChannel.self,
            WatchProgress.self,
            EPGProgram.self,
        ], inMemory: true)
}
