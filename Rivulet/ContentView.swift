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
            // Hubs wait for the picker's selection, so content-ready never fires:
            // drop the splash now instead of riding the 15 s timeout behind the picker.
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
            ServerDataStore.shared.reload()
            PlexExtraServers.shared.refreshForAccount()
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
            ServerDataStore.shared.reload()
        }
        .onChange(of: authManager.selectedServerToken) { _, _ in
            MediaProviderRegistry.shared.populateFromCurrentAuth()
            MusicProviderRegistry.shared.populateFromCurrentAuth()
            // A PIN lock or another profile changes which other Plex servers show.
            ServerDataStore.shared.reload()
        }
        // Refresh libraries on every return to .active: `loadLibrariesIfNeeded` stops at
        // the cache, so a library added on the server would never appear otherwise.
        .onChange(of: scenePhase) { _, phase in
            DiagLog.notice(.launch, "Scene \(phase)")
            if phase == .active {
                Task { await dataStore.refreshLibraries() }
                ServerDataStore.shared.reload()
            }
        }
    }

    /// Dismisses the splash once content is ready and, with the hero on, its backdrop is too,
    /// so the hero does not pop in after the rows. A short cap keeps a slow image from holding it.
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
                #if DEBUG
                if env["RIVULET_AUTOPLAY_LIVE"] != nil {
                    hasLaunched = true
                    Task { await AVKitScrubProbe.runLive(env: env) }
                    return
                }
                if env["RIVULET_SCRUBPROBE"] != nil {
                    hasLaunched = true
                    // Unstructured: presenting the player cancels this view's .task.
                    Task { await AVKitScrubProbe.run(env: env) }
                    return
                }
                #endif
                guard env["RIVULET_AUTOPLAY"] == "1",
                      var ratingKey = env["RIVULET_AUTOPLAY_KEY"] else { return }

                let testDuration = TimeInterval(env["RIVULET_AUTOPLAY_DURATION"] ?? "45") ?? 45
                let skipLifecycle = env["RIVULET_AUTOPLAY_SKIP_LIFECYCLE"] == "1"
                let startOffset: TimeInterval? = env["RIVULET_AUTOPLAY_OFFSET"].flatMap { TimeInterval($0) }

                hasLaunched = true
                print("[AutoPlay] Starting: ratingKey=\(ratingKey) duration=\(testDuration)s skipLifecycle=\(skipLifecycle) offset=\(startOffset.map { String(format: "%.0f", $0) } ?? "none")")

                #if DEBUG
                // RIVULET_AUTOPLAY_SERVER=<machineIdentifier>: play the key from
                // another Plex server on the account, through the real tile route.
                if let machineID = env["RIVULET_AUTOPLAY_SERVER"] {
                    await ContentView.autoplayOnOtherServer(machineID, ratingKey: ratingKey, duration: testDuration)
                    return
                }
                #endif

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

                #if DEBUG
                ratingKey = await AVKitScrubProbe.resolveRatingKey(ratingKey, serverURL: serverURL, token: authToken)
                #endif

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
                        loadingArtImage: nil,
                        loadingThumbImage: nil
                    )

                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let rootVC = windowScene.windows.first?.rootViewController {
                        PlayerPresenter.present(viewModel: viewModel, from: rootVC, animated: false)
                    }

                    #if DEBUG
                    // RIVULET_AUTOPLAY_CHROME=1: pause and bring the controls up
                    // with focus on them, for layout checks without a remote.
                    if env["RIVULET_AUTOPLAY_CHROME"] == "1" {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(12))
                            viewModel.pause()
                            viewModel.showControlsTemporarily()
                            viewModel.enterControlsFocus()
                            if env["RIVULET_AUTOPLAY_TRIVIA"] == "1" {
                                viewModel.debugSetInsightsTrivia(ScrubStatesProbe.fixtureTrivia)
                            }
                            // RIVULET_AUTOPLAY_PANE=info|chapters|upNext|insights|details
                            if let pane = env["RIVULET_AUTOPLAY_PANE"] {
                                try? await Task.sleep(for: .seconds(1))
                                PlayerContainerViewController.debugCurrent?.debugPresentPane(pane)
                            }
                            // RIVULET_AUTOPLAY_MOVES=down,up,...: drive focus without a remote.
                            if let moves = env["RIVULET_AUTOPLAY_MOVES"],
                               let window = PlayerContainerViewController.debugCurrent?.view.window {
                                await DebugFocusDriver.run(moves, in: window)
                            }
                        }
                    }
                    #endif

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

#if DEBUG
extension ContentView {
    /// The autoplay hook for an extra Plex server's item: waits for its provider,
    /// then plays it the way a tile does (`ProviderPlayer.play`).
    @MainActor
    static func autoplayOnOtherServer(_ machineID: String, ratingKey: String, duration: TimeInterval) async {
        let providerID = "plex:\(machineID)"
        let deadline = Date().addingTimeInterval(45)
        while MediaProviderRegistry.shared.provider(for: providerID) == nil {
            guard Date() < deadline else { return print("[AutoPlay] ERROR: \(providerID) never registered") }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard let provider = MediaProviderRegistry.shared.provider(for: providerID),
              let detail = try? await provider.fullDetail(for: MediaItemRef(providerID: providerID, itemID: ratingKey)),
              let rootVC = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first?.rootViewController
        else { return print("[AutoPlay] ERROR: could not resolve \(ratingKey) on \(providerID)") }
        print("[AutoPlay] Other server: \(detail.item.title) on \(providerID) isPlex=\(detail.item.ref.isPlex)")
        ProviderPlayer.play(detail.item, fromBeginning: false, from: rootVC, onDismiss: nil)
        // Unstructured: presenting the player cancels the view's .task, which would end the sleep at once.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            print("[AutoPlay] Test duration elapsed (\(duration)s), exiting")
            rootVC.dismiss(animated: false)
            try? await Task.sleep(for: .seconds(2))
            exit(0)
        }
    }
}
#endif

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
