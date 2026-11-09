// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicQueue.swift
//  Rivulet
//
//  Global music queue and state manager. Persists playback while browsing.
//

import Foundation
import Combine

/// Repeat mode for music playback
enum MusicRepeatMode: String, CaseIterable {
    case off
    case all
    case one
}

/// Playback state for the music player
enum MusicPlaybackState: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
}

/// The album or artist page a Music menu asks `MusicPresenter` to open.
enum MusicNavigationRequest: Equatable, Sendable {
    case album(MediaItemRef)
    case artist(MediaItemRef)
}

/// Global music queue manager — singleton that persists across navigation.
/// Music plays in the background while the user browses other content.
@MainActor
final class MusicQueue: ObservableObject {

    // MARK: - Singleton

    static let shared = MusicQueue()

    // MARK: - Published State

    @Published var currentTrack: MusicTrack? {
        didSet { if currentTrack?.ref != oldValue?.ref { loadLyrics() } }
    }
    @Published var queue: [MusicTrack] = []
    @Published var history: [MusicTrack] = []
    @Published var playbackState: MusicPlaybackState = .idle
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var repeatMode: MusicRepeatMode = .off
    @Published var isShuffled: Bool = false
    @Published var showNowPlaying: Bool = false
    /// A fast forward or rewind in progress: a `ShuttleGrammar` level, 0 when there is none.
    /// While it runs `currentTime` is the position the scan has reached.
    @Published private(set) var scanLevel = 0

    /// Time-synced lyrics of `currentTrack`, fetched after each track change.
    /// Nil while loading and when the track has none, so `!= nil` is "has lyrics".
    @Published private(set) var currentLyrics: [MusicLyricLine]?

    /// Favorites toggled this session, by track. Tracks are immutable values,
    /// so read a star through `isFavorite(_:)`, never `userState` directly.
    // ponytail: entries live until the account changes; drop one when a refetch
    // disagrees if edits from another client ever need to show.
    @Published private(set) var favoriteOverrides: [MediaItemRef: Bool] = [:]
    /// The registry generation the overrides were made under: ratings are per user.
    private var favoritesGeneration = 0
    /// One writer per track with a write in flight.
    private var favoriteWriters: [MediaItemRef: Task<Void, Never>] = [:]

    /// Whether a track is loaded, playing or paused. An empty queue has nothing to add to.
    var isActive: Bool { currentTrack != nil }

    /// True while a video player is up. The system has ONE Now Playing entry
    /// and one remote-command center, and both players register handlers on
    /// it: a Control Center, iPhone Remote or HDMI-CEC play/pause during a film
    /// also toggled the paused song underneath it, and this queue's progress
    /// timer kept writing the song's position and a zero rate into the film's
    /// entry, so the system scrubber showed the wrong time.
    var videoOwnsNowPlaying: Bool { filmOwnsNowPlaying || !liveTVSessions.isEmpty }
    private var filmOwnsNowPlaying = false
    /// Live TV screens up (full-screen player, multiview); the two overlap during a hand-off.
    private var liveTVSessions: Set<ObjectIdentifier> = []

    func liveTVSessionBegan(_ owner: ObjectIdentifier) {
        liveTVSessions.insert(owner)
        if playbackState == .playing { pause() }  // A channel does not play over a song.
    }

    func liveTVSessionEnded(_ owner: ObjectIdentifier) { liveTVSessions.remove(owner) }

    // MARK: - Private State

    private let player = MusicPlayer()
    private let nowPlayingBridge = MusicNowPlayingBridge()
    private var cancellables = Set<AnyCancellable>()
    private var originalQueue: [MusicTrack] = []
    private var progressTimer: Timer?
    private var scanTimer: Timer?
    private var scanStart: TimeInterval = 0
    private var scanTicks = 0
    private var musicRegistry: MusicProviderRegistry?
    /// The playing track's own play reports (Jellyfin). Nil sends Plex timeline reports.
    private var reporter: (any ProgressReporter)?

    // MARK: - Initialization

    private init() {
        bindPlayerState()
        observeVideoPlayback()
    }

    /// See `videoOwnsNowPlaying`.
    private func observeVideoPlayback() {
        NotificationCenter.default.addObserver(
            forName: .plexPlaybackStarted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.filmOwnsNowPlaying = true
                // A film does not play over a song.
                if self?.playbackState == .playing { self?.pause() }
            }
        }

        NotificationCenter.default.addObserver(
            forName: .plexPlaybackStopped,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.filmOwnsNowPlaying = false
            }
        }
    }

    // MARK: - Configuration

    /// Called once at app launch after MusicProviderRegistry is populated.
    func configure(registry: MusicProviderRegistry) {
        self.musicRegistry = registry
    }

    // MARK: - Queue Operations

    /// Reset queue state and modes without stopping playback (a profile switch
    /// or sign-out calls `stop()` first).
    func clear() {
        currentTrack = nil
        queue = []
        history = []
        originalQueue = []
        isShuffled = false
        repeatMode = .off
        showNowPlaying = false
        resetScan()
        currentLyrics = nil
        favoriteOverrides = [:]
        favoriteWriters = [:]
    }

    /// Play a single track immediately, clearing the queue
    func playNow(track: MusicTrack) {
        begin(current: track, history: [], queue: [], original: [track], shuffled: false)
    }

    /// Play a tracklist in order from `index`. Turns shuffle off.
    func playAlbum(tracks: [MusicTrack], startingAt index: Int = 0) {
        guard !tracks.isEmpty else { return }
        let clampedIndex = min(index, tracks.count - 1)
        begin(
            current: tracks[clampedIndex],
            history: Array(tracks.prefix(clampedIndex)),
            queue: Array(tracks.suffix(from: clampedIndex + 1)),
            original: tracks,
            shuffled: false
        )
    }

    /// Play a tracklist shuffled, from a random track. Shuffle shows on, and
    /// turning it off continues in the order of `tracks`.
    func playShuffled(tracks: [MusicTrack]) {
        var order = tracks.shuffled()
        guard !order.isEmpty else { return }
        let first = order.removeFirst()
        begin(current: first, history: [], queue: order, original: tracks, shuffled: true)
    }

    private func begin(
        current: MusicTrack,
        history: [MusicTrack],
        queue: [MusicTrack],
        original: [MusicTrack],
        shuffled: Bool
    ) {
        // A film started while the tracks were loading: Now Playing must not open over it.
        guard !videoOwnsNowPlaying else { return }
        self.history = history
        self.queue = queue
        originalQueue = original
        isShuffled = shuffled
        currentTrack = current
        startPlayback(track: current)
        showNowPlaying = true
    }

    /// Add tracks to play next, in their order (front of queue). One publish for the lot.
    func addNext(tracks: [MusicTrack]) {
        queue.insert(contentsOf: tracks, at: 0)
        // Kept in the unshuffled order too, or turning shuffle off drops them.
        let currentIndex = originalQueue.firstIndex { $0.ref == currentTrack?.ref }
        originalQueue.insert(contentsOf: tracks, at: currentIndex.map { $0 + 1 } ?? 0)
    }

    /// Add a track to the end of the queue
    func addToEnd(track: MusicTrack) {
        addToEnd(tracks: [track])
    }

    /// Add multiple tracks to the end of the queue
    func addToEnd(tracks: [MusicTrack]) {
        queue.append(contentsOf: tracks)
        originalQueue.append(contentsOf: tracks)
    }

    // MARK: - Playback Controls

    // Play and pause both end a scan where it reached, as AVKit's do.
    func play() {
        endScan()
        player.play()
    }

    func pause() {
        endScan()
        player.pause()
    }

    func togglePlayPause() {
        // During a scan the press means "play from here", whatever the state under it.
        if scanLevel != 0 { return play() }
        if playbackState == .playing {
            pause()
        } else {
            play()
        }
    }

    func stop() {
        finishReport(at: currentTime)
        resetScan()
        player.stop()
        progressTimer?.invalidate()
        progressTimer = nil
        playbackState = .idle
        currentTime = 0
        duration = 0
        nowPlayingBridge.clear()
    }

    /// Skip to the next track in the queue. A manual Next advances under
    /// Repeat One too; only a track that ends by itself repeats (`onTrackEnded`).
    func skipToNext() {
        guard let current = currentTrack else { return }

        // Move current to history
        history.append(current)

        if let nextTrack = queue.first {
            queue.removeFirst()
            currentTrack = nextTrack
            startPlayback(track: nextTrack)
        } else if repeatMode == .all {
            // Rebuild queue from history
            queue = history
            history = []
            let firstTrack = queue.removeFirst()
            currentTrack = firstTrack
            startPlayback(track: firstTrack)
        } else {
            // Queue exhausted: nothing is left for Now Playing to show.
            currentTrack = nil
            stop()
            showNowPlaying = false
        }
    }

    static let restartThreshold: TimeInterval = 4

    /// Skip to the previous track
    func skipToPrevious() {
        resetScan()
        // More than 4 seconds in (Apple's threshold), restart the current track. Not while
        // the next one loads: the clock still holds the last track's position.
        if currentTime > Self.restartThreshold, playbackState != .loading {
            player.seek(to: 0)
            return
        }

        guard let current = currentTrack else { return }

        if let previousTrack = history.last {
            history.removeLast()
            // Put current back at front of queue
            queue.insert(current, at: 0)
            currentTrack = previousTrack
            startPlayback(track: previousTrack)
        } else {
            // No history, restart current track
            player.seek(to: 0)
        }
    }

    /// Toggle shuffle mode
    func toggleShuffle() {
        isShuffled.toggle()
        if isShuffled {
            queue.shuffle()
        } else {
            // Restore original order from current position
            restoreOriginalOrder()
        }
        nowPlayingBridge.updateShuffleRepeat(shuffle: isShuffled, repeat: repeatMode)
    }

    /// Cycle through repeat modes: off → all → one → off
    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        nowPlayingBridge.updateShuffleRepeat(shuffle: isShuffled, repeat: repeatMode)
    }

    /// Seek to a specific time
    func seek(to time: TimeInterval) {
        resetScan()
        player.seek(to: time)
    }

    /// The position right now, for a reader that follows the song frame by frame.
    var playbackTime: TimeInterval { scanLevel != 0 ? currentTime : player.playbackTime }

    // MARK: - Scan

    /// AVKit's scan table stops at 96x, `ShuttleGrammar` level 4.
    static let scanMaxLevel = 4
    private static let scanTick: TimeInterval = 0.1

    /// A hold on the timeline starts a scan at 8x, and each further Left or Right steps it
    /// (24, 48, 96, or back down). It runs on after the release, as AVKit's does.
    func scan(forward: Bool) {
        guard currentTrack != nil, duration > 0, playbackState != .loading else { return }
        if scanLevel == 0 {
            scanStart = player.playbackTime
            currentTime = scanStart
            scanTicks = 0
            let timer = Timer(timeInterval: Self.scanTick, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.advanceScan() }
            }
            RunLoop.main.add(timer, forMode: .common)
            scanTimer = timer
        }
        let level = ShuttleGrammar.step(current: scanLevel, clickForward: forward)
        scanLevel = min(max(level, -Self.scanMaxLevel), Self.scanMaxLevel)
    }

    /// Ends a scan where it reached, or back where it began when cancelled.
    func endScan(cancelled: Bool = false) {
        guard scanLevel != 0 else { return }
        resetScan()
        if cancelled { currentTime = scanStart }
        player.seek(to: currentTime)
    }

    private func resetScan() {
        scanTimer?.invalidate()
        scanTimer = nil
        scanLevel = 0
    }

    /// One tick of the scan. Internal for tests.
    func advanceScan() {
        let step = ShuttleGrammar.rate(forLevel: scanLevel) * Self.scanTick
        let time = currentTime + (scanLevel > 0 ? step : -step)
        // Past the end is the next track; the start is as far back as a scan goes.
        guard time < duration else {
            resetScan()
            return skipToNext()
        }
        currentTime = max(0, time)
        guard time > 0 else { return endScan() }
        // The player follows a few times a second, so the scan is heard as well as seen.
        scanTicks += 1
        if scanTicks % 3 == 0 { player.seek(to: currentTime) }
    }

    /// Jump to a specific track in the queue
    func jumpToQueueItem(at index: Int) {
        guard queue.indices.contains(index) else { return }

        if let current = currentTrack {
            history.append(current)
        }

        // Move skipped queue items to history
        let skipped = Array(queue.prefix(index))
        history.append(contentsOf: skipped)

        let track = queue[index]
        queue.removeSubrange(0...index)
        currentTrack = track
        startPlayback(track: track)
    }

    /// Jump back to a track in the history. Everything after it plays again.
    func jumpToHistoryItem(at index: Int) {
        guard history.indices.contains(index) else { return }
        let track = history[index]
        queue.insert(contentsOf: history.suffix(from: index + 1) + [currentTrack].compactMap { $0 }, at: 0)
        history.removeSubrange(index...)
        currentTrack = track
        startPlayback(track: track)
    }

    // MARK: - Favorites

    func isFavorite(_ track: MusicTrack) -> Bool {
        // Another profile's stars are not this one's.
        guard favoritesGeneration == musicRegistry?.generation else { return track.userState.isFavorite }
        return favoriteOverrides[track.ref] ?? track.userState.isFavorite
    }

    /// Flips a track's favorite at once and writes it to the provider. A failed
    /// write puts back the last value the server took. The task is returned for tests.
    @discardableResult
    func toggleFavorite(_ track: MusicTrack) -> Task<Void, Never>? {
        guard let registry = musicRegistry, let provider = registry.provider(for: track.ref.providerID) else { return nil }
        if favoritesGeneration != registry.generation {
            favoriteOverrides = [:]
            favoriteWriters = [:]
            favoritesGeneration = registry.generation
        }
        let ref = track.ref, generation = favoritesGeneration
        let current = isFavorite(track)
        favoriteOverrides[ref] = !current
        // A write is in flight: its writer sends this value next, so two never race.
        if let writer = favoriteWriters[ref] { return writer }
        let writer = Task { @MainActor in
            var confirmed = current
            while favoritesGeneration == generation, let wanted = favoriteOverrides[ref], wanted != confirmed {
                do {
                    try await provider.setFavorite(wanted, for: ref)
                    confirmed = wanted
                } catch {
                    print("[MusicQueue] setFavorite failed: \(error)")
                    if favoritesGeneration == generation { favoriteOverrides[ref] = confirmed }
                    break
                }
            }
            if favoritesGeneration == generation { favoriteWriters[ref] = nil }
        }
        favoriteWriters[ref] = writer
        return writer
    }

    // MARK: - Private Helpers

    private func startPlayback(track: MusicTrack) {
        finishReport(at: currentTime)
        resetScan()
        playbackState = .loading

        Task { @MainActor in
            do {
                guard let registry = musicRegistry else {
                    print("[MusicQueue] registry not configured; cannot resolve stream")
                    playbackState = .idle
                    return
                }
                guard let provider = registry.provider(for: track.ref.providerID) else {
                    print("[MusicQueue] no provider for \(track.ref.providerID)")
                    playbackState = .idle
                    return
                }
                let stream = try await provider.resolveStream(for: track.ref)
                // Skipped on, or the queue ended, while this resolved: a newer call owns the player.
                guard currentTrack?.ref == track.ref else { return }
                guard let url = stream.source.streamURL else {
                    print("[MusicQueue] provider returned no stream URL")
                    playbackState = .idle
                    return
                }
                // A film started while this was resolving. Loading now would
                // start the song over it and switch the audio session away from
                // movie playback; leave it for the user to start again.
                guard !videoOwnsNowPlaying else {
                    playbackState = .idle
                    return
                }
                player.load(url: url, headers: [:], useEngine: MusicCodecPolicy.needsEngine(codec: track.audioCodec))
                reporter = provider.progressReporter(for: track.ref, stream: stream)
                if let reporter { Task { await reporter.start(position: 0) } }

                // Update Now Playing
                nowPlayingBridge.update(
                    track: track,
                    queue: queue,
                    history: history,
                    isPlaying: true,
                    currentTime: 0,
                    duration: track.duration
                )

                // Start progress reporting
                startProgressTimer(trackRef: track.ref, durationSec: track.duration)
            } catch {
                print("[MusicQueue] resolveStream failed: \(error)")
                playbackState = .idle
            }
        }
    }

    /// Off the playback path: a slow or missing lyric lookup never delays the song.
    private func loadLyrics() {
        currentLyrics = nil
        guard let ref = currentTrack?.ref,
              let provider = musicRegistry?.provider(for: ref.providerID) else { return }
        Task { @MainActor in
            let lines = try? await provider.lyrics(for: ref)
            // The user may have skipped on while this was in flight.
            if currentTrack?.ref == ref { currentLyrics = lines }
        }
    }

    private func bindPlayerState() {
        player.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .idle: self.playbackState = .idle
                case .loading: self.playbackState = .loading
                case .playing:
                    self.playbackState = .playing
                    // Take back next/previous from the video player, which turns
                    // them off while it owns the command center. A resume after a
                    // film starts no new track, so claiming only on track change
                    // left them dead.
                    if !self.videoOwnsNowPlaying { self.nowPlayingBridge.claimRemoteCommands() }
                case .paused: self.playbackState = .paused
                case .ended: self.onTrackEnded()
                }
            }
            .store(in: &cancellables)

        player.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                // A scan owns the clock while it runs.
                if self?.scanLevel == 0 { self?.currentTime = time }
            }
            .store(in: &cancellables)

        player.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dur in
                self?.duration = dur
            }
            .store(in: &cancellables)
    }

    private func onTrackEnded() {
        // Mark as watched
        if reporter != nil {
            finishReport(at: max(duration, currentTrack?.duration ?? 0))
        } else if let ref = currentTrack?.ref {
            Task {
                await PlexProgressReporter.shared.markAsWatched(ratingKey: ref.itemID)
            }
        }

        if repeatMode == .one, let current = currentTrack {
            // The queue player drops an item that ends, so a seek to zero has
            // nothing to play: load the track again.
            startPlayback(track: current)
        } else {
            skipToNext()
        }
    }

    private func startProgressTimer(trackRef: MediaItemRef, durationSec: TimeInterval) {
        progressTimer?.invalidate()

        progressTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playbackState == .playing || self.playbackState == .paused else { return }
                let state = self.playbackState == .playing ? "playing" : "paused"
                if let reporter = self.reporter {
                    let time = self.currentTime
                    if state == "playing" { await reporter.progress(position: time) } else { await reporter.paused(at: time) }
                } else {
                    await PlexProgressReporter.shared.reportProgress(
                        ratingKey: trackRef.itemID,
                        time: self.currentTime,
                        duration: durationSec,
                        state: state
                    )
                }

                // Update Now Playing time, unless a video owns the entry
                // (see `videoOwnsNowPlaying`).
                if !self.videoOwnsNowPlaying {
                    self.nowPlayingBridge.updateTime(
                        currentTime: self.currentTime,
                        duration: durationSec,
                        isPlaying: self.playbackState == .playing
                    )
                }
            }
        }
    }

    /// Ends the previous track's report before a new one starts or the queue stops.
    private func finishReport(at position: TimeInterval) {
        guard let reporter else { return }
        self.reporter = nil
        Task { await reporter.stopped(at: position) }
    }

    private func restoreOriginalOrder() {
        guard let current = currentTrack,
              let currentIndex = originalQueue.firstIndex(where: { $0.ref == current.ref }) else { return }
        // What is still upcoming, counted: a track queued again after it played stays.
        var upcoming = Dictionary(queue.map { ($0.ref, 1) }, uniquingKeysWith: +)
        queue = originalQueue.suffix(from: currentIndex + 1).filter { item in
            guard let count = upcoming[item.ref], count > 0 else { return false }
            upcoming[item.ref] = count - 1
            return true
        }
    }
}
