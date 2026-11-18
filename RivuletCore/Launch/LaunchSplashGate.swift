// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Combine
import Foundation

/// When the iOS and Mac launch splash leaves. tvOS decides the same things from
/// `PlexDataStore` in `ContentView`; this reads `BrowseStore`, which both other apps share.
///
/// The splash leaves as soon as there is nothing left to wait for: no server signed in, a
/// profile to choose, Home's rows loaded, an error, or a load that came back empty. With the
/// hero on, loaded rows also wait for the hero's artwork (so it does not pop in after them),
/// but never longer than `heroWaitCap`. `safetyTimeout` is the backstop.
///
/// The app makes one at launch, so a second window, or a root view rebuilt later, finds it
/// finished and opens straight on Home.
@MainActor
final class LaunchSplashGate: ObservableObject {
    enum Decision: Equatable {
        case wait
        case waitForHero
        case finish
    }

    struct Signals: Equatable {
        /// Any server signed in to load Home from.
        var hasServers: Bool
        /// The profile picker comes up instead of Home.
        var needsProfile: Bool
        /// Home has rows to draw (`BrowseStore.hasHomeContent`).
        var hasContent: Bool
        var hasError: Bool
        /// A load ran and ended.
        var loadEnded: Bool
        var heroEnabled: Bool
        /// The hero's first artwork is on screen, or Home settled with no hero to show.
        var heroReady: Bool
    }

    static func decide(_ signals: Signals) -> Decision {
        if !signals.hasServers || signals.needsProfile || signals.hasError { return .finish }
        guard signals.hasContent else { return signals.loadEnded ? .finish : .wait }
        return !signals.heroEnabled || signals.heroReady ? .finish : .waitForHero
    }

    static let safetyTimeout: Duration = .seconds(15)
    /// The same cap tvOS gives the hero (`ContentView.heroWaitCap`).
    static let heroWaitCap: Duration = .milliseconds(3500)

    /// Turns true once; the host then plays the splash's exit.
    @Published private(set) var isFinished: Bool

    private let browse: BrowseStore
    private let profiles: PlexUserProfileManager
    private var heroReady = false
    private var heroCap: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(browse: BrowseStore, profiles: PlexUserProfileManager = .shared) {
        self.browse = browse
        self.profiles = profiles
        isFinished = !LaunchSplashAnimation.isWanted
        guard !isFinished, !LaunchSplashAnimation.holdsForDebug else { return }
        // objectWillChange fires before the new value lands, so look on the next turn.
        browse.objectWillChange.merge(with: profiles.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)
        timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.safetyTimeout)
            guard !Task.isCancelled else { return }
            self?.finish("safety timeout")
        }
        evaluate()
    }

    /// The hero's first artwork is on screen, or Home settled with no hero to show.
    func heroIsReady() {
        guard !heroReady else { return }
        heroReady = true
        evaluate()
    }

    private func evaluate() {
        guard !isFinished else { return }
        let signals = Signals(hasServers: !browse.allProviders.isEmpty,
                              needsProfile: profiles.needsProfileSelection,
                              hasContent: browse.hasHomeContent,
                              hasError: browse.contentError != nil,
                              loadEnded: browse.hasRefreshed && !browse.isLoadingContent,
                              heroEnabled: HeroSources.isEnabled,
                              heroReady: heroReady)
        switch Self.decide(signals) {
        case .wait:
            break
        case .finish:
            finish("ready \(signals)")
        case .waitForHero:
            guard heroCap == nil else { return }
            heroCap = Task { [weak self] in
                try? await Task.sleep(for: Self.heroWaitCap)
                guard !Task.isCancelled else { return }
                self?.finish("hero wait cap")
            }
        }
    }

    private func finish(_ reason: String) {
        guard !isFinished else { return }
        DiagLog.notice(.launch, "Splash done: \(reason)")
        isFinished = true
        heroCap?.cancel()
        timeout?.cancel()
        cancellables.removeAll()
    }
}
