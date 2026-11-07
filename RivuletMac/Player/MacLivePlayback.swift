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
    var onItemChange: (() -> Void)?

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
            seek: { [weak player] in await player?.seekLive(to: $0) },
            seekToLiveEdge: { [weak player] in await player?.seekToLiveEdge() },
            play: { [weak player] in player?.play() },
            isUserPaused: { [weak player] in player?.state == .paused }
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
        if player.liveWindow.seekableRange != nil {
            windowSeeker.step(by: seconds)
        } else {
            Task { await player.skip(by: seconds) }
        }
    }

    func goLive() {
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
        windowSeeker.cancelPending()
        let channel = channel
        guard let stream = await tuner.tune(channel) else {
            if !Task.isCancelled { notice = tuner.notice }
            return
        }
        do {
            try await player.loadLive(url: stream.url, headers: stream.headers, forceEngineDemux: stream.forceEngineDemux)
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
