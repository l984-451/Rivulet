// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Combine
import Foundation

/// A Live TV channel on the Mac player; switches channel in place. Tuning, the Plex keepalive
/// and the refusal messages are `MacLiveTuner`. Mirrors `IOSLivePlayback`.
@MainActor
final class MacLivePlayback: ObservableObject, MacPlaybackSession {
    let player = AetherPlayer()
    @Published private(set) var channel: UnifiedChannel
    /// Shown instead of the engine's failure: a refused tune or a busy tuner.
    @Published private(set) var notice: String?
    /// Start from Beginning or Watch Live, for a recording in progress (#444).
    @Published private(set) var startQuestion: LiveStartQuestion?
    /// How far the session's edge trails live: nonzero only after a join at a
    /// recording's start, which then plays at 1x.
    @Published private(set) var liveLag: TimeInterval = 0
    var onItemChange: (() -> Void)?
    /// The next join is Go Live from such a session: no question, the edge.
    private var joinsLiveWithoutAsking = false
    /// The recording this session plays from (Start from Beginning), and where it was loaded.
    private var recordingStart: LiveRecordingStart?

    private let store = LiveTVDataStore.shared
    private let tuner = MacLiveTuner()
    private var loadTask: Task<Void, Never>?
    private var rolloverTask: Task<Void, Never>?
    private var shownProgramId: String?
    /// Stacked skips land as one seek once they settle; a seek per tap takes a live item down.
    private let windowSeeker = LiveWindowSeekController()

    init(channel: UnifiedChannel) {
        self.channel = channel
        let player = player
        windowSeeker.attach(LiveWindowSeekController.Player(
            window: { [weak player] in
                guard let window = player?.liveWindow, let range = window.seekableRange else { return nil }
                return LiveSeekableWindow(lowerBound: range.lowerBound, upperBound: window.edgeTime)
            },
            position: { [weak player] in player?.liveWindow.playhead ?? 0 },
            seek: { [weak self] in await self?.seekWithinRecording(to: $0) },
            seekToLiveEdge: { [weak self] in await self?.seekToLiveEdge() },
            play: { [weak player] in player?.play() },
            isUserPaused: { [weak player] in player?.state == .paused },
            reach: { [weak self] in
                guard let self, let start = self.recordingStart else { return (0, 0) }
                return start.reach(lag: self.liveLag)
            }
        ))
        windowSeeker.onChange = { [weak self] in self?.objectWillChange.send() }
    }

    var changes: AnyPublisher<Void, Never> { objectWillChange.map { _ in () }.eraseToAnyPublisher() }

    var programme: UnifiedProgram? { store.getCurrentProgram(for: channel) }

    var nowPlayingItem: MacNowPlaying.Item {
        let programme = programme
        return MacNowPlaying.Item(
            title: programme?.displayTitle ?? channel.name,
            subtitle: programme == nil ? nil : channel.name,
            artworkURL: channel.logoURL,
            isLive: true
        )
    }

    // MARK: - Transport

    /// Where stacked skips will land while they settle, on the session axis.
    var stagedSkipTarget: Double? {
        if case .position(let target) = windowSeeker.pendingRequest { return target }
        return nil
    }

    func skip(by seconds: Double) {
        if player.liveWindow.seekableRange != nil || windowSeeker.isLanding {
            windowSeeker.step(by: seconds)
        } else {
            Task { await player.skip(by: seconds) }
        }
    }

    /// A seek on the session axis. The engine fetches a recording's backlog at 1x, so a target
    /// past what it holds (or before where this join began) reloads the recording there.
    private func seekWithinRecording(to target: Double) async {
        let window = player.liveWindow
        if let start = recordingStart, liveLag > 0, let range = window.seekableRange,
           let offset = start.rejoinOffset(
               forSessionPosition: target,
               in: LiveSeekableWindow(lowerBound: range.lowerBound, upperBound: window.edgeTime),
               edgeWall: Date().addingTimeInterval(-liveLag)) {
            await reloadRecording(start.joining(atOffset: offset))
            return
        }
        await player.seekLive(to: target)
    }

    /// Loads the same recorder session from a later (or earlier) offset. The tune and its
    /// keepalive stay, so a skip costs one playlist fetch, not a re-tune.
    private func reloadRecording(_ start: LiveRecordingStart) async {
        recordingStart = start
        liveLag = start.lag(at: Date())
        await reloadEngine(start.url, joinsAtRecordingStart: true)
    }

    /// The same recorder session joined at its head, which is live: no re-tune.
    private func reloadAtLive(_ start: LiveRecordingStart) async {
        let head = start.joining(atOffset: Date().timeIntervalSince(start.firstSegmentAired) - LiveRecordingStart.headMargin)
        recordingStart = nil
        liveLag = 0
        await reloadEngine(head.url, joinsAtRecordingStart: false)
    }

    /// Reloads the engine on the session already tuned. Awaited, so the skip control holds
    /// presses until the new window exists.
    private func reloadEngine(_ url: URL, joinsAtRecordingStart: Bool) async {
        let headers = LiveTVClientIdentity.streamHeaders(for: channel)
        loadTask?.cancel()
        let task = Task {
            do {
                try await player.loadLive(url: url, headers: headers,
                                          forceEngineDemux: true, joinsAtRecordingStart: joinsAtRecordingStart)
            } catch {
                guard !Task.isCancelled, !isCancellationError(error) else { return }
                // The session is gone: join live again rather than ask a second time.
                joinsLiveWithoutAsking = true
                retry()
            }
        }
        loadTask = task
        await task.value
    }

    /// The controller's far end. Behind a recording's head, live is the recording's head.
    private func seekToLiveEdge() async {
        if liveLag > 0, let start = recordingStart {
            await reloadAtLive(start)
        } else {
            await player.seekToLiveEdge()
        }
    }

    func goLive() {
        if liveLag > 0, let start = recordingStart {
            windowSeeker.cancelPending()
            Task { await reloadAtLive(start) }
            return
        }
        if liveLag > 0 {
            // Joined at a recording's start, the session only reaches its own edge; live is a new join.
            joinsLiveWithoutAsking = true
            retry()
            return
        }
        windowSeeker.cancelPending()
        Task { await player.seekToLiveEdge() }
    }

    func seek(to sessionSeconds: Double) {
        windowSeeker.cancelPending()
        Task { await player.seekLive(to: sessionSeconds) }
    }

    // MARK: - Tracks

    var audioTracks: [AetherPlayer.Track] { player.audioTracks }
    var subtitleTracks: [AetherPlayer.Track] { player.subtitleTracks }
    var selectedAudioID: Int? { player.currentAudioTrackId }
    var selectedSubtitleID: Int? { player.currentSubtitleTrackId }
    func selectAudio(_ id: Int) { player.selectAudioTrack(id: id) }
    func selectSubtitle(_ id: Int?) { player.selectSubtitleTrack(id: id) }

    // MARK: - Channels

    /// The channel `offset` places along the lineup, wrapping. Nil when the lineup has no other.
    func neighbour(_ offset: Int) -> UnifiedChannel? {
        let channels = store.channels
        guard channels.count > 1, let index = channels.firstIndex(where: { $0.id == channel.id }) else { return nil }
        return channels[(index + offset + channels.count) % channels.count]
    }

    func switchChannel(to newChannel: UnifiedChannel) {
        guard newChannel.id != channel.id else { return }
        channel = newChannel
        shownProgramId = programme?.id
        onItemChange?()
        retry()
    }

    // MARK: - Lifecycle

    func begin() async {
        startRollover()
        retry()
        await loadTask?.value
    }

    func end() {
        windowSeeker.reset()
        loadTask?.cancel()
        rolloverTask?.cancel()
        tuner.stop()
    }

    func retry() {
        loadTask?.cancel()
        loadTask = Task { await load() }
    }

    private func load() async {
        notice = nil
        liveLag = 0
        recordingStart = nil
        windowSeeker.cancelPending()
        let channel = channel
        guard let stream = await tuner.tune(channel) else {
            if !Task.isCancelled { notice = tuner.notice }
            return
        }
        let asksForStart = !joinsLiveWithoutAsking
        joinsLiveWithoutAsking = false
        var fromStart: LiveRecordingStart?
        if asksForStart, let recordingStart = stream.recordingStart {
            let question = LiveStartQuestion(recording: recordingStart.recording)
            if await question.ask(present: { startQuestion = question }) { fromStart = recordingStart }
            if startQuestion === question { startQuestion = nil }
            guard !Task.isCancelled else { return }
        }
        recordingStart = fromStart
        liveLag = fromStart?.lag(at: Date()) ?? 0
        do {
            try await player.loadLive(url: fromStart?.url ?? stream.url, headers: stream.headers,
                                      forceEngineDemux: stream.forceEngineDemux,
                                      joinsAtRecordingStart: fromStart != nil)
        } catch {
            guard !Task.isCancelled, !isCancellationError(error) else { return }
            await tuner.loadFailed(stream, channel: channel)
            if !Task.isCancelled { notice = tuner.notice }
        }
    }

    /// Now Playing follows the programme across its boundaries.
    private func startRollover() {
        shownProgramId = programme?.id
        rolloverTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self else { return }
                let id = self.programme?.id
                if id != self.shownProgramId {
                    self.shownProgramId = id
                    self.onItemChange?()
                }
            }
        }
    }
}
