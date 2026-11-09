// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import AppKit
import AVKit
import Combine
import SwiftUI

/// App-level owner of the active player, Picture in Picture and Now Playing, so PiP outlives the
/// player view. Starting PiP hides the player, PiP's restore button shows it again, and closing
/// PiP ends playback. Mirrors `IOSPlaybackController`.
@MainActor
final class MacPlaybackController: NSObject, ObservableObject {
    @Published private(set) var session: (any MacPlaybackSession)?
    /// False while the picture is in a PiP window.
    @Published private(set) var isPresented = false
    /// True while a play is preparing; a second request in that window is ignored.
    @Published private(set) var isPreparing = false
    @Published private(set) var isPictureInPicturePossible = false
    @Published private(set) var isPictureInPictureActive = false
    /// Shown in an alert by the host when playback fails to start.
    @Published var playbackError: String?

    /// Needed by Plex titles; the host modifier supplies it.
    weak var plex: PlexSession?

    /// The engine surface, kept here so it survives the view while PiP runs.
    private(set) var surface: NSView?
    private var pip: AVPictureInPictureController?
    private var pipPossibleObservation: AnyCancellable?
    private var isRestoring = false
    private let nowPlaying = MacNowPlaying()
    private var cancellables = Set<AnyCancellable>()
    private var displayActivity: NSObjectProtocol?
    private var beginTask: Task<Void, Never>?
    private var lifecycleTokens: [NSObjectProtocol] = []
    /// The window the player covers; closing it ends playback.
    weak var hostWindow: NSWindow? { didSet { observeWindow() } }
    /// The subtitle the C key turns back on.
    private var lastSubtitleID: Int?
    private static let volumeKey = "macPlayerVolume"

    /// The player is up and the Playback menu has something to drive.
    var isActive: Bool { session != nil && isPresented }

    // MARK: - Caller API

    /// The one way to play a title from any server. A show or season plays the episode Play
    /// means; `sourceID` picks a version; a `queue` (a playlist) replaces Up Next. Failure shows
    /// in the host's alert; a second call while one prepares is ignored.
    func play(_ item: MediaItem, fromBeginning: Bool = false, sourceID: String? = nil,
              queue: PlayQueue<PlaylistEntry>? = nil, startOffset: TimeInterval? = nil) {
        guard !isPreparing else { return }
        isPreparing = true
        Task {
            defer { isPreparing = false }
            do {
                let prepared = try await PlaybackStart.prepare(
                    item, fromBeginning: fromBeginning, sourceID: sourceID, queue: queue, plex: plex,
                    startOffset: startOffset)
                let session = MacPlexPlayback(request: prepared.request, plex: prepared.backend, queue: prepared.queue)
                session.onFailure = { [weak self] message in
                    self?.close()
                    self?.playbackError = message
                }
                session.onFinished = { [weak self] in self?.close() }
                start(session)
            } catch is CancellationError {
            } catch {
                playbackError = PlaybackFailure.message(for: error)
            }
        }
    }

    /// The title being played, nil for a channel.
    var plexSession: MacPlexPlayback? { session as? MacPlexPlayback }

    /// Live TV: one click from a channel to full-window playback.
    func playLive(_ channel: UnifiedChannel) {
        start(MacLivePlayback(channel: channel))
    }

    /// Channel Up and Down, along the lineup.
    func stepChannel(_ offset: Int) {
        guard let live = session as? MacLivePlayback, let next = live.neighbour(offset) else { return }
        live.switchChannel(to: next)
    }

    func start(_ newSession: any MacPlaybackSession) {
        end()
        session = newSession
        let player = newSession.player
        let surface = AetherPlayer.makeRenderSurface()
        player.bind(surface: surface)
        self.surface = surface
        player.setVolume((UserDefaults.standard.object(forKey: Self.volumeKey) as? Float) ?? 1)
        newSession.onItemChange = { [weak self] in
            self?.lastSubtitleID = nil
            self?.startNowPlaying()
        }
        observe(newSession)
        startNowPlaying()
        isPresented = true
        beginTask = Task { await newSession.begin() }
    }

    /// Close button: ends playback and leaves the screen.
    func close() {
        end()
        isPresented = false
    }

    /// Esc: leaves full screen first, then closes.
    func escape() {
        if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        } else {
            close()
        }
    }

    func toggleFullScreen() { NSApp.keyWindow?.toggleFullScreen(nil) }

    func startPictureInPicture() { pip?.startPictureInPicture() }

    /// Ends the session: final reports, player stop, PiP and Now Playing torn down.
    func end() {
        guard let session else { return }
        beginTask?.cancel()
        beginTask = nil
        session.end()
        lastSubtitleID = nil
        if let surface { session.player.unbind(surface: surface) }
        session.player.stop()
        surface = nil
        pip?.stopPictureInPicture()
        pip?.delegate = nil
        pip = nil
        pipPossibleObservation = nil
        isPictureInPicturePossible = false
        isPictureInPictureActive = false
        nowPlaying.stop()
        cancellables.removeAll()
        setKeepsDisplayAwake(false)
        self.session = nil
    }

    /// Quitting sends the final report; closing the window stops the player. PiP outlives the window.
    private func observeWindow() {
        lifecycleTokens.forEach(NotificationCenter.default.removeObserver)
        lifecycleTokens = []
        let center = NotificationCenter.default
        lifecycleTokens.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.session != nil else { return }
                self?.end()
                // Lets the stopped report leave before the process does.
                RunLoop.current.run(until: .now + 0.5)
            }
        })
        guard let hostWindow else { return }
        lifecycleTokens.append(center.addObserver(forName: NSWindow.willCloseNotification, object: hostWindow, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isPictureInPictureActive else { return }
                self.close()
            }
        })
    }

    // MARK: - Transport (the Playback menu and the player's keys)

    func togglePlayPause() { session?.player.togglePlayPause() }

    func skip(forward: Bool) {
        let defaults = UserDefaults.standard
        let seconds = forward
            ? Double(defaults.object(forKey: SkipLengthKeys.forward) as? Int ?? 30)
            : Double(defaults.object(forKey: SkipLengthKeys.back) as? Int ?? 10)
        guard let session else { return }
        if let live = session as? MacLivePlayback {
            live.skip(by: forward ? seconds : -seconds)
        } else {
            Task { await session.player.skip(by: forward ? seconds : -seconds) }
        }
    }

    func adjustVolume(by delta: Float) {
        guard let player = session?.player else { return }
        setVolume(player.volume + delta)
    }

    func setVolume(_ volume: Float) {
        guard let player = session?.player else { return }
        player.setVolume(volume)
        UserDefaults.standard.set(player.volume, forKey: Self.volumeKey)
    }

    func toggleMute() {
        guard let player = session?.player else { return }
        player.setMuted(!player.isMuted)
    }

    /// C: subtitles off, or back to the last track (else the first one).
    func toggleSubtitles() {
        guard let session else { return }
        if let current = session.selectedSubtitleID {
            lastSubtitleID = current
            session.selectSubtitle(nil)
        } else {
            let tracks = session.subtitleTracks
            let remembered = tracks.first { $0.id == lastSubtitleID }?.id
            if let id = remembered ?? tracks.first?.id { session.selectSubtitle(id) }
        }
    }

    // MARK: - Observation

    private func observe(_ session: any MacPlaybackSession) {
        let player = session.player
        player.$pictureInPictureSource
            .sink { [weak self] source in self?.updatePictureInPicture(source) }
            .store(in: &cancellables)

        // Now Playing and display sleep follow transport changes, not clock ticks.
        Publishers.Merge4(
            player.$state.map { _ in () },
            player.$rate.map { _ in () },
            player.$pendingSeekTarget.map { _ in () },
            player.$duration.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.transportChanged() }
        .store(in: &cancellables)

        // The Playback menu lists the tracks and marks the speed and mute, so it follows them.
        Publishers.MergeMany([
            player.$audioTracks.map { _ in () }.eraseToAnyPublisher(),
            player.$subtitleTracks.map { _ in () }.eraseToAnyPublisher(),
            player.$currentAudioTrackId.map { _ in () }.eraseToAnyPublisher(),
            player.$currentSubtitleTrackId.map { _ in () }.eraseToAnyPublisher(),
            player.$isMuted.map { _ in () }.eraseToAnyPublisher(),
            player.$fillsScreen.map { _ in () }.eraseToAnyPublisher(),
            player.$rate.map { _ in () }.eraseToAnyPublisher(),
            player.$state.map { _ in () }.eraseToAnyPublisher(),
            session.changes
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.objectWillChange.send() }
        .store(in: &cancellables)
    }

    private func transportChanged() {
        guard let player = session?.player else { return }
        let playing = player.state == .playing
        setKeepsDisplayAwake(playing)
        nowPlaying.update(
            elapsed: player.pendingSeekTarget ?? player.currentTime,
            duration: player.duration,
            rate: playing ? player.rate : 0
        )
        // Sample-buffer PiP re-reads paused state and range only when told.
        if let pip, pip.contentSource?.sampleBufferDisplayLayer != nil { pip.invalidatePlaybackState() }
    }

    private func setKeepsDisplayAwake(_ awake: Bool) {
        if awake, displayActivity == nil {
            displayActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Playing video")
        } else if !awake, let activity = displayActivity {
            ProcessInfo.processInfo.endActivity(activity)
            displayActivity = nil
        }
    }

    private func startNowPlaying() {
        guard let session else { return }
        let player = session.player
        let defaults = UserDefaults.standard
        let back = Double(defaults.object(forKey: SkipLengthKeys.back) as? Int ?? 10)
        let forward = Double(defaults.object(forKey: SkipLengthKeys.forward) as? Int ?? 30)
        let item = session.nowPlayingItem
        nowPlaying.start(
            item,
            commands: MacNowPlaying.Commands(
                play: { [weak player] in player?.play() },
                pause: { [weak player] in player?.pause() },
                skip: { [weak player] seconds in Task { await player?.skip(by: seconds) } },
                seek: item.isLive ? nil : { [weak player] time in Task { await player?.seek(to: time) } }
            ),
            skipBackward: back,
            skipForward: forward
        )
        transportChanged()
    }

    // MARK: - Picture in Picture

    private func updatePictureInPicture(_ source: AVPictureInPictureController.ContentSource?) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        if let pip {
            // Keep a live window through the teardown's transient nil; a new layer replaces a dead one.
            if source != nil || !pip.isPictureInPictureActive { pip.contentSource = source }
            return
        }
        guard let source else { return }
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        pipPossibleObservation = controller.publisher(for: \.isPictureInPicturePossible)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isPictureInPicturePossible = $0 }
        pip = controller
    }
}

extension MacPlaybackController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        isPictureInPictureActive = true
        session?.player.setPictureInPictureActive(true)
        isPresented = false
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        isRestoring = true
        isPresented = true
        // Let the player view mount so the window animates into it.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            completionHandler(true)
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        isPictureInPictureActive = false
        session?.player.setPictureInPictureActive(false)
        // Re-apply anything withheld while the window was up.
        controller.contentSource = session?.player.pictureInPictureSource
        defer { isRestoring = false }
        guard !isRestoring else { return }
        // The window's close button: end playback, or pause if the player is still on screen.
        if !isPresented {
            end()
        } else {
            session?.player.pause()
        }
    }
}

extension View {
    /// Covers the window with the player while a session is presented.
    func macPlaybackHost(_ controller: MacPlaybackController) -> some View {
        modifier(MacPlaybackHost(controller: controller))
    }
}

private struct MacPlaybackHost: ViewModifier {
    @ObservedObject var controller: MacPlaybackController
    @EnvironmentObject private var plex: PlexSession

    func body(content: Content) -> some View {
        content
            .onAppear { controller.plex = plex }
            .background(MacHostWindowReader { controller.hostWindow = $0 })
            // The page under the player stays alive; its keys and buttons must not act on it.
            .disabled(controller.isPresented && controller.session != nil)
            .overlay {
                if controller.isPresented, let session = controller.session {
                    Group {
                        if let plex = session as? MacPlexPlayback {
                            MacPlayerView(session: plex, player: plex.player, controller: controller)
                        } else if let live = session as? MacLivePlayback {
                            MacLivePlayerView(session: live, player: live.player, controller: controller)
                        }
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
                }
            }
            .toolbarVisibility(controller.isPresented && controller.session != nil ? .hidden : .automatic, for: .windowToolbar)
            .animation(.easeInOut(duration: 0.2), value: controller.isPresented)
            .alert(
                "Couldn't Play",
                isPresented: Binding(get: { controller.playbackError != nil },
                                     set: { if !$0 { controller.playbackError = nil } }),
                actions: { Button("OK") {} },
                message: { Text(controller.playbackError ?? "") }
            )
    }
}

/// Hands the hosting window to the controller.
private struct MacHostWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {}
}
