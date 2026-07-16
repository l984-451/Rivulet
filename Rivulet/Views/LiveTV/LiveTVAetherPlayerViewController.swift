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
//  Subtitles (including DVB/teletext decoded engine-side) render through
//  AetherSubtitleOverlayView, the same overlay Aether VOD uses.
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
import SwiftUI
import UIKit

final class LiveTVAetherPlayerViewController: UIViewController {

    private let channel: UnifiedChannel

    private var aetherPlayer: AetherPlayer?

    /// Engine render surface — the only correct way to display Aether video.
    private let engineSurfaceView = AetherPlayerView()

    /// Shown until the first frame plays; the engine spins up demux + decode
    /// before any picture, so give the user something in the meantime.
    private let loadingSpinner = UIActivityIndicatorView(style: .large)

    private let subtitleModel = SubtitleModel()
    private var subtitleHostingController: UIHostingController<AetherSubtitleOverlayView>?
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
    /// a timeline periodically. Pings every 60s while playing; a final
    /// "stopped" ping on teardown releases the tuner promptly.
    private var keepAliveTask: Task<Void, Never>?
    private var stopPingURL: URL?

    /// tvOS delivers Menu both through the responder chain AND a parallel
    /// system gesture that calls `dismiss(animated:)` on the presented VC.
    /// After we consume a Menu press (hide rail / close panel), this swallows
    /// the system echo so it can't peel the whole player. Cleared on use and
    /// by a short timer so the next genuine press works.
    private var blockNextDismiss = false

    // MARK: Native HLS legible subtitles (remote WebVTT renditions)
    //
    // On the nativeRemoteHLS path the engine never demuxes, so its subtitle
    // track list is empty — the stream's WebVTT renditions live in AVPlayer's
    // legible media selection group. Selection alone isn't enough either: a
    // bare AVPlayerLayer doesn't paint legible content (only AVKit does), so
    // cues are pulled through an AVPlayerItemLegibleOutput and drawn by the
    // same overlay the engine paths use.
    private var nativeLegibleGroup: AVMediaSelectionGroup?
    private var nativeLegibleOutput: AVPlayerItemLegibleOutput?
    private var nativeLegibleBridge: LegibleOutputBridge?
    private var nativeLegibleActive = false

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

    // MARK: Chrome state

    /// Same glass rail as Aether VOD; Up Next and Insights are hidden (they
    /// have no meaning for a live broadcast).
    private let railView = PlayerRailView()
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

    /// Called once when the player is dismissed, so the guide can restore state.
    var onDismiss: (() -> Void)?

    init(channel: UnifiedChannel) {
        self.channel = channel
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

        mountSubtitleOverlay()
        observeCaptionAppearance()
        setupChrome()

        let aether = AetherPlayer()
        aetherPlayer = aether
        aether.bind(view: engineSurfaceView)
        bindAetherSubtitles(aether)
        startAudioDropoutDiagnostics()

        aether.playbackStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                print("🔊 [LiveAudioDiag] playbackState → \(state) t=\(Date().timeIntervalSince1970)")
                switch state {
                case .playing:
                    self.loadingSpinner.stopAnimating()
                case .failed:
                    guard !self.isFallbackInFlight else { return }
                    self.advanceFallback()
                default:
                    break
                }
            }
            .store(in: &cancellables)

        // Keep the rail's audio meta line current as the engine reports tracks.
        aether.$audioTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateRailContent() }
            .store(in: &cancellables)

        Task { @MainActor in
            // Resolve performs the Plex tune step for cloud-EPG/DVB channels;
            // other sources pass straight through.
            guard let url = await LiveTVDataStore.shared.resolveStreamURL(for: channel) else {
                onDismiss?()
                dismiss(animated: true)
                return
            }
            startLiveSessionKeepAlive(for: url)
            do {
                try await aether.loadLive(url: url, headers: nil)
                aether.play()
            } catch {
                self.advanceFallback()
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || isMovingFromParent else { return }
        stopLiveSessionKeepAlive()
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        programInfoTimer?.invalidate()
        programInfoTimer = nil
        activePanel?.dismissPanel()
        activePanel = nil
        if let hosting = subtitleHostingController {
            hosting.willMove(toParent: nil)
            hosting.view.removeFromSuperview()
            hosting.removeFromParent()
            subtitleHostingController = nil
        }
        NotificationCenter.default.removeObserver(
            self,
            name: CaptionAppearance.changedNotification,
            object: nil
        )
        lastResortPlayer?.pause()
        lastResortPlayer = nil
        lastResortLayer?.removeFromSuperlayer()
        lastResortLayer = nil
        nativeLegibleActive = false
        nativeLegibleOutput = nil
        nativeLegibleBridge = nil
        nativeLegibleGroup = nil
        aetherPlayer?.stop()
        aetherPlayer?.unbind(view: engineSurfaceView)
        aetherPlayer = nil
        cancellables.removeAll()
        onDismiss?()
    }

    // MARK: - Chrome (glass rail + panels)

    private func setupChrome() {
        // Focus catcher: 1pt, transparent, always present.
        focusCatcher.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        focusCatcher.backgroundColor = .clear
        view.addSubview(focusCatcher)

        railView.setUpNextAvailable(false)
        railView.setInsightsAvailable(false)
        railView.setLoading(false)
        railView.alpha = 0
        railView.transform = CGAffineTransform(translationX: 0, y: 24)
        view.addSubview(railView)
        railView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            railView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 90),
            railView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -90),
            railView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -84),
            railView.heightAnchor.constraint(equalToConstant: PlayerRailView.railHeight),
        ])

        railView.onSubtitles = { [weak self] in self?.presentSubtitlePanel() }
        railView.onAudio = { [weak self] in self?.presentAudioPanel() }
        railView.onInfo = { [weak self] in self?.presentInfoPanel() }

        updateRailContent()

        // The guide's "current programme" rolls over on its own clock.
        programInfoTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateRailContent() }
        }
    }

    /// Rail metadata from GUIDE data: programme title, channel line, air
    /// window, and the engine's current audio track.
    private func updateRailContent() {
        let current = LiveTVDataStore.shared.getCurrentProgram(for: channel)

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

        var audioDescription: String?
        if let aether = aetherPlayer,
           let activeId = aether.currentAudioTrackId,
           let track = aether.audioTracks.first(where: { $0.id == activeId }) {
            audioDescription = [track.language, track.codec?.uppercased()]
                .compactMap { $0 }
                .joined(separator: " ")
        }

        railView.setMeta(rating: "LIVE", runtime: runtime, audio: audioDescription)
    }

    private func showRail() {
        guard !railVisible else { return }
        railVisible = true
        updateRailContent()
        UIView.animate(withDuration: 0.25) {
            self.railView.alpha = 1
            self.railView.transform = .identity
        }
        rebuildSubtitleOverlay()
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
        rebuildSubtitleOverlay()
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
            aboveRail: railView,
            towards: railView
        )
        panel.onDismiss = { [weak self] in
            guard let self else { return }
            self.activePanel = nil
            self.setNeedsFocusUpdate()
            self.updateFocusIfNeeded()
            self.restartAutoHide()
        }
        // The panel consumes Menu itself while focus is inside it; arm the
        // echo block so the parallel system gesture's dismiss() can't peel
        // the rail (or the player) on the same physical press.
        panel.onMenuHandled = { [weak self] in
            self?.armDismissEchoBlock()
        }
        activePanel = panel
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func presentSubtitlePanel() {
        guard let aether = aetherPlayer else { return }

        // Engine demux path: tracks come from the engine.
        if !aether.subtitleTracks.isEmpty {
            let list = CardTrackListView(
                header: "Subtitles",
                tracks: aether.subtitleTracks,
                selectedTrackId: aether.currentSubtitleTrackId,
                showsOffRow: true
            ) { [weak self] trackId in
                self?.aetherPlayer?.selectSubtitleTrack(id: trackId)
                self?.activePanel?.dismissPanel()
            }
            presentPanel(content: list, width: 520)
            return
        }

        // nativeRemoteHLS path: the engine never demuxes, so list the REMOTE
        // playlist's WebVTT renditions from AVPlayer's legible group.
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
                showsOffRow: true
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
            }
            self.presentPanel(content: list, width: 520)
        }
    }

    /// Select (or clear, with nil) a remote WebVTT rendition, and attach the
    /// legible output that feeds its cues to our overlay — AVPlayerLayer does
    /// not paint legible content on its own.
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
            subtitleModel.update(cues: [])
        }
    }

    private func ensureNativeLegibleOutput(on item: AVPlayerItem) {
        guard nativeLegibleOutput == nil else { return }
        let bridge = LegibleOutputBridge { [weak self] strings, itemTime in
            self?.handleNativeLegible(strings: strings, at: itemTime)
        }
        let output = AVPlayerItemLegibleOutput()
        output.setDelegate(bridge, queue: .main)
        item.add(output)
        nativeLegibleBridge = bridge
        nativeLegibleOutput = output
    }

    /// Each legible-output event replaces the on-screen text wholesale (open
    /// ended: valid until the next event, which mirrors how the engine's
    /// teletext cues behave). Empty events clear the overlay.
    private func handleNativeLegible(strings: [NSAttributedString], at itemTime: CMTime) {
        let time = max(0, CMTimeGetSeconds(itemTime))
        let texts = strings.map(\.string).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !texts.isEmpty else {
            subtitleModel.update(cues: [])
            return
        }
        let cues = texts.enumerated().map { index, text in
            AetherSubtitleCue(id: index, startTime: time, endTime: time + 3600, body: .text(text))
        }
        subtitleModel.update(cues: cues)
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

    // MARK: - Audio dropout diagnostics (temporary)

    /// Logs the three things that can silence audio while video keeps playing,
    /// timestamped so dropout moments can be matched against them:
    ///  - AVAudioSession INTERRUPTIONS (system took the session)
    ///  - AVAudioSession ROUTE CHANGES (HDMI renegotiation / someone calling
    ///    setCategory-setActive mid-stream)
    ///  - media services resets
    /// If a dropout shows NONE of these, the starvation is inside the engine's
    /// renderer feed (upstream issue); if it shows route changes with reason
    /// .categoryChange, something app-side is touching the shared session.
    private func startAudioDropoutDiagnostics() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        center.addObserver(forName: AVAudioSession.interruptionNotification,
                           object: session, queue: .main) { note in
            let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 99
            let type = AVAudioSession.InterruptionType(rawValue: raw)
            print("🔊 [LiveAudioDiag] INTERRUPTION type=\(String(describing: type)) t=\(Date().timeIntervalSince1970)")
        }

        center.addObserver(forName: AVAudioSession.routeChangeNotification,
                           object: session, queue: .main) { note in
            let raw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 99
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
            let out = session.currentRoute.outputs.map { "\($0.portType.rawValue)(ch=\($0.channels?.count ?? 0))" }.joined(separator: ",")
            print("🔊 [LiveAudioDiag] ROUTE CHANGE reason=\(String(describing: reason)) route=[\(out)] sr=\(session.sampleRate) t=\(Date().timeIntervalSince1970)")
        }

        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                           object: session, queue: .main) { _ in
            print("🔊 [LiveAudioDiag] MEDIA SERVICES RESET t=\(Date().timeIntervalSince1970)")
        }
    }

    // MARK: - Remote handling

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.type {
            case .menu:
                // Route through dismiss(animated:): its override converts
                // "close" into panel-close / rail-hide before ever exiting the
                // player, and the same funnel catches the system Menu gesture.
                dismiss(animated: true)
                return
            case .select:
                if !railVisible {
                    showRail()
                    return
                }
            case .playPause:
                togglePlayPause()
                return
            default:
                break
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Menu is fully consumed at began; an unswallowed ended phase bubbles
        // to the system and peels an extra layer.
        for press in presses where press.type == .menu { return }
        super.pressesEnded(presses, with: event)
    }

    /// Menu must peel ONE layer at a time: panel → rail → player. tvOS's
    /// system Menu gesture calls this directly (racing pressesBegan), so the
    /// layering decision lives HERE — both delivery routes converge on it.
    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
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
        super.dismiss(animated: flag, completion: completion)
    }

    /// The press handler and the system gesture can BOTH reach dismiss() for
    /// one physical Menu press; after consuming the first, swallow the echo.
    /// Time-limited so a stuck flag can't eat the user's next real press.
    private func armDismissEchoBlock() {
        blockNextDismiss = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.blockNextDismiss = false
        }
    }

    private func togglePlayPause() {
        if let lastResortPlayer {
            lastResortPlayer.rate == 0 ? lastResortPlayer.play() : lastResortPlayer.pause()
        } else if let aetherPlayer {
            aetherPlayer.isPlaying ? aetherPlayer.pause() : aetherPlayer.play()
        }
    }

    // MARK: - Failure ladder

    /// Move to the next recovery stage. Each stage re-resolves the stream URL
    /// so Plex channels get a FRESH tune/session (a dead session keeps
    /// erroring). Non-Plex URLs re-resolve unchanged.
    private func advanceFallback() {
        fallbackStage += 1
        guard fallbackStage <= 2 else {
            loadingSpinner.stopAnimating()
            return
        }
        let stage = fallbackStage

        isFallbackInFlight = true
        loadingSpinner.startAnimating()
        Task { @MainActor in
            defer { isFallbackInFlight = false }
            guard let freshURL = await LiveTVDataStore.shared.resolveStreamURL(for: channel) else { return }
            startLiveSessionKeepAlive(for: freshURL)

            if stage == 1 {
                // Retry through the engine's own demuxer (no native-HLS
                // shortcut). Plex URLs also drop directPlay → 0 here: if the
                // server refused raw passthrough on the first attempt, the
                // fresh session retries as a pure direct-stream remux.
                let retryURL = Self.forcingDirectStream(freshURL)
                do {
                    aetherPlayer?.stop()
                    try await aetherPlayer?.loadLive(url: retryURL, headers: nil, forceEngineDemux: true)
                    aetherPlayer?.play()
                } catch {
                    advanceFallback()
                }
            } else {
                // Last resort: bare AVPlayer on its own layer (engine is done).
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
        return components.url ?? url
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        lastResortLayer?.frame = view.bounds
    }

    // MARK: - Live session keepalive (Plex tuner grabs)

    /// If the stream URL carries a tuned Plex live session, report a timeline
    /// every 60s so the server keeps the tuner grab alive, and remember a
    /// "stopped" ping to release it on dismiss. No-op for non-Plex streams.
    private func startLiveSessionKeepAlive(for url: URL) {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        stopPingURL = nil

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = components.queryItems?.first(where: { $0.name == "X-Plex-Token" })?.value,
              let scheme = components.scheme,
              let host = components.host else { return }

        // Session path comes from either form of tuned URL:
        //  - direct part:          /livetv/sessions/<uuid>/<tuner>/index.m3u8
        //  - universal transcode:  …start.ts?path=/livetv/sessions/<uuid>
        let sessionPath: String
        if url.path.hasPrefix("/livetv/sessions/") {
            let parts = url.path.split(separator: "/")  // [livetv, sessions, uuid, …]
            guard parts.count >= 3 else { return }
            sessionPath = "/livetv/sessions/\(parts[2])"
        } else if let queryPath = components.queryItems?.first(where: { $0.name == "path" })?.value,
                  queryPath.hasPrefix("/livetv/sessions/") {
            sessionPath = queryPath
        } else {
            return  // Not a tuned Plex session — no keepalive needed.
        }

        let port = components.port.map { ":\($0)" } ?? ""

        func timelineURL(state: String) -> URL? {
            var ping = URLComponents(string: "\(scheme)://\(host)\(port)/:/timeline")
            ping?.queryItems = [
                URLQueryItem(name: "key", value: sessionPath),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "time", value: "0"),
                URLQueryItem(name: "X-Plex-Client-Identifier", value: PlexAPI.clientIdentifier),
                URLQueryItem(name: "X-Plex-Token", value: token)
            ]
            return ping?.url
        }

        stopPingURL = timelineURL(state: "stopped")
        guard let playingURL = timelineURL(state: "playing") else { return }

        keepAliveTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                _ = try? await URLSession.shared.data(from: playingURL)
            }
        }
    }

    private func stopLiveSessionKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        if let stopURL = stopPingURL {
            stopPingURL = nil
            Task.detached(priority: .utility) {
                _ = try? await URLSession.shared.data(from: stopURL)
            }
        }
    }

    // MARK: - Subtitle overlay (same overlay as Aether VOD)

    private func mountSubtitleOverlay() {
        let hosting = UIHostingController(rootView: makeOverlayRootView())
        hosting.view.backgroundColor = .clear
        hosting.view.isUserInteractionEnabled = false

        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hosting.didMove(toParent: self)

        subtitleHostingController = hosting
    }

    private func makeOverlayRootView() -> AetherSubtitleOverlayView {
        AetherSubtitleOverlayView(
            model: subtitleModel,
            style: captionStyle,
            controlsVisible: railVisible  // lift captions above the glass rail
        )
    }

    private func rebuildSubtitleOverlay() {
        subtitleHostingController?.rootView = makeOverlayRootView()
    }

    private func bindAetherSubtitles(_ aether: AetherPlayer) {
        aether.$subtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                guard let self else { return }
                // While a native legible (remote WebVTT) selection drives the
                // overlay, an empty engine publish must not wipe its cues —
                // the engine list is always empty on the nativeRemoteHLS path.
                if self.nativeLegibleActive && cues.isEmpty { return }
                self.subtitleModel.update(cues: cues)
            }
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
        rebuildSubtitleOverlay()
    }
}
