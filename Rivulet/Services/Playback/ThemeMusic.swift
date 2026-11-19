// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

//
//  ThemeMusic.swift
//  Rivulet
//
//  A TV show's theme tune, played once and quietly while one of its pages (the show, a
//  season, an episode) is on screen. One shared controller: the pages only say "look again"
//  (`refresh`), and everything that starts other sound says `stopForVideo`.
//
//  It writes nothing to the audio session, Now Playing or the remote commands: re-applying the
//  session's category on a running session renegotiates HDMI (see
//  PlaybackAudioSessionConfigurator), so the tune plays in whatever session the app has and its
//  player is released, not paused, before a video configures one.
//

import AVFoundation
import UIKit

/// A page that belongs to a title: the expanded detail, a season page, an episode page.
@MainActor
protocol ThemeMusicPage: UIViewController {
    /// The show this page belongs to right now; nil for a film or the collapsed card carousel.
    var themeMusicShow: MediaItemRef? { get }
}

@MainActor
final class ThemeMusic {
    static let shared = ThemeMusic()

    // MARK: Rules (pure, unit tested)

    /// What the pages on screen ask for.
    nonisolated enum Screen: Equatable, Sendable {
        /// No page of a show is on top.
        case noShow
        /// A show's page is up, under something that covers it (a player, a person's page).
        case covered
        case show(MediaItemRef)
    }

    /// One presented controller, bottom to top, reduced to what the rule reads.
    nonisolated struct Layer: Sendable {
        var isPage: Bool
        var show: MediaItemRef?
        /// Covers the page under it: a full-screen presentation, or another opaque page.
        var isFullScreen: Bool
    }

    /// The topmost page decides. Popups (not pages, not full screen) change nothing; a
    /// full-screen cover over a show's page silences it without ending the visit.
    nonisolated static func screen(for layers: [Layer]) -> Screen {
        var result = Screen.noShow
        for layer in layers {
            if layer.isPage {
                result = layer.show.map { Screen.show($0) } ?? .noShow
            } else if layer.isFullScreen, result != .noShow {
                result = .covered
            }
        }
        return result
    }

    /// Whether a tune may start. Every condition must hold.
    nonisolated static func mayStart(enabled: Bool, isForeground: Bool, musicActive: Bool,
                                     videoActive: Bool, otherAppAudio: Bool) -> Bool {
        enabled && isForeground && !musicActive && !videoActive && !otherAppAudio
    }

    // MARK: State

    /// The shows whose tune has had its turn. A show stays here while any of its pages is
    /// still presented, even under another title's page, so its tune plays once per visit:
    /// not again on its season and episode pages, nor on the way back from a related title.
    private var served: Set<MediaItemRef> = []
    /// The show whose page was on top at the last look.
    private var onTop: MediaItemRef?
    private var lookup: Task<Void, Never>?
    private var player: AVPlayer?
    private var endObservers: [NSObjectProtocol] = []
    private var failureObservation: NSKeyValueObservation?
    private var soundingObservation: NSKeyValueObservation?
    private var fadeTimer: Timer?
    private var poll: Timer?
    private var resignObserver: NSObjectProtocol?
    /// Bumped whenever the sound is started or stopped, so a late lookup, fade or end is ignored.
    private var generation = 0

    private static let fadeInSeconds: TimeInterval = 1.0
    private static let fadeOutSeconds: TimeInterval = 0.4
    /// The pages are over-full-screen, so a page gets no callback when something is put over
    /// it. While a tune is sounding or being looked up, look again this often: a missed
    /// callback can then only end in silence.
    private static let pollSeconds: TimeInterval = 0.5

    private init() {
        // The app declares background audio, so a tune would carry on after the Home button.
        resignObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopForVideo() }
        }
    }

    // MARK: Entry points

    /// A page appeared, left or changed: work out again which show's tune is wanted.
    /// Cheap and idempotent; the lookup and the player start happen later, off this call.
    func refresh() {
        let layers = ThemeMusicSettings.isEnabled ? Self.layersOnScreen() : []
        // A show is forgotten when its last page has left, not when another title covers it.
        served.formIntersection(layers.compactMap(\.show))
        switch Self.screen(for: layers) {
        case .noShow:
            onTop = nil
            leave()
        case .covered:
            silence()
        case .show(let show):
            guard show != onTop else { return }
            onTop = show
            if served.insert(show).inserted {
                silence()
                start(show)
            } else {
                // Back on a show that has had its tune: fade out whatever the page above played.
                leave()
            }
        }
    }

    /// Something else is about to make sound (a video, a channel, a song). Synchronous: the
    /// player is released before this returns. The show keeps its turn, so the tune does not
    /// come back when the video closes.
    func stopForVideo() {
        silence()
    }

    // MARK: Starting

    private func start(_ show: MediaItemRef) {
        generation += 1
        let generation = generation
        startPoll()
        lookup = Task { [weak self] in
            // Theme media is optional: a failed lookup is simply no tune on this visit.
            let url = try? await MediaProviderRegistry.shared.provider(for: show.providerID)?
                .themeMusicURL(for: show)
            // A read, never a write, and off the main thread: it can wait on the audio server.
            let otherAppAudio = await Task.detached { AVAudioSession.sharedInstance().isOtherAudioPlaying }.value
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.lookup = nil
            guard let url,
                  Self.mayStart(enabled: ThemeMusicSettings.isEnabled,
                                isForeground: HostPlatform.isForeground(),
                                musicActive: MusicQueue.shared.isActive,
                                videoActive: MusicQueue.shared.videoOwnsNowPlaying,
                                otherAppAudio: otherAppAudio),
                  Self.screen(for: Self.layersOnScreen()) == .show(show)
            else {
                self.stopPoll()
                return
            }
            self.play(url)
        }
    }

    private func play(_ url: URL) {
        releasePlayer()
        generation += 1
        let generation = generation

        // A Plex theme path has no file extension; say what it is in case the server does not.
        let options: [String: Any] = url.pathExtension.isEmpty
            ? ["AVURLAssetOutOfBandMIMETypeKey": "audio/mpeg"] : [:]
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
        let player = AVPlayer(playerItem: item)
        player.volume = 0
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.audiovisualBackgroundPlaybackPolicy = .pauses
        // Once, like Plex: no loop.
        player.actionAtItemEnd = .pause
        self.player = player

        let center = NotificationCenter.default
        endObservers = [AVPlayerItem.didPlayToEndTimeNotification,
                        AVPlayerItem.failedToPlayToEndTimeNotification].map { name in
            center.addObserver(forName: name, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.ended(generation) }
            }
        }
        // A tune that cannot play is dropped for this visit; no retry, and nothing is logged
        // (the URL and the player's error both carry the server's token).
        failureObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in self?.ended(generation) }
        }

        // The file is remote and takes a moment to open: fade in from when sound really starts.
        soundingObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            guard player.timeControlStatus == .playing else { return }
            Task { @MainActor [weak self] in
                guard let self, generation == self.generation else { return }
                self.soundingObservation?.invalidate()
                self.soundingObservation = nil
                self.fade(to: ThemeMusicSettings.volume, over: Self.fadeInSeconds)
            }
        }

        startPoll()
        player.play()
    }

    // MARK: Stopping

    /// The tune finished or failed: let go of the player. The show keeps its turn.
    private func ended(_ generation: Int) {
        guard generation == self.generation else { return }
        silence()
    }

    /// Hard stop, synchronous. The show keeps its turn.
    private func silence() {
        generation += 1
        lookup?.cancel()
        lookup = nil
        stopPoll()
        releasePlayer()
    }

    /// No page of the sounding show is on top any more: fade out, then let go.
    private func leave() {
        guard player != nil || lookup != nil else { return }
        generation += 1
        lookup?.cancel()
        lookup = nil
        stopPoll()
        guard player != nil else { return }
        let generation = generation
        fade(to: 0, over: Self.fadeOutSeconds) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.releasePlayer()
        }
    }

    /// Released, not paused: a paused player still holds an audio path.
    private func releasePlayer() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        endObservers.forEach(NotificationCenter.default.removeObserver)
        endObservers = []
        failureObservation?.invalidate()
        failureObservation = nil
        soundingObservation?.invalidate()
        soundingObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private func fade(to target: Float, over seconds: TimeInterval, then completion: (() -> Void)? = nil) {
        fadeTimer?.invalidate()
        guard let player else { return }
        let start = player.volume
        let steps = 12
        var step = 0
        fadeTimer = Timer.scheduledTimer(withTimeInterval: seconds / Double(steps), repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return timer.invalidate() }
                step += 1
                if step >= steps {
                    player.volume = target
                    timer.invalidate()
                    self.fadeTimer = nil
                    completion?()
                } else {
                    player.volume = start + (target - start) * Float(step) / Float(steps)
                }
            }
        }
    }

    // MARK: Looking again

    private func startPoll() {
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: Self.pollSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func stopPoll() {
        poll?.invalidate()
        poll = nil
    }

    /// The controllers presented over the window's root, bottom to top. One being dismissed
    /// no longer counts, nor does anything above it.
    private static func layersOnScreen() -> [Layer] {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
        var layers: [Layer] = []
        var current = window?.rootViewController?.presentedViewController
        while let controller = current, !controller.isBeingDismissed {
            if let page = controller as? ThemeMusicPage {
                layers.append(Layer(isPage: true, show: page.themeMusicShow, isFullScreen: false))
            } else {
                // A person page and a collection or playlist page are opaque pages of something
                // else: over-full-screen, but they cover a show's page as a player does.
                let covers = controller.modalPresentationStyle == .fullScreen
                    || controller is PersonDetailViewController
                    || controller is PlexHomeViewController
                layers.append(Layer(isPage: false, show: nil, isFullScreen: covers))
            }
            current = controller.presentedViewController
        }
        return layers
    }
}
