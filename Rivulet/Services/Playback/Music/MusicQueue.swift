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
import SwiftUI

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

/// Global music queue manager — singleton that persists across navigation.
/// Music plays in the background while the user browses other content.
@MainActor
final class MusicQueue: ObservableObject {

    // MARK: - Singleton

    static let shared = MusicQueue()

    // MARK: - Published State

    @Published var currentTrack: MusicTrack?
    @Published var queue: [MusicTrack] = []
    @Published var history: [MusicTrack] = []
    @Published var playbackState: MusicPlaybackState = .idle
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var repeatMode: MusicRepeatMode = .off
    @Published var isShuffled: Bool = false
    @Published var showNowPlaying: Bool = false

    /// Whether music is actively playing or paused (i.e., a session exists)
    var isActive: Bool { currentTrack != nil }

    /// True while a video player is up. The system has ONE Now Playing entry
    /// and one remote-command center, and both players register handlers on
    /// it: a Control Center, iPhone Remote or HDMI-CEC play/pause during a film
    /// also toggled the paused song underneath it, and this queue's progress
    /// timer kept writing the song's position and a zero rate into the film's
    /// entry, so the system scrubber showed the wrong time.
    private(set) var videoOwnsNowPlaying = false

    // MARK: - Private State

    private let player = MusicPlayer()
    private let nowPlayingBridge = MusicNowPlayingBridge()
    private var cancellables = Set<AnyCancellable>()
    private var originalQueue: [MusicTrack] = []
    private var progressTimer: Timer?
    private var musicRegistry: MusicProviderRegistry?

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
            Task { @MainActor in
                self?.videoOwnsNowPlaying = true
                // A film does not play over a song.
                if self?.playbackState == .playing { self?.pause() }
            }
        }

        NotificationCenter.default.addObserver(
            forName: .plexPlaybackStopped,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.videoOwnsNowPlaying = false
            }
        }
    }

    // MARK: - Configuration

    /// Called once at app launch after MusicProviderRegistry is populated.
    func configure(registry: MusicProviderRegistry) {
        self.musicRegistry = registry
    }

    // MARK: - Queue Operations

    /// Clear all queue state (current, queue, history) without stopping playback.
    /// Mostly for tests.
    func clear() {
        currentTrack = nil
        queue = []
        history = []
        originalQueue = []
    }

    /// Play a single track immediately, clearing the queue
    func playNow(track: MusicTrack) {
        history = []
        queue = []
        originalQueue = []
        currentTrack = track
        startPlayback(track: track)
    }

    /// Play an album/tracklist starting at a specific index
    func playAlbum(tracks: [MusicTrack], startingAt index: Int = 0) {
        guard !tracks.isEmpty else { return }
        let clampedIndex = min(index, tracks.count - 1)

        history = Array(tracks.prefix(clampedIndex))
        currentTrack = tracks[clampedIndex]
        queue = Array(tracks.suffix(from: clampedIndex + 1))
        originalQueue = tracks

        if isShuffled {
            queue.shuffle()
        }

        startPlayback(track: tracks[clampedIndex])
        showNowPlaying = true
    }

    /// Add a track to play next (front of queue)
    func addNext(track: MusicTrack) {
        queue.insert(track, at: 0)
    }

    /// Add a track to the end of the queue
    func addToEnd(track: MusicTrack) {
        queue.append(track)
    }

    /// Add multiple tracks to the end of the queue
    func addToEnd(tracks: [MusicTrack]) {
        queue.append(contentsOf: tracks)
    }

    /// Remove a track from the queue at the given index
    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index) else { return }
        queue.remove(at: index)
    }

    /// Move a queue item
    func moveInQueue(from source: IndexSet, to destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
    }

    /// Clear the entire queue and stop playback
    func clearQueue() {
        stop()
        queue = []
        history = []
        originalQueue = []
        currentTrack = nil
    }

    // MARK: - Playback Controls

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func togglePlayPause() {
        if playbackState == .playing {
            pause()
        } else {
            play()
        }
    }

    func stop() {
        player.stop()
        progressTimer?.invalidate()
        progressTimer = nil
        playbackState = .idle
        currentTime = 0
        duration = 0
        nowPlayingBridge.clear()
    }

    /// Skip to the next track in the queue
    func skipToNext() {
        guard let current = currentTrack else { return }

        // Handle repeat one
        if repeatMode == .one {
            player.seek(to: 0)
            player.play()
            return
        }

        // Move current to history
        history.append(current)

        if let nextTrack = queue.first {
            queue.removeFirst()
            currentTrack = nextTrack
            startPlayback(track: nextTrack)
        } else if repeatMode == .all && !history.isEmpty {
            // Rebuild queue from history
            queue = history
            history = []
            if let firstTrack = queue.first {
                queue.removeFirst()
                currentTrack = firstTrack
                startPlayback(track: firstTrack)
            }
        } else {
            // Queue exhausted
            currentTrack = nil
            stop()
        }
    }

    /// Skip to the previous track
    func skipToPrevious() {
        // If more than 3 seconds in, restart current track
        if currentTime > 3 {
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
        player.seek(to: time)
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

    // MARK: - Private Helpers

    private func startPlayback(track: MusicTrack) {
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
                player.load(url: url, headers: [:])

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
                self?.currentTime = time
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
        if let ref = currentTrack?.ref {
            Task {
                await PlexProgressReporter.shared.markAsWatched(ratingKey: ref.itemID)
            }
        }

        skipToNext()
    }

    private func startProgressTimer(trackRef: MediaItemRef, durationSec: TimeInterval) {
        progressTimer?.invalidate()

        progressTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playbackState == .playing || self.playbackState == .paused else { return }
                let state = self.playbackState == .playing ? "playing" : "paused"
                await PlexProgressReporter.shared.reportProgress(
                    ratingKey: trackRef.itemID,
                    time: self.currentTime,
                    duration: durationSec,
                    state: state
                )

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

    private func restoreOriginalOrder() {
        guard let current = currentTrack else { return }
        // Find current position in original queue
        if let currentIndex = originalQueue.firstIndex(where: { $0.ref == current.ref }) {
            queue = Array(originalQueue.suffix(from: currentIndex + 1))
                .filter { item in
                    // Only include items not already in history
                    !history.contains(where: { $0.ref == item.ref })
                }
        }
    }
}
