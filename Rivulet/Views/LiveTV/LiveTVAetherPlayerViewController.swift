// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveTVAetherPlayerViewController.swift
//  Rivulet
//
//  Live TV player on Rivulet's own chrome (no AVKit). Video renders through
//  the engine surface (`AetherPlayerView` → `engine.bind(view:)`), which hosts
//  whichever layer the active backend uses — AVPlayerLayer on the native /
//  loopback-HLS paths, AVSampleBufferDisplayLayer on the software path
//  (MPEG-2, interlaced H.264). Audio is engine-owned: with no AVKit in the
//  picture the renderer activates the audio session itself, which is what the
//  multi-stream grid already relies on.
//
//  Chrome: the same UIKit glass rail as Aether VOD (PlayerRailView +
//  PlayerRailPanelView), driven by GUIDE data instead of Plex metadata —
//  programme title/times from LiveTVDataStore's EPG, subtitle and audio
//  pickers from the engine's track lists (CardTrackListView), and a
//  guide-fed info card (LiveGuideInfoCardView). Select shows the rail,
//  Menu hides it (or dismisses the player when it's already hidden).
//
//  Transport (issue #316): the engine keeps a rewind window on every live
//  load, so the stream can be paused and skipped like a recording. With the
//  rail hidden, Left/Right skip within that window and Play/Pause pauses; a
//  timeline (programme bar, a LIVE / "−2:15" badge) comes up on its own for
//  both without taking focus, so the remote keeps skipping. "Go to Live" on
//  the rail returns to the edge. Play/Pause is taken through the same
//  deduping coordinator VOD uses, because it can arrive as a press AND as a
//  system remote command for one click.
//
//  Subtitles (including DVB/teletext decoded engine-side) render through
//  CaptionOverlayView, the same overlay Aether VOD uses.
//
//  Playback routing (inside `AetherPlayer.loadLive`):
//    - plain HLS (.m3u8 / format=hls) → nativeRemoteHLS: AVPlayer plays the
//      remote playlist directly, engine re-attaches its layer to the surface.
//    - raw MPEG-TS and Plex tuned sessions (progressive start.ts remux) →
//      engine demux/decode.
//
//  Failure ladder (each stage re-resolves the URL — fresh Plex tune/session):
//    0 primary → 1 engine demux → 2 bare AVPlayer on an AVPlayerLayer.
//

import AVKit
import AetherEngine
import Combine
import UIKit

final class LiveTVAetherPlayerViewController: UIViewController {

    /// The channel on screen. A `var` because the OSD channel list switches
    /// channels IN PLACE (`switchChannel`) rather than by presenting a new
    /// player — see that method for why.
    private var channel: UnifiedChannel

    private var aetherPlayer: AetherPlayer?

    /// Engine render surface — the only correct way to display Aether video.
    private let engineSurfaceView = AetherPlayerView()

    /// Shown until the first frame plays; the engine spins up demux + decode
    /// before any picture, so give the user something in the meantime.
    private let loadingSpinner = UIActivityIndicatorView(style: .large)

    private let subtitleModel = SubtitleModel()
    private var subtitleOverlay: CaptionOverlayView?
    private var captionStyle: CaptionStyle = CaptionAppearance.current()
    private var cancellables = Set<AnyCancellable>()

    /// Last-resort AVPlayer (fallback stage 2) rendered on its own layer.
    private var lastResortPlayer: AVPlayer?
    private var lastResortLayer: AVPlayerLayer?

    /// Escalating recovery for playback failures (a Plex session can die
    /// server-side after load): 0 = primary, 1 = fresh URL + engine demux,
    /// 2 = fresh URL + bare AVPlayer.
    private var fallbackStage = 0
    private var isFallbackInFlight = false

    /// Plex releases a tuned /livetv/sessions grab unless the client reports
    /// a timeline periodically (300s rolling stop-grab timer server-side).
    /// A `var` because a handed-off session brings its own (see
    /// `detachSession()`).
    private var liveKeepalive = PlexLiveTimelineKeepalive()

    /// A running session to adopt instead of joining, consumed by the first
    /// `startPlayback()`.
    private var pendingAdoption: LiveTVSessionHandoff?

    /// The in-flight stream resolve/load (and its fallback retries). Held so it
    /// can be cancelled on dismissal — otherwise a slow Plex tune could finish
    /// after teardown and spin a new player/keep-alive on an off-screen VC.
    private var streamLoadTask: Task<Void, Never>?

    /// Measures time-to-first-frame for the in-flight join, split into handshake
    /// / engine load / holdback fill. One per load attempt; a fallback retry
    /// starts a fresh one so each attempt is measured separately.
    private var joinTelemetry: LiveJoinTelemetry?

    // MARK: Subtitle delay and height (OSD steppers, sticky per channel)

    /// User subtitle delay for THIS channel. Engine-cue paths apply it through
    /// SubtitleModel.delaySeconds. The native-legible (remote WebVTT) path is
    /// event-driven with timeless cues, so a POSITIVE delay there is applied
    /// by scheduling the model update instead; a NEGATIVE delay can't pre-show
    /// cues that haven't arrived yet, so it's treated as 0 on that path.
    private var subtitleDelaySeconds: Double = 0

    /// This channel's height adjustment, in stepper units. Re-read on every
    /// channel switch so a switch picks up the incoming channel's own value.
    private var subtitleHeightUnits: Int = 0

    private var subtitleMediaKey: String { "live:\(channel.id)" }

    // MARK: Native HLS legible subtitles (remote WebVTT renditions)
    //
    // On the nativeRemoteHLS path the engine never demuxes: the stream's WebVTT
    // renditions live in AVPlayer's legible media selection group, and it
    // publishes no cues of its own. Selecting a rendition isn't enough either —
    // a bare AVPlayerLayer doesn't paint legible content (only AVKit does), so
    // cues are pulled out through an AVPlayerItemLegibleOutput and drawn by the
    // same overlay every other path uses.
    //
    // The engine DOES publish that group as `subtitleTracks` (AE#154), so an
    // empty engine track list no longer distinguishes this path from the demux
    // one. Route detection lives below; do not reintroduce that test.
    /// Whether this session took the `nativeRemoteHLS` bypass.
    ///
    /// AE#154 made the engine publish the bypass item's legible options as
    /// `subtitleTracks`, so "the engine track list is empty" no longer
    /// identifies the native route — it used to, and every branch keyed off it
    /// silently started taking the demux path, handing subtitle selection to
    /// the engine (and rendering to AVPlayer). Branch on the routing decision.
    private var isNativeHLSRoute = false

    /// True when AVPlayer is playing the REMOTE playlist itself, so its legible
    /// renditions are ours to intercept and the engine has no cues of its own.
    ///
    /// Confirmed against the item's URL rather than trusting the routing
    /// decision alone: the engine can move a bypass session onto the
    /// live-ingest loopback mid-load (#168, a native mount that builds no video
    /// track), after which it really is demuxing and really does publish cues.
    /// It exposes no effective-route property to ask, but the loopback item is
    /// served from its local HTTP server, which is plainly visible here.
    private var isPlayingRemoteHLSDirectly: Bool {
        guard isNativeHLSRoute, let item = aetherPlayer?.currentAVPlayer?.currentItem
        else { return false }
        return Self.isRemoteItem(item)
    }

    /// The loopback item is served by the engine's local HTTP server; a bypass
    /// item points at the origin.
    private static func isRemoteItem(_ item: AVPlayerItem) -> Bool {
        guard let asset = item.asset as? AVURLAsset else { return false }
        switch asset.url.host?.lowercased() {
        case "127.0.0.1", "localhost", "::1", nil: return false
        default: return true
        }
    }

    private var nativeLegibleGroup: AVMediaSelectionGroup?
    private var nativeLegibleOutput: AVPlayerItemLegibleOutput?
    private var nativeLegibleBridge: LegibleOutputBridge?
    /// The item the output is attached to. The failure ladder re-resolves the
    /// URL and builds a NEW item; without this the output stays bound to the
    /// dead one and subtitles silently stop.
    private weak var nativeLegibleItem: AVPlayerItem?
    private var nativeLegibleActive = false
    /// Lines currently on screen. Roll-up WebVTT re-delivers the same block
    /// every segment; re-emitting it would churn the cue identities (and
    /// their SwiftUI views) for no visible change.
    private var lastNativeLegibleLines: [StyledLine] = []
    /// Deferred clear: roll-up streams emit an EMPTY legible event at every
    /// cue boundary, and clearing on the spot blinks the overlay between cues.
    private var nativeLegibleClearWorkItem: DispatchWorkItem?
    /// Nested inside the `$currentAVPlayer` sink rather than stored in
    /// `cancellables`, so it can be replaced when the player is swapped.
    /// `startPlayback` builds a fresh `AetherPlayer` per session, so the outer
    /// sink re-subscribes and re-establishes this on every channel switch.
    private var nativeItemObservation: AnyCancellable?

    /// Push-delegate shim: `AVPlayerItemLegibleOutput.setDelegate` does not
    /// retain, so the VC holds this.
    private final class LegibleOutputBridge: NSObject, AVPlayerItemLegibleOutputPushDelegate {
        let onStrings: ([NSAttributedString], CMTime) -> Void
        init(onStrings: @escaping ([NSAttributedString], CMTime) -> Void) {
            self.onStrings = onStrings
        }
        func legibleOutput(_ output: AVPlayerItemLegibleOutput,
                           didOutputAttributedStrings strings: [NSAttributedString],
                           nativeSampleBuffers nativeSamples: [Any],
                           forItemTime itemTime: CMTime) {
            onStrings(strings, itemTime)
        }
    }

    /// tvOS processes a Menu press on a present()-ed modal through a system
    /// gesture that calls `dismiss(animated:)` on this VC, IN PARALLEL to the
    /// responder-chain press. After we consume a Menu press to peel one chrome
    /// layer (close panel / hide rail), this swallows that system echo so it
    /// can't peel a second layer on the same physical press. Same mechanism
    /// the VOD player (PlayerContainerViewController) uses.
    private var blockNextDismiss = false
    /// Cancellable reset for `blockNextDismiss`, so two arms inside the window
    /// can't leave an early-firing timer that clears the flag mid-press.
    private var blockDismissResetWorkItem: DispatchWorkItem?

    // MARK: Chrome state

    /// Which chrome the player wears. `.rail` is the glass rail shared with
    /// VOD (Up Next and Insights hidden: they mean nothing on a broadcast);
    /// `.showcase` is the Browse layout's Apple TV-style chrome.
    enum ChromeStyle {
        case rail
        case showcase
    }

    private let chromeStyle: ChromeStyle
    private let railView: any LivePlayerChrome
    /// The SAME scrubber component VOD uses (same assets + spot in the rail),
    /// but driven non-seekably: it shows the current programme's air window
    /// (start/end wall-clock at the edges, current time on the playhead) with
    /// no scrub interaction. Fades with the rail.
    private let progressBar = PlayerProgressBarView()
    private var railVisible = false
    private var activePanel: PlayerRailPanelView?
    private var autoHideTimer: Timer?
    private var programInfoTimer: Timer?

    /// Invisible focus target that holds focus while the chrome is hidden so
    /// remote presses reach this VC through the responder chain (tvOS routes
    /// presses via the focused view; a fullscreen video with no focusable
    /// content would swallow them).
    private final class FocusCatcherView: UIView {
        override var canBecomeFocused: Bool { true }
    }
    private let focusCatcher = FocusCatcherView()

    /// One front door for transport input. A Play/Pause can reach this VC as a
    /// press and ALSO as a system remote command for the same click; both go
    /// through here and it dedupes them, so the stream toggles once.
    private let inputCoordinator = PlaybackInputCoordinator()
    private var isHandlingPlayPausePress = false

    /// Left/Right skip and Up/Down while the chrome is hidden, for every remote
    /// transport. Installed on the focus catcher, so it only sees input while
    /// the catcher holds focus: exactly while this surface is focusless.
    private var directionalBinding: DirectionalInputBinding?

    /// The viewer's own pause. Kept apart from engine state: a paused live
    /// session keeps buffering, and the timeline stays up while paused.
    private var isUserPaused = false

    /// Timeline without the rail: the programme bar and live badge, shown for
    /// a skip or a pause. Focus stays on the catcher, so Left/Right keep
    /// skipping instead of walking the rail buttons.
    private var timelineVisible = false
    private var timelineHideTimer: Timer?
    /// Refreshes the bar and badge once a second while either is on screen.
    private var timelineTicker: Timer?
    private let timeshiftBadge = LiveTimeshiftBadgeView()
    private let timelineScrim = LiveBottomScrimView()

    /// Called once when the player is dismissed, with the channel on screen at
    /// that moment (the viewer may have changed channels in the player), so
    /// the guide can put focus back on it.
    var onDismiss: ((UnifiedChannel) -> Void)?

    /// The channel currently playing.
    var playingChannel: UnifiedChannel { channel }

    /// Back with the chrome down keeps the channel going somewhere else (the
    /// guide's corner) instead of stopping it, when the host offers a place.
    /// The session is handed over running; the player then closes.
    var onMinimize: ((LiveTVSessionHandoff) -> Void)?

    /// Multiview from the showcase chrome: the running session moves into the
    /// first tile. The host presents multiview once this player has closed.
    var onOpenMultiview: ((LiveTVSessionHandoff) -> Void)?

    init(channel: UnifiedChannel, chromeStyle: ChromeStyle = .rail, adopting session: LiveTVSessionHandoff? = nil) {
        self.channel = session?.channel ?? channel
        self.chromeStyle = chromeStyle
        self.pendingAdoption = session
        switch chromeStyle {
        case .rail: railView = PlayerRailView()
        case .showcase: railView = LiveShowcaseChromeView()
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        engineSurfaceView.frame = view.bounds
        engineSurfaceView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(engineSurfaceView)

        loadingSpinner.color = .white
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loadingSpinner)
        NSLayoutConstraint.activate([
            loadingSpinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        loadingSpinner.startAnimating()

        // ORDER MATTERS: the overlay must be added BEFORE setupChrome, so the
        // rail and progress bar sit in front of it and captions slide up
        // behind the chrome rather than over it. Same z-order as VOD.
        mountSubtitleOverlay()
        observeCaptionAppearance()
        setupChrome()

        inputCoordinator.target = self
        NowPlayingService.shared.attachLive(inputCoordinator: inputCoordinator)
        // Live TV is watched lean-back for long stretches with no input; the
        // screensaver must not take over mid-programme.
        UIApplication.shared.isIdleTimerDisabled = true

        startPlayback()

        // What is already set to record, for the rail's record button.
        Task { @MainActor [weak self] in
            await LiveTVDataStore.shared.refreshScheduledRecordings()
            self?.updateRailContent()
        }
    }

    /// Builds the player for `channel` and starts the join. Called on load and
    /// again for every in-place channel switch, so it must assume NOTHING is
    /// left over from a previous session — `teardownPlaybackSession()` is the
    /// matching half.
    private func startPlayback() {
        loadingSpinner.startAnimating()
        isUserPaused = false

        // Sticky per-channel subtitle delay (OSD stepper). Re-read per channel:
        // the key is derived from the channel id.
        subtitleDelaySeconds = SubtitleAdjustments.delay(forKey: subtitleMediaKey)
        subtitleHeightUnits = SubtitleAdjustments.heightUnits(forMediaKey: subtitleMediaKey)
        subtitleModel.delaySeconds = subtitleDelaySeconds

        let adopted = pendingAdoption
        pendingAdoption = nil
        let aether = adopted?.player ?? AetherPlayer()
        if let adopted {
            liveKeepalive = adopted.keepalive
            isNativeHLSRoute = adopted.isNativeHLSRoute
        }
        aetherPlayer = aether
        aether.bind(view: engineSurfaceView)
        bindAetherSubtitles(aether)
        bindNativeLegibleAttachment(aether)

        aether.playbackStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .playing:
                    self.loadingSpinner.stopAnimating()
                    // Same signal the spinner uses, so the measurement ends
                    // exactly where the user stops waiting. Finishing is
                    // idempotent, so later resumes don't reopen the join.
                    self.finishJoinTelemetry { $0.joined() }
                    self.updateRailContent()
                case .failed:
                    self.finishJoinTelemetry { $0.failed(reason: "state_failed") }
                    guard !self.isFallbackInFlight else { return }
                    self.advanceFallback()
                default:
                    break
                }
            }
            .store(in: &cancellables)

        // The engine parked a source it cannot revive (a transcode that
        // respawned from byte 0, a frozen playlist). Only a fresh URL and a new
        // load bring it back, which for Plex means a new tune.
        aether.liveSourceResets
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rejoinAfterSourceReset() }
            .store(in: &cancellables)

        // Keep the rail's audio meta line current as the engine reports tracks.
        aether.$audioTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateRailContent() }
            .store(in: &cancellables)

        if adopted != nil {
            // Already joined elsewhere and still running: this surface only
            // takes over the picture. No resolve, no tune, no load.
            loadingSpinner.stopAnimating()
            if !aether.intendsToPlay { aether.play() }
            updateRailContent()
            return
        }

        streamLoadTask = Task { @MainActor in
            // Resolve performs the Plex tune step for cloud-EPG/DVB channels;
            // other sources pass straight through.
            joinTelemetry = LiveJoinTelemetry()
            guard let url = await LiveTVDataStore.shared.resolveStreamURL(for: channel) else {
                finishJoinTelemetry { $0.failed(reason: "resolve_failed") }
                if Task.isCancelled { return }
                dismissPlayer()
                return
            }
            if Task.isCancelled { finishJoinTelemetry { $0.abandoned() }; return }
            // Raw tuned-session HLS must go through the engine demuxer:
            // AVPlayer's native HLS path can't decode broadcast mp2 audio
            // or the DVB/teletext subtitles that direct play preserves.
            let forceEngineDemux = url.path.hasPrefix("/livetv/sessions/")
            let route = AetherPlayer.liveRoute(for: url, forceEngineDemux: forceEngineDemux)
            isNativeHLSRoute = route == .nativeHLS
            joinTelemetry?.resolveFinished(url: url, route: route)
            startLiveSessionKeepAlive(for: url)
            do {
                try await aether.loadLive(
                    url: url,
                    headers: LiveTVClientIdentity.streamHeaders(for: channel),
                    forceEngineDemux: forceEngineDemux
                )
                if Task.isCancelled { finishJoinTelemetry { $0.abandoned() }; return }
                joinTelemetry?.loadFinished()
                aether.play()
            } catch {
                if Task.isCancelled { finishJoinTelemetry { $0.abandoned() }; return }
                finishJoinTelemetry { $0.failed(reason: "engine_load_failed") }
                self.advanceFallback()
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || isMovingFromParent else { return }
        teardownPlaybackSession()
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        programInfoTimer?.invalidate()
        programInfoTimer = nil
        blockDismissResetWorkItem?.cancel()
        blockDismissResetWorkItem = nil
        activePanel?.dismissPanel()
        activePanel = nil
        subtitleOverlay?.removeFromSuperview()
        subtitleOverlay = nil
        NotificationCenter.default.removeObserver(
            self,
            name: CaptionAppearance.changedNotification,
            object: nil
        )
        timelineHideTimer?.invalidate()
        timelineHideTimer = nil
        stopTimelineTicker()
        NowPlayingService.shared.detachLive(inputCoordinator: inputCoordinator)
        inputCoordinator.invalidate()
        UIApplication.shared.isIdleTimerDisabled = false
        onDismiss?(channel)
    }

    /// Leaves the player entirely, past every chrome layer. The layered
    /// `dismiss(animated:)` override below peels one layer per Menu press, so
    /// a programmatic exit clears the layers first.
    private func dismissPlayer(completion: (() -> Void)? = nil) {
        activePanel?.dismissPanel()
        activePanel = nil
        railVisible = false
        timelineVisible = false
        blockNextDismiss = false
        super.dismiss(animated: true, completion: completion)
    }

    /// Carry the running channel into multiview as its first tile.
    private func openMultiview() {
        guard let onOpenMultiview, let session = detachSession() else { return }
        dismissPlayer {
            onOpenMultiview(session)
        }
    }

    /// A whole new join on the same channel, after the engine gave up on the
    /// source. Not counted against the fallback ladder: the source died, the
    /// route did not fail.
    private func rejoinAfterSourceReset() {
        guard !isFallbackInFlight, !isBeingDismissed else { return }
        teardownPlaybackSession()
        startPlayback()
    }

    /// Hands the running session to another surface without stopping it: no
    /// re-tune, no gap in the picture. Everything this player hooked onto the
    /// session is unhooked, and the player is left with nothing to tear down.
    /// nil while there is no engine session to hand over (still joining, or
    /// on the last-resort AVPlayer).
    private func detachSession() -> LiveTVSessionHandoff? {
        guard let aether = aetherPlayer, lastResortPlayer == nil, !isJoining else { return nil }
        streamLoadTask?.cancel()
        streamLoadTask = nil
        finishJoinTelemetry { $0.abandoned() }
        cancellables.removeAll()
        nativeItemObservation = nil
        nativeLegibleActive = false
        if let output = nativeLegibleOutput, let item = nativeLegibleItem {
            item.remove(output)
        }
        nativeLegibleOutput = nil
        nativeLegibleBridge = nil
        nativeLegibleItem = nil
        nativeLegibleGroup = nil
        resetNativeLegibleState()
        subtitleModel.update(cues: [])
        aether.unbind(view: engineSurfaceView)

        let handoff = LiveTVSessionHandoff(channel: channel, player: aether,
                                           keepalive: liveKeepalive, isNativeHLSRoute: isNativeHLSRoute)
        aetherPlayer = nil
        // The handed-off session keeps its keepalive; teardown stops this one.
        liveKeepalive = PlexLiveTimelineKeepalive()
        isNativeHLSRoute = false
        return handoff
    }

    /// True between the start of a join and the first frame: the engine is
    /// still loading, so there is nothing yet worth handing over.
    private var isJoining: Bool { loadingSpinner.isAnimating }

    /// Unwinds everything `startPlayback()` set up, leaving the VC's chrome
    /// (rail, overlay host, observers) intact. Used both by dismissal and by
    /// an in-place channel switch, so the two can never drift apart.
    private func teardownPlaybackSession() {
        streamLoadTask?.cancel()
        streamLoadTask = nil
        // Backing out before first frame still ends the transaction. An
        // unfinished one would otherwise hang until the SDK times it out and
        // land as a bogus outlier.
        finishJoinTelemetry { $0.abandoned() }
        stopLiveSessionKeepAlive()
        lastResortPlayer?.pause()
        lastResortPlayer = nil
        lastResortLayer?.removeFromSuperlayer()
        lastResortLayer = nil
        nativeLegibleActive = false
        if let output = nativeLegibleOutput, let item = nativeLegibleItem {
            item.remove(output)
        }
        nativeLegibleOutput = nil
        nativeLegibleBridge = nil
        nativeLegibleItem = nil
        nativeLegibleGroup = nil
        isNativeHLSRoute = false
        nativeItemObservation = nil
        resetNativeLegibleState()
        // Drop the outgoing channel's cues: on a switch the overlay would
        // otherwise keep painting them until the new session publishes.
        subtitleModel.update(cues: [])
        aetherPlayer?.stop()
        aetherPlayer?.unbind(view: engineSurfaceView)
        aetherPlayer = nil
        // Every subscription in this set is bound to the player built by
        // startPlayback(); a stale one would feed the next session's UI from
        // the dead player.
        cancellables.removeAll()
        // Fallback ladder is per-session: a new channel starts at the top.
        fallbackStage = 0
        isFallbackInFlight = false
    }

    // MARK: - Chrome (glass rail + panels)

    private func setupChrome() {
        // Focus catcher: 1pt, transparent, always present.
        focusCatcher.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        focusCatcher.backgroundColor = .clear
        view.addSubview(focusCatcher)
        directionalBinding = DirectionalInputBinding(
            view: focusCatcher,
            directions: [.left, .right, .up, .down],
            onTap: { [weak self] direction in self?.handleHiddenChromeDirection(direction) }
        )

        // Behind the timeline when the rail's glass is not there to carry it.
        // Added before the rail so it can never sit above a rail button.
        timelineScrim.isHidden = true
        timelineScrim.alpha = 0
        view.addSubview(timelineScrim)
        timelineScrim.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            timelineScrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            timelineScrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            timelineScrim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            timelineScrim.heightAnchor.constraint(equalToConstant: 320),
        ])

        railView.alpha = 0
        railView.transform = CGAffineTransform(translationX: 0, y: 24)
        view.addSubview(railView)
        railView.translatesAutoresizingMaskIntoConstraints = false
        progressBar.alpha = 0
        progressBar.transform = CGAffineTransform(translationX: 0, y: 24)
        view.addSubview(progressBar)
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        switch chromeStyle {
        case .rail:
            if let rail = railView as? PlayerRailView {
                // The Up Next slot becomes the channel list on live (same
                // button, same action hook — see setChannelListAvailable).
                rail.setChannelListAvailable(true)
                rail.setInsightsAvailable(false)
                rail.setLoading(false)
            }
            NSLayoutConstraint.activate([
                railView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 90),
                railView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -90),
                railView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -84),
                railView.heightAnchor.constraint(equalToConstant: PlayerRailView.railHeight),
                // Programme progress bar — placed exactly where VOD puts its
                // scrubber (132pt side insets, 34pt up from the rail bottom) so
                // it looks identical; fades with the rail.
                progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 132),
                progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -132),
                progressBar.bottomAnchor.constraint(equalTo: railView.bottomAnchor, constant: -34),
            ])
        case .showcase:
            if let showcase = railView as? LiveShowcaseChromeView {
                NSLayoutConstraint.activate([
                    showcase.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    showcase.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                    showcase.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                    showcase.heightAnchor.constraint(equalToConstant: LiveShowcaseChromeView.height),
                    // The timeline runs through the chrome's own slot for it.
                    progressBar.leadingAnchor.constraint(equalTo: showcase.timelineGuide.leadingAnchor),
                    progressBar.trailingAnchor.constraint(equalTo: showcase.timelineGuide.trailingAnchor),
                    progressBar.topAnchor.constraint(equalTo: showcase.timelineGuide.topAnchor),
                ])
                showcase.onMultiview = { [weak self] in self?.openMultiview() }
                showcase.setMultiviewAvailable(onOpenMultiview != nil)
            }
        }

        // Where the picture sits relative to live. Right-aligned just above the
        // track, which keeps it below the rail's button row.
        timeshiftBadge.isHidden = true
        timeshiftBadge.alpha = 0
        view.addSubview(timeshiftBadge)
        timeshiftBadge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            timeshiftBadge.trailingAnchor.constraint(equalTo: progressBar.trailingAnchor),
            timeshiftBadge.bottomAnchor.constraint(equalTo: progressBar.topAnchor, constant: -10),
        ])

        railView.onSubtitles = { [weak self] in self?.presentSubtitlePanel() }
        railView.onAudio = { [weak self] in self?.presentAudioPanel() }
        railView.onInfo = { [weak self] in self?.presentInfoPanel() }
        railView.onUpNext = { [weak self] in self?.presentChannelListPanel() }
        railView.onGoLive = { [weak self] in self?.goLive() }
        railView.onRecord = { [weak self] in self?.presentRecordPanel() }

        updateRailContent()

        // The guide's "current programme" rolls over on its own clock.
        programInfoTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateRailContent() }
        }
    }

    /// Rail metadata from GUIDE data: programme title, channel line, air
    /// window, and the engine's current audio track. Timeshift-aware: a viewer
    /// behind live is watching the past, so the programme, the bar and the
    /// clock label describe the picture on screen, not the wall clock.
    private func updateRailContent() {
        let store = LiveTVDataStore.shared
        let shift = aetherPlayer?.liveTimeshift ?? AetherPlayer.LiveTimeshift.idle
        let hasRewindWindow = shift.seekableRange != nil
        let behind = hasRewindWindow ? max(0, shift.behindLiveSeconds) : 0
        let now = Date()
        let onScreenAt = now.addingTimeInterval(-behind)
        let current = store.program(for: channel, at: onScreenAt) ?? store.getCurrentProgram(for: channel)

        let eyebrow = [channel.channelNumber.map(String.init), channel.name]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        railView.setTitle(current?.title ?? channel.name, eyebrow: eyebrow.isEmpty ? nil : eyebrow)

        var runtime: String?
        if let current {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            runtime = "\(formatter.string(from: current.startTime)) – \(formatter.string(from: current.endTime))"
        }

        let isBehindLive = hasRewindWindow && behind >= LiveTimeshiftBadgeView.liveToleranceSeconds

        // Programme progress bar: the show's air window, the playhead at the
        // picture on screen, and (when timeshifted) the buffered stretch up to
        // now. Hidden when there's no guide data to anchor to.
        if let current, current.endTime > current.startTime {
            progressBar.isHidden = false
            progressBar.updateLiveTimeline(
                startTime: current.startTime,
                currentTime: onScreenAt,
                endTime: current.endTime,
                liveEdgeTime: isBehindLive ? now : nil
            )
        } else {
            progressBar.isHidden = true
        }

        timeshiftBadge.update(behindLiveSeconds: behind, hasRewindWindow: hasRewindWindow,
                              isPaused: isUserPaused)
        railView.setTimeshift(behindLiveSeconds: behind, hasRewindWindow: hasRewindWindow,
                              isPaused: isUserPaused)
        railView.setGoLiveAvailable(isBehindLive)
        railView.setRecordState(
            available: store.canRecord(channel) && current != nil,
            isRecording: current.map { store.activeRecording(for: $0) != nil } ?? false
        )

        var audioDescription: String?
        if let aether = aetherPlayer,
           let activeId = aether.currentAudioTrackId,
           let track = aether.audioTracks.first(where: { $0.id == activeId }) {
            audioDescription = [track.language, track.codec?.uppercased()]
                .compactMap { $0 }
                .joined(separator: " ")
        }

        // The badge says LIVE / how far behind; the chip only repeats it at the
        // edge, where it is the programme's defining fact.
        railView.setMeta(rating: isBehindLive ? nil : "LIVE", runtime: runtime, audio: audioDescription)

        NowPlayingService.shared.updateLive(
            title: current?.title ?? channel.name,
            channelName: channel.name,
            isPlaying: !isUserPaused
        )
    }

    private func showRail() {
        guard !railVisible else { return }
        railVisible = true
        timelineHideTimer?.invalidate()
        timelineHideTimer = nil
        updateRailContent()
        setTimelineElementsVisible(true)
        UIView.animate(withDuration: 0.25) {
            self.railView.alpha = 1
            self.railView.transform = .identity
        }
        syncSubtitleOverlay(animated: true)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        restartAutoHide()
    }

    private func hideRail() {
        guard railVisible else { return }
        railVisible = false
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        railView.resetFocusMemory()
        UIView.animate(withDuration: 0.2) {
            self.railView.alpha = 0
            self.railView.transform = CGAffineTransform(translationX: 0, y: 24)
        }
        // A paused picture keeps its timeline: it is the only sign the stream
        // is paused rather than frozen.
        if isUserPaused {
            timelineVisible = true
            UIView.animate(withDuration: 0.2) { self.timeshiftBadge.alpha = 1 }
        } else {
            setTimelineElementsVisible(false)
        }
        syncSubtitleOverlay(animated: true)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    /// Chrome auto-hides after a few idle seconds, same spirit as the VOD
    /// container. Any focus movement inside the rail restarts the clock; an
    /// open panel suspends it.
    private func restartAutoHide() {
        autoHideTimer?.invalidate()
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.activePanel == nil else { return }
                self.hideRail()
            }
        }
    }

    // MARK: - Timeline (without the rail)

    /// The programme bar, the live badge and the scrim behind them. Shown with
    /// the rail, and on their own for a skip or a pause.
    private func setTimelineElementsVisible(_ visible: Bool) {
        if visible {
            [timelineScrim, timeshiftBadge].forEach { $0.isHidden = false }
            startTimelineTicker()
        } else {
            stopTimelineTicker()
        }
        UIView.animate(withDuration: visible ? 0.25 : 0.2, animations: {
            self.progressBar.alpha = visible ? 1 : 0
            self.progressBar.transform = visible ? .identity : CGAffineTransform(translationX: 0, y: 24)
            self.timeshiftBadge.alpha = (visible && self.badgeShowsWithChrome) ? 1 : 0
            // The rail's own glass carries the bar when it is up.
            self.timelineScrim.alpha = visible ? 1 : 0
        }, completion: { _ in
            // Hidden, not just transparent: nothing may sit over a focus
            // target at alpha 0 and still count in the occlusion test.
            guard !visible, !self.timelineVisible, !self.railVisible else { return }
            self.timelineScrim.isHidden = true
            self.timeshiftBadge.isHidden = true
        })
        if !visible { timelineVisible = false }
    }

    /// The showcase chrome says LIVE / how far behind in its own pill, so the
    /// separate badge only shows there while the chrome itself is down.
    private var badgeShowsWithChrome: Bool {
        chromeStyle == .rail || !railVisible
    }

    /// Bring the timeline up without the rail and without moving focus, then
    /// let it go again after a few seconds unless the stream is paused. With
    /// the rail already up this only refreshes it.
    private func flashTimeline() {
        updateRailContent()
        if railVisible {
            restartAutoHide()
            return
        }
        if !timelineVisible {
            timelineVisible = true
            setTimelineElementsVisible(true)
            syncSubtitleOverlay(animated: true)
        }
        timelineHideTimer?.invalidate()
        timelineHideTimer = nil
        guard !isUserPaused else { return }
        timelineHideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.hideTimeline() }
        }
    }

    private func hideTimeline() {
        timelineHideTimer?.invalidate()
        timelineHideTimer = nil
        guard timelineVisible, !railVisible else { return }
        setTimelineElementsVisible(false)
        syncSubtitleOverlay(animated: true)
    }

    private func startTimelineTicker() {
        guard timelineTicker == nil else { return }
        timelineTicker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateRailContent() }
        }
    }

    private func stopTimelineTicker() {
        timelineTicker?.invalidate()
        timelineTicker = nil
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let activePanel { return [activePanel] }
        return railVisible ? [railView] : [focusCatcher]
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if railVisible, activePanel == nil,
           let next = context.nextFocusedView, next.isDescendant(of: railView) {
            restartAutoHide()
        }
    }

    // MARK: - Panels

    private func presentPanel(content: UIView, width: CGFloat) {
        guard activePanel == nil else { return }
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        let panel = PlayerRailPanelView.present(
            content: content,
            width: width,
            in: view,
            aboveRail: railView.panelAnchor,
            towards: railView.panelAnchor
        )
        panel.onDismiss = { [weak self] in
            guard let self else { return }
            self.activePanel = nil
            self.setNeedsFocusUpdate()
            self.updateFocusIfNeeded()
            self.restartAutoHide()
        }
        // While focus is inside the panel it owns Menu itself (its own
        // pressesBegan closes it), so the VC's dismiss() funnel is bypassed —
        // arm the echo block here instead so the parallel system dismiss
        // can't peel the rail (or the player) on the same press.
        panel.onMenuHandled = { [weak self] in
            self?.armDismissEchoBlock()
        }
        activePanel = panel
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func presentSubtitlePanel() {
        guard let aether = aetherPlayer else { return }

        // Engine demux path: tracks come from the engine, and so do cues.
        // Never taken on the bypass, where the engine's published tracks are
        // AE#154 mirrors of AVPlayer's legible options and selecting one hands
        // rendering to AVPlayerLayer instead of our overlay.
        if !isPlayingRemoteHLSDirectly, !aether.subtitleTracks.isEmpty {
            var steppers = subtitleAdjustmentSteppers()
            if aether.subtitleTracks.contains(where: { ($0.codec ?? "").lowercased().contains("teletext") }) {
                steppers.append(teletextPageStepper())
            }
            let list = CardTrackListView(
                header: "Subtitles",
                tracks: aether.subtitleTracks,
                selectedTrackId: aether.currentSubtitleTrackId,
                showsOffRow: true,
                steppers: steppers
            ) { [weak self] trackId in
                self?.aetherPlayer?.selectSubtitleTrack(id: trackId)
                self?.activePanel?.dismissPanel()
            }
            presentPanel(content: list, width: 520)
            return
        }

        // nativeRemoteHLS path: the engine never demuxes, so list the REMOTE
        // playlist's WebVTT renditions out of AVPlayer's legible group.
        guard let item = aether.currentAVPlayer?.currentItem else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  !group.options.isEmpty else { return }
            self.nativeLegibleGroup = group

            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            let selectedIndex = selected.flatMap { group.options.firstIndex(of: $0) }
            let tracks = group.options.enumerated().map { index, option in
                MediaTrack(
                    id: index,
                    name: option.displayName,
                    language: option.locale.map { Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier },
                    languageCode: option.locale?.identifier,
                    codec: "webvtt"
                )
            }
            let list = CardTrackListView(
                header: "Subtitles",
                tracks: tracks,
                selectedTrackId: selectedIndex,
                showsOffRow: true,
                steppers: self.subtitleAdjustmentSteppers()
            ) { [weak self] trackId in
                self?.selectNativeLegible(trackId)
                self?.activePanel?.dismissPanel()
            }
            self.presentPanel(content: list, width: 520)
        }
    }

    private func presentAudioPanel() {
        guard let aether = aetherPlayer else { return }

        // Engine demux path: tracks come from the engine.
        if !aether.audioTracks.isEmpty {
            let list = CardTrackListView(
                header: "Audio",
                tracks: aether.audioTracks,
                selectedTrackId: aether.currentAudioTrackId,
                showsOffRow: false
            ) { [weak self] trackId in
                if let trackId { self?.aetherPlayer?.selectAudioTrack(id: trackId) }
                self?.activePanel?.dismissPanel()
                self?.updateRailContent()
            }
            presentPanel(content: list, width: 520)
            return
        }

        // nativeRemoteHLS path: list AVPlayer's audible media selection.
        guard let item = aether.currentAVPlayer?.currentItem else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
                  !group.options.isEmpty else { return }

            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            let selectedIndex = selected.flatMap { group.options.firstIndex(of: $0) }
            let tracks = group.options.enumerated().map { index, option in
                MediaTrack(
                    id: index,
                    name: option.displayName,
                    language: option.locale.map { Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier },
                    languageCode: option.locale?.identifier
                )
            }
            let list = CardTrackListView(
                header: "Audio",
                tracks: tracks,
                selectedTrackId: selectedIndex,
                showsOffRow: false
            ) { [weak self] trackId in
                if let trackId, trackId < group.options.count {
                    item.select(group.options[trackId], in: group)
                }
                self?.activePanel?.dismissPanel()
                self?.updateRailContent()
            }
            self.presentPanel(content: list, width: 520)
        }
    }

    // MARK: - Native legible (remote WebVTT) rendering

    /// Select (or clear, with nil) a remote WebVTT rendition and attach the
    /// legible output that feeds its cues to our overlay — an AVPlayerLayer
    /// does not paint legible content on its own.
    private func selectNativeLegible(_ index: Int?) {
        guard let aether = aetherPlayer,
              let item = aether.currentAVPlayer?.currentItem,
              let group = nativeLegibleGroup else { return }

        if let index, index < group.options.count {
            ensureNativeLegibleOutput(on: item)
            nativeLegibleActive = true
            item.select(group.options[index], in: group)
        } else {
            nativeLegibleActive = false
            item.select(nil, in: group)
            resetNativeLegibleState()
            subtitleModel.update(cues: [])
        }
    }

    /// Attach the legible output to every native item, as soon as it exists.
    ///
    /// Two things this deliberately does NOT do, both of which broke it before:
    ///
    /// It does not run once after `loadLive` returns. `engine.load` returns
    /// when the native host is mounted, several seconds before the item is
    /// ready (device: `readyToPlay` at t+4.5s), so a one-shot attach races
    /// AVFoundation's automatic selection and loses.
    ///
    /// It does not wait for a selection to exist, or adopt one.
    /// `suppressesPlayerRendering` applies to whatever legible option is or
    /// LATER BECOMES selected, so the output only has to be on the item before
    /// the first cue is drawn. Gating on a current selection just reintroduced
    /// the race. Automatic selection is left alone on purpose: it honours the
    /// system captioning preference and the preferred languages `loadLive`
    /// passes, and disabling it would mean nothing is ever selected at all.
    private func bindNativeLegibleAttachment(_ aether: AetherPlayer) {
        aether.$currentAVPlayer
            .receive(on: DispatchQueue.main)
            .sink { [weak self] player in
                guard let self, let player else { return }
                // Aether swaps the item under us (retune, #93 item-death
                // revive), and each new item needs its own output.
                self.nativeItemObservation = player.publisher(for: \.currentItem)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] item in
                        guard let self, let item else { return }
                        self.attachNativeLegible(to: item)
                    }
            }
            .store(in: &cancellables)
    }

    private func attachNativeLegible(to item: AVPlayerItem) {
        guard isNativeHLSRoute, Self.isRemoteItem(item), nativeLegibleItem !== item else { return }

        // Attached NOW, not after readiness. AVFoundation makes its automatic
        // legible selection around `readyToPlay` (t+4.5s on device) and renders
        // that option natively from the very first cue. An output attached
        // after has already lost the first pass — which is why captions came up
        // in AVPlayer's own rendering on a live HLS channel until the user
        // toggled them off and on, at which point the now-attached output took
        // over and they became ours.
        //
        // Being early is free: `suppressesPlayerRendering` applies to whatever
        // option is or later becomes selected, so the output does not need a
        // selection to exist yet. Waiting was defensive — "nothing attached
        // until the item loads, so this can never be why a stream fails" — but
        // an AVPlayerItemLegibleOutput is a passive attachment, and the cost of
        // the caution was a wrong first render on every channel.
        ensureNativeLegibleOutput(on: item)
        nativeLegibleActive = true

        Task { @MainActor [weak self] in
            // The GROUP is only needed so the subtitle panel can list and switch
            // renditions, and it genuinely does need a loaded asset. Cue
            // delivery does not depend on it: the output is already on the item
            // and receives whatever automatic selection settles on.
            guard await Self.itemBecameReady(item) else { return }
            guard let self,
                  self.isNativeHLSRoute,
                  self.nativeLegibleItem === item,
                  item === self.aetherPlayer?.currentAVPlayer?.currentItem else { return }

            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  !group.options.isEmpty, self.nativeLegibleItem === item else { return }
            self.nativeLegibleGroup = group
        }
    }

    /// Resolves true once `item` is playable, false if it fails first.
    private static func itemBecameReady(_ item: AVPlayerItem) async -> Bool {
        if item.status != .unknown { return item.status == .readyToPlay }
        for await status in item.publisher(for: \.status).values where status != .unknown {
            return status == .readyToPlay
        }
        return false
    }

    private func resetNativeLegibleState() {
        nativeLegibleClearWorkItem?.cancel()
        nativeLegibleClearWorkItem = nil
        lastNativeLegibleLines = []
    }

    private func ensureNativeLegibleOutput(on item: AVPlayerItem) {
        // Re-attach when the item changed under us (failure-ladder retune).
        guard nativeLegibleOutput == nil || nativeLegibleItem !== item else { return }
        if let existing = nativeLegibleOutput, let oldItem = nativeLegibleItem {
            oldItem.remove(existing)
        }
        resetNativeLegibleState()

        let bridge = LegibleOutputBridge { [weak self] strings, itemTime in
            self?.handleNativeLegible(strings: strings, at: itemTime)
        }
        let output = AVPlayerItemLegibleOutput()
        // The engine's surface hosts a REAL AVPlayerLayer on the
        // nativeRemoteHLS path, and AVPlayerLayer paints selected legible
        // content itself. This defaults to FALSE, so without it the native
        // render stacks on top of our overlay: double captions, and the
        // native roll-up repaint reads as constant blinking.
        output.suppressesPlayerRendering = true
        // Content-specified styling ONLY. `.default` bakes the user's caption
        // appearance into every run, which would make every cue look
        // "content-coloured" and defeat the Video Override gate in the overlay
        // (CaptionStyle.allowsContentColor). With .sourceAndRulesOnly a colour
        // attribute is present iff the WebVTT actually specified one.
        output.textStylingResolution = .sourceAndRulesOnly
        output.setDelegate(bridge, queue: .main)
        item.add(output)
        nativeLegibleBridge = bridge
        nativeLegibleOutput = output
        nativeLegibleItem = item
    }

    /// Each legible-output event replaces the on-screen text wholesale (open
    /// ended: valid until the next event, mirroring how the engine's teletext
    /// cues behave). Anti-blink measures for roll-up WebVTT:
    ///  - EMPTY events fire at every cue boundary, so the clear is deferred
    ///    ~0.5s and cancelled when the next cue arrives.
    ///  - Identical re-emissions (the same block re-delivered each segment)
    ///    are ignored so cue identities — and their SwiftUI views — survive.
    ///  - Cues are TIMELESS (startTime 0, endTime huge). This pipeline is
    ///    event-driven — whatever the last event delivered IS what's on screen
    ///    — so cues must never be gated by SubtitleModel's clock: the legible
    ///    output's itemTime is on the AVPlayerItem axis while the model runs
    ///    on the engine's sourceTime axis (different on live HLS), and legible
    ///    events can arrive AHEAD of display time. Either mismatch would make
    ///    time-stamped cues flicker around the clock boundary.
    private func handleNativeLegible(strings: [NSAttributedString], at itemTime: CMTime) {
        let lines = strings.compactMap(Self.styledLine(from:))

        if lines.isEmpty {
            guard nativeLegibleClearWorkItem == nil, !lastNativeLegibleLines.isEmpty else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.nativeLegibleClearWorkItem = nil
                self.lastNativeLegibleLines = []
                self.applyNativeLegible(cues: [])
            }
            nativeLegibleClearWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            return
        }

        // Real text cancels any pending boundary clear.
        nativeLegibleClearWorkItem?.cancel()
        nativeLegibleClearWorkItem = nil

        guard lines != lastNativeLegibleLines else { return }
        lastNativeLegibleLines = lines

        let cues = lines.enumerated().map { index, line -> AetherSubtitleCue in
            AetherSubtitleCue(
                id: index,
                startTime: 0,
                endTime: .greatestFiniteMagnitude,
                body: .styledText(line.runs),
                placement: line.placement
            )
        }
        applyNativeLegible(cues: cues)
    }

    /// Pushes a native-legible model update, honouring a POSITIVE per-channel
    /// delay by deferring it. These cues are timeless, so the model's clock
    /// can't shift them — a constant deadline preserves event order, and a
    /// negative delay is treated as 0 (can't pre-show cues not yet delivered).
    private func applyNativeLegible(cues: [AetherSubtitleCue]) {
        let delay = max(0, subtitleDelaySeconds)
        if delay == 0 {
            subtitleModel.update(cues: cues)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.nativeLegibleActive else { return }
                self.subtitleModel.update(cues: cues)
            }
        }
    }

    // MARK: - Subtitle adjustment steppers

    /// The Delay + Height steppers shared by both subtitle-panel branches
    /// (engine tracks and native legible renditions).
    private func subtitleAdjustmentSteppers() -> [CardStepperConfig] {
        [
            CardStepperConfig(
                title: "Delay",
                value: { [weak self] in SubtitleAdjustments.formattedDelay(self?.subtitleDelaySeconds ?? 0) },
                onStep: { [weak self] step in self?.adjustSubtitleDelay(bySteps: step) }),
            CardStepperConfig(
                title: "Height",
                value: { [weak self] in
                    SubtitleAdjustments.formattedHeight(self?.subtitleHeightUnits ?? 0)
                },
                onStep: { [weak self] step in self?.adjustSubtitleHeight(bySteps: step) }),
        ]
    }

    /// Teletext captions live on a page, and not every broadcaster flags
    /// theirs, so auto-detect can come up empty. Steps through the pages
    /// captions are commonly carried on; the engine re-decodes immediately.
    private static let teletextPages: [Int?] = [nil, 801, 888, 777, 150, 199]

    private func teletextPageStepper() -> CardStepperConfig {
        CardStepperConfig(
            title: "Teletext Page",
            value: { [weak self] in
                guard let page = self?.aetherPlayer?.teletextPage else { return "Auto" }
                return String(page)
            },
            onStep: { [weak self] step in
                guard let aether = self?.aetherPlayer else { return }
                let pages = Self.teletextPages
                let index = pages.firstIndex(of: aether.teletextPage) ?? 0
                let next = (index + step % pages.count + pages.count) % pages.count
                aether.setTeletextPage(pages[next])
            })
    }

    /// Steps this channel's subtitle height, applies it live, and persists it.
    private func adjustSubtitleHeight(bySteps steps: Int) {
        SubtitleAdjustments.setHeightUnits(subtitleHeightUnits + steps,
                                           forMediaKey: subtitleMediaKey)
        subtitleHeightUnits = SubtitleAdjustments.heightUnits(forMediaKey: subtitleMediaKey)
        syncSubtitleOverlay()
    }

    /// Steps this channel's subtitle delay, applies it live, and persists it.
    private func adjustSubtitleDelay(bySteps steps: Int) {
        let raw = subtitleDelaySeconds + Double(steps) * SubtitleAdjustments.delayStep
        subtitleDelaySeconds = SubtitleAdjustments.roundedDelay(raw)
        subtitleModel.delaySeconds = subtitleDelaySeconds
        SubtitleAdjustments.setDelay(subtitleDelaySeconds, forKey: subtitleMediaKey)
    }

    /// One legible-output attributed string: its styled runs plus the
    /// placement the cue asked for.
    private struct StyledLine: Equatable {
        let runs: [AetherSubtitleCue.StyledRun]
        var placement: AetherSubtitleCue.TextPlacement?
    }

    /// Converts a legible-output attributed string into styled runs.
    ///
    /// This is the ONLY way styling reaches the overlay on the remote-HLS
    /// path: the rendition belongs to AVPlayer, the engine never demuxes it,
    /// so nothing arrives on `subtitleCues` and the 5.26.0 / 5.27.0 engine
    /// styling does not apply here. AVFoundation does surface the full
    /// text-markup set on the legible output, so the same attributes are
    /// recovered from it instead — every one present iff the WebVTT actually
    /// specified it, thanks to `.sourceAndRulesOnly`.
    ///
    /// Whitespace-only strings return nil; edge whitespace is trimmed so
    /// placement matches the plain-text path.
    private static func styledLine(from attr: NSAttributedString) -> StyledLine? {
        guard !attr.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let colorKey = NSAttributedString.Key(kCMTextMarkupAttribute_ForegroundColorARGB as String)
        let boldKey = NSAttributedString.Key(kCMTextMarkupAttribute_BoldStyle as String)
        let italicKey = NSAttributedString.Key(kCMTextMarkupAttribute_ItalicStyle as String)
        let underlineKey = NSAttributedString.Key(kCMTextMarkupAttribute_UnderlineStyle as String)
        let faceKey = NSAttributedString.Key(kCMTextMarkupAttribute_FontFamilyName as String)
        let sizeKey = NSAttributedString.Key(kCMTextMarkupAttribute_RelativeFontSize as String)

        let ns = attr.string as NSString
        var runs: [AetherSubtitleCue.StyledRun] = []
        attr.enumerateAttributes(in: NSRange(location: 0, length: attr.length)) { attrs, range, _ in
            let text = ns.substring(with: range)
            var color: UIColor?
            if let argb = attrs[colorKey] as? [NSNumber], argb.count == 4 {
                color = UIColor(red: CGFloat(argb[1].doubleValue),
                                green: CGFloat(argb[2].doubleValue),
                                blue: CGFloat(argb[3].doubleValue),
                                alpha: CGFloat(argb[0].doubleValue))
            }
            // Relative size is a PERCENTAGE of the default cue size; the
            // renderer wants ASS play-resolution points, so convert through
            // the same nominal 16pt the engine's synthesised lines use.
            var fontSize: Int?
            if let percent = (attrs[sizeKey] as? NSNumber)?.doubleValue,
               percent > 0, abs(percent - 100) > 0.5 {
                fontSize = Int((percent / 100 * 16).rounded())
            }
            runs.append(AetherSubtitleCue.StyledRun(
                text: text,
                color: color,
                isBold: (attrs[boldKey] as? NSNumber)?.boolValue ?? false,
                isItalic: (attrs[italicKey] as? NSNumber)?.boolValue ?? false,
                isUnderlined: (attrs[underlineKey] as? NSNumber)?.boolValue ?? false,
                fontName: attrs[faceKey] as? String,
                fontSize: fontSize
            ))
        }

        if var first = runs.first {
            first.text = String(first.text.drop(while: \.isWhitespace))
            runs[0] = first
        }
        if var last = runs.last {
            while let c = last.text.last, c.isWhitespace { last.text.removeLast() }
            runs[runs.count - 1] = last
        }
        runs.removeAll { $0.text.isEmpty }
        guard !runs.isEmpty else { return nil }

        return StyledLine(runs: runs, placement: cuePlacement(from: attr))
    }

    /// The cue's own placement, from the cue-level markup attributes (uniform
    /// across the string, so read at index 0).
    ///
    /// WebVTT `line` is a percentage down the frame and `position` a
    /// percentage across; `align` gives the column. Mapped to the same ASS
    /// numpad + normalized-anchor model the engine uses on its own demux
    /// path, so the overlay places an engine cue and an AVPlayer cue the same
    /// way. Anchored to the frame edge the line is nearer, matching how the
    /// engine resolves it (AE 5.27.0) — the spec's default line alignment
    /// pins the box top, which would hang a two-line cue off the bottom at
    /// `line:90%`.
    ///
    /// nil when the cue asked for nothing, which is the common case and puts
    /// it in the overlay's default band.
    private static func cuePlacement(from attr: NSAttributedString) -> AetherSubtitleCue.TextPlacement? {
        guard attr.length > 0 else { return nil }
        let attrs = attr.attributes(at: 0, effectiveRange: nil)
        let lineKey = NSAttributedString.Key(
            kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection as String)
        let posKey = NSAttributedString.Key(
            kCMTextMarkupAttribute_TextPositionPercentageRelativeToWritingDirection as String)
        let alignKey = NSAttributedString.Key(kCMTextMarkupAttribute_Alignment as String)

        let linePercent = (attrs[lineKey] as? NSNumber)?.doubleValue
        let posPercent = (attrs[posKey] as? NSNumber)?.doubleValue
        let alignment = attrs[alignKey] as? String
        guard linePercent != nil || posPercent != nil || alignment != nil else { return nil }

        // Column: 0 left, 1 centre, 2 right.
        var col = 1
        if let alignment {
            if alignment == (kCMTextMarkupAlignmentType_Start as String)
                || alignment == (kCMTextMarkupAlignmentType_Left as String) {
                col = 0
            } else if alignment == (kCMTextMarkupAlignmentType_End as String)
                || alignment == (kCMTextMarkupAlignmentType_Right as String) {
                col = 2
            }
        }

        // Row: numpad 0 bottom, 1 middle, 2 top. Without a line the cue keeps
        // only its column, so it stays in the default band horizontally
        // placed — an anchor point needs both axes to mean anything.
        guard let linePercent else {
            return AetherSubtitleCue.TextPlacement(alignment: col + 1, position: nil)
        }
        let y = min(max(linePercent / 100, 0), 1)
        let row = y < 0.34 ? 2 : (y < 0.67 ? 1 : 0)

        let x = posPercent.map { min(max($0 / 100, 0), 1) } ?? 0.5
        return AetherSubtitleCue.TextPlacement(
            alignment: row * 3 + col + 1,
            position: CGPoint(x: x, y: y)
        )
    }

    /// The live counterpart of the VOD OSD's season list: every channel in
    /// guide order, opened scrolled to the one playing, with 16:9 programme
    /// art, "504 · Fox Footy", and the current programme title.
    private func presentChannelListPanel() {
        let store = LiveTVDataStore.shared
        let channels = store.channels
        guard !channels.isEmpty else { return }

        let list = ChannelListPanelView(
            channels: channels,
            currentChannelId: channel.id,
            programProvider: { store.getCurrentProgram(for: $0) }
        ) { [weak self] selected in
            self?.activePanel?.dismissPanel()
            self?.switchChannel(to: selected)
        }
        presentPanel(content: list, width: 520)
    }

    /// Switches channels IN PLACE: tear the current session down, adopt the
    /// new channel, start again. The VC, its chrome, and the render surface
    /// all survive.
    ///
    /// Deliberately not "dismiss self and present a fresh player": this VC is
    /// presented from a SwiftUI host whose view leaves the window hierarchy
    /// while the player covers it, so the re-present landed on a detached
    /// controller ("whose view is not in the window hierarchy") — the new
    /// player loaded its stream but never appeared, and the outgoing one kept
    /// running because its teardown is driven by `viewDidDisappear`, which
    /// never came. Reloading in place has no such dependency, and skips a
    /// full modal transition per channel change.
    private func switchChannel(to newChannel: UnifiedChannel) {
        guard newChannel.id != channel.id else { return }
        teardownPlaybackSession()
        channel = newChannel
        // Rail must not keep showing the old channel's programme while the
        // new one resolves.
        updateRailContent()
        startPlayback()
    }

    // MARK: - Recording

    /// The programme on screen right now (behind live, that is an earlier one).
    private func programOnScreen() -> UnifiedProgram? {
        let store = LiveTVDataStore.shared
        let shift = aetherPlayer?.liveTimeshift ?? AetherPlayer.LiveTimeshift.idle
        let behind = shift.seekableRange == nil ? 0 : max(0, shift.behindLiveSeconds)
        return store.program(for: channel, at: Date().addingTimeInterval(-behind))
            ?? store.getCurrentProgram(for: channel)
    }

    /// Record the programme on screen, or cancel its recording, in the rail's
    /// own panel rather than a modal over the player.
    private func presentRecordPanel() {
        let store = LiveTVDataStore.shared
        guard let program = programOnScreen(), store.canRecord(channel) else { return }
        let channel = self.channel

        if let recording = store.activeRecording(for: program) {
            var rows = [CardTrackListView.Row(title: "Cancel Recording", subtitle: program.title,
                                              trackId: 0, isSelected: false)]
            if recording.ruleIsSeries {
                rows.append(CardTrackListView.Row(title: "Cancel Series", subtitle: "Stop recording \(recording.title)",
                                                  trackId: 1, isSelected: false))
            }
            let list = CardTrackListView(header: "Recording", rows: rows) { [weak self] choice in
                self?.activePanel?.dismissPanel()
                Task { @MainActor [weak self] in
                    do {
                        if choice == 1 {
                            try await store.cancelSeries(of: recording)
                        } else {
                            try await store.cancel(recording)
                        }
                    } catch {
                        self?.presentMessagePanel(title: "Couldn't Cancel", message: error.localizedDescription)
                    }
                    self?.updateRailContent()
                }
            }
            presentPanel(content: list, width: 520)
            return
        }

        Task { @MainActor [weak self] in
            let options: [LiveTVRecordOption]
            do {
                options = try await store.recordOptions(for: program, on: channel)
            } catch {
                self?.presentMessagePanel(title: "Can't Record", message: error.localizedDescription)
                return
            }
            guard let self, self.channel.id == channel.id else { return }
            guard !options.isEmpty else {
                self.presentMessagePanel(title: "Can't Record",
                                         message: "The server offered no way to record this programme.")
                return
            }
            let rows = options.enumerated().map { index, option in
                CardTrackListView.Row(title: option.title, subtitle: nil, trackId: index, isSelected: false)
            }
            let list = CardTrackListView(header: program.title, rows: rows) { [weak self] choice in
                self?.activePanel?.dismissPanel()
                guard let choice, choice < options.count else { return }
                Task { @MainActor [weak self] in
                    do {
                        try await store.record(options[choice], program: program, on: channel)
                    } catch {
                        self?.presentMessagePanel(title: "Couldn't Record", message: error.localizedDescription)
                    }
                    self?.updateRailContent()
                }
            }
            self.presentPanel(content: list, width: 560)
        }
    }

    /// A one-row panel that says what went wrong; selecting it closes it.
    private func presentMessagePanel(title: String, message: String) {
        guard activePanel == nil else { return }
        let list = CardTrackListView(
            header: title,
            rows: [CardTrackListView.Row(title: "OK", subtitle: message, trackId: 0, isSelected: false)]
        ) { [weak self] _ in
            self?.activePanel?.dismissPanel()
        }
        presentPanel(content: list, width: 560)
    }

    private func presentInfoPanel() {
        let card = LiveGuideInfoCardView(
            channel: channel,
            current: LiveTVDataStore.shared.getCurrentProgram(for: channel),
            next: LiveTVDataStore.shared.getNextProgram(for: channel)
        )
        presentPanel(content: card, width: 560)
        card.onFocusChange = { [weak self] focused in
            self?.activePanel?.setFocusHighlight(focused)
        }
    }

    // MARK: - Remote handling

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.type {
            case .menu:
                // Route through dismiss(animated:): its override peels one
                // layer at a time (panel → rail → timeline → player) and is the
                // SAME funnel the parallel system Menu gesture hits, so both
                // delivery routes make one consistent decision.
                dismiss(animated: true)
                return
            case .select:
                if !railVisible {
                    showRail()
                    return
                }
            case .playPause:
                // Honored whatever holds focus. The coordinator dedupes this
                // against the same click arriving as a system remote command.
                isHandlingPlayPausePress = true
                inputCoordinator.handle(action: .playPause, source: .irPress)
                return
            case .pageUp:
                // The channel keys some IR and HDMI-CEC remotes carry.
                zapChannel(by: 1)
                return
            case .pageDown:
                zapChannel(by: -1)
                return
            default:
                break
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Menu is fully consumed at began; an unswallowed ended phase bubbles
        // to the system and peels an extra layer. Same for a Play/Pause taken
        // at began: its ended phase must not reach the system as a second one.
        for press in presses where press.type == .menu { return }
        for press in presses where press.type == .playPause && isHandlingPlayPausePress {
            isHandlingPlayPausePress = false
            return
        }
        for press in presses where press.type == .pageUp || press.type == .pageDown { return }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .playPause && isHandlingPlayPausePress {
            isHandlingPlayPausePress = false
            return
        }
        super.pressesCancelled(presses, with: event)
    }

    /// Menu peels ONE layer at a time: panel → rail → timeline → player. Both
    /// delivery routes — the responder-chain press (pressesBegan) and tvOS's
    /// parallel system Menu gesture — reach dismiss(), so the layering
    /// decision lives HERE and stays consistent whichever fires first.
    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        // Something presented over the player (an alert) is dismissing
        // itself, which UIKit routes through here. That is its dismissal, not
        // a Menu press on the player.
        if presentedViewController != nil {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        if blockNextDismiss {
            blockNextDismiss = false
            completion?()
            return
        }
        if let activePanel {
            activePanel.dismissPanel()
            armDismissEchoBlock()
            completion?()
            return
        }
        if railVisible {
            hideRail()
            armDismissEchoBlock()
            completion?()
            return
        }
        if timelineVisible {
            hideTimeline()
            armDismissEchoBlock()
            completion?()
            return
        }
        // Leaving: hand the channel to the host's corner player when it keeps
        // one (issue #318), so it goes on playing with its audio.
        if let onMinimize, let session = detachSession() {
            onMinimize(session)
        }
        super.dismiss(animated: flag, completion: completion)
    }

    /// After consuming a Menu press to peel a layer, swallow the parallel
    /// system-gesture echo that would otherwise peel a second. Time-limited
    /// (and cancellable) so a stuck flag can't eat the user's next real press.
    private func armDismissEchoBlock() {
        blockNextDismiss = true
        blockDismissResetWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.blockNextDismiss = false }
        blockDismissResetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    // MARK: - Transport

    /// Directions while the chrome is hidden (the binding only fires then):
    /// Left/Right skip within the rewind window, Up/Down bring the rail up.
    private func handleHiddenChromeDirection(_ direction: DirectionalInputBinding.Direction) {
        switch direction {
        case .left:
            skip(by: -InputConfig.tapSeekSeconds)
        case .right:
            skip(by: InputConfig.tapSeekSeconds)
        case .up, .down:
            showRail()
        }
    }

    private func pausePlayback() {
        guard !isUserPaused else { return }
        isUserPaused = true
        if let lastResortPlayer {
            lastResortPlayer.pause()
        } else {
            aetherPlayer?.pause()
        }
        // The timeline stays up for as long as the stream is paused.
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        flashTimeline()
    }

    private func resumePlayback() {
        guard isUserPaused else { return }
        isUserPaused = false
        if let lastResortPlayer {
            lastResortPlayer.play()
        } else {
            aetherPlayer?.play()
        }
        flashTimeline()
    }

    private func togglePlayPause() {
        isUserPaused ? resumePlayback() : pausePlayback()
    }

    /// Skip within the engine's rewind window, clamped to it; forward stops at
    /// live. Shows where that landed either way, so a skip with nothing to skip
    /// into (a source with no window) still answers the press.
    private func skip(by seconds: TimeInterval) {
        if let aether = aetherPlayer, lastResortPlayer == nil {
            Task { @MainActor [weak self] in
                await aether.seekLive(by: seconds)
                self?.updateRailContent()
            }
        }
        flashTimeline()
    }

    private func goLive() {
        guard let aether = aetherPlayer else { return }
        if isUserPaused { resumePlayback() }
        Task { @MainActor [weak self] in
            await aether.seekToLiveEdge()
            self?.updateRailContent()
        }
    }

    /// Next or previous channel in guide order, wrapping at the ends.
    private func zapChannel(by offset: Int) {
        let channels = LiveTVDataStore.shared.channels
        guard !channels.isEmpty,
              let index = channels.firstIndex(where: { $0.id == channel.id }) else { return }
        let next = channels[(index + offset % channels.count + channels.count) % channels.count]
        switchChannel(to: next)
        flashTimeline()
    }

    // MARK: - Failure ladder

    /// Move to the next recovery stage. Each stage re-resolves the stream URL
    /// so Plex channels get a FRESH tune/session (a dead session keeps
    /// erroring). Non-Plex URLs re-resolve unchanged.
    /// Terminates the in-flight join measurement and clears it, so no later
    /// state change can reopen or double-report the same join. `LiveJoinTelemetry`
    /// is itself idempotent; clearing the reference here is what keeps a
    /// fallback retry's fresh instance from being confused with this one.
    private func finishJoinTelemetry(_ terminate: (LiveJoinTelemetry) -> Void) {
        guard let telemetry = joinTelemetry else { return }
        joinTelemetry = nil
        terminate(telemetry)
    }

    private func advanceFallback() {
        fallbackStage += 1
        guard fallbackStage <= 2 else {
            loadingSpinner.stopAnimating()
            return
        }
        let stage = fallbackStage

        isFallbackInFlight = true
        loadingSpinner.startAnimating()
        streamLoadTask = Task { @MainActor in
            defer { isFallbackInFlight = false }
            guard let freshURL = await LiveTVDataStore.shared.resolveStreamURL(for: channel) else { return }
            if Task.isCancelled { return }
            startLiveSessionKeepAlive(for: freshURL)

            if stage == 1 {
                // Retry through the engine's own demuxer (no native-HLS
                // shortcut). Plex URLs also drop directPlay → 0 here: if the
                // server refused raw passthrough on the first attempt, the
                // fresh session retries as a pure direct-stream remux.
                //
                // Only a raw source can take the demuxer. Forcing it on a
                // playlist hands an m3u8 body to the engine's raw path, which
                // fails closed by design, so the retry would be spent before
                // it ran. A re-resolve that lands on the start.m3u8 consensus
                // leg therefore retries natively: a fresh tune is still a real
                // second chance at a session that died server-side.
                let retryURL = Self.forcingDirectStream(freshURL)
                let isPlaylist = AetherPlayer.liveRoute(for: retryURL,
                                                        forceEngineDemux: false) == .nativeHLS
                do {
                    aetherPlayer?.stop()
                    try await aetherPlayer?.loadLive(url: retryURL,
                                                     headers: LiveTVClientIdentity.streamHeaders(for: channel),
                                                     forceEngineDemux: !isPlaylist)
                    if Task.isCancelled { return }
                    aetherPlayer?.play()
                } catch {
                    if Task.isCancelled { return }
                    advanceFallback()
                }
            } else {
                // Last resort: bare AVPlayer on its own layer (engine is done).
                if Task.isCancelled { return }
                aetherPlayer?.stop()
                aetherPlayer?.unbind(view: engineSurfaceView)
                aetherPlayer = nil

                let avPlayer = AVPlayer(url: freshURL)
                let layer = AVPlayerLayer(player: avPlayer)
                layer.frame = view.bounds
                layer.videoGravity = .resizeAspect
                view.layer.insertSublayer(layer, at: 0)
                lastResortPlayer = avPlayer
                lastResortLayer = layer
                avPlayer.play()
                loadingSpinner.stopAnimating()
            }
        }
    }

    /// Rewrite `directPlay=1` → `0` on Plex universal-transcode URLs so the
    /// retry runs as a direct-stream remux. URLs without that query item
    /// (IPTV, HDHomeRun raw TS) pass through untouched.
    private static func forcingDirectStream(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var items = components.queryItems,
              let index = items.firstIndex(where: { $0.name == "directPlay" }) else {
            return url
        }
        items[index] = URLQueryItem(name: "directPlay", value: "0")
        components.queryItems = items
        // Reassigning queryItems decodes the client profile's %2B clause
        // separators back to raw '+', which PMS reads as spaces. Visible in the
        // wild: a retry URL logged with ')+add-' where the first attempt had
        // ')%2Badd-'. See PlexLiveTVChannel.finalizedLiveURL.
        return PlexLiveTVChannel.finalizedLiveURL(components) ?? url
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        lastResortLayer?.frame = view.bounds
    }

    // MARK: - Live session keepalive (Plex tuner grabs)

    private func startLiveSessionKeepAlive(for url: URL) {
        liveKeepalive.start(url: url)
    }

    private func stopLiveSessionKeepAlive() {
        liveKeepalive.stop()
    }

    // MARK: - Subtitle overlay (same overlay as Aether VOD)

    private func mountSubtitleOverlay() {
        // A plain subview, not a hosting controller. That removes the safe-area
        // problem this used to need a workaround for: a hosting controller
        // applies the tvOS ~60pt title-safe inset to its content, so the overlay
        // measured against the inset box and every bottom margin came out that
        // much too high (the rail gap measured about double its intended 5%).
        let overlay = CaptionOverlayView(
            model: subtitleModel,
            style: captionStyle,
            controlsVisible: railVisible,
            // Broadcast is usually 16:9, but a 4:3 or 2.39:1 channel gets its
            // captions on the picture rather than in the pillar/letterbox.
            videoSize: aetherPlayer?.videoSize ?? .zero,
            // Height is sticky per channel, like the delay stepper.
            heightUnits: subtitleHeightUnits
        )
        // Added here, below the chrome — see the call site in viewDidLoad.
        view.addSubview(overlay)
        overlay.frame = view.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        subtitleOverlay = overlay
    }

    /// Pushes the controller's current caption inputs into the overlay.
    ///
    /// `animated` is the rail-driven lift ONLY: the captions slide out of the
    /// rail's way on the same 0.25s ease-in-out the rail fades on, so the two
    /// travel together. Content-driven updates (a new video size, a
    /// caption-settings change) stay instant — animating a caption's geometry
    /// because the user changed their font size would be noise.
    private func syncSubtitleOverlay(animated: Bool = false) {
        guard let overlay = subtitleOverlay else { return }
        overlay.style = captionStyle
        // Broadcast is usually 16:9, but a 4:3 or 2.39:1 channel gets its
        // captions on the picture rather than in the pillar/letterbox.
        overlay.videoSize = aetherPlayer?.videoSize ?? .zero
        // Height is sticky per channel, like the delay stepper.
        overlay.heightUnits = subtitleHeightUnits
        overlay.setControlsVisible(railVisible || timelineVisible, animated: animated)
    }

    private func bindAetherSubtitles(_ aether: AetherPlayer) {
        aether.$subtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                guard let self else { return }
                // While a native legible (remote WebVTT) selection drives the
                // overlay, an empty engine publish must not wipe its cues: the
                // engine has no cues of its own on the bypass. Keyed off the
                // publish being empty rather than the route, so a #168 reroute
                // onto the loopback (where it really does demux) still lands.
                if self.nativeLegibleActive && cues.isEmpty { return }
                self.subtitleModel.update(cues: cues)
            }
            .store(in: &cancellables)

        // The overlay is a rebuilt-on-demand root view, so a videoSize change
        // has to force a rebuild — nothing observes the player from SwiftUI.
        aether.$videoSize
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncSubtitleOverlay() }
            .store(in: &cancellables)

        aether.$sourceTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in self?.subtitleModel.sourceTime = time }
            .store(in: &cancellables)
    }

    // MARK: - Caption appearance

    private func observeCaptionAppearance() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(captionAppearanceDidChange),
            name: CaptionAppearance.changedNotification,
            object: nil
        )
    }

    @objc private func captionAppearanceDidChange() {
        captionStyle = CaptionAppearance.current()
        syncSubtitleOverlay()
    }
}

// MARK: - Transport input

extension LiveTVAetherPlayerViewController: PlaybackInputTarget {
    /// Live TV never enters a scrub mode: every seek is a discrete skip.
    var isScrubbingForInput: Bool { false }

    func handleInputAction(_ action: PlaybackInputAction, source: PlaybackInputSource) {
        switch action {
        case .play:
            resumePlayback()
        case .pause:
            pausePlayback()
        case .playPause:
            togglePlayPause()
        case .seekRelative(let seconds):
            skip(by: seconds)
        case .stepSeek(let forward), .scrubNudge(let forward):
            skip(by: forward ? InputConfig.tapSeekSeconds : -InputConfig.tapSeekSeconds)
        case .jumpSeek(let forward):
            skip(by: forward ? InputConfig.jumpSeekSeconds : -InputConfig.jumpSeekSeconds)
        case .showInfo:
            showRail()
        default:
            // Absolute positions (Control Center) mean nothing on a live
            // stream's wall-clock bar, and scrub commits never start here.
            break
        }
    }
}
