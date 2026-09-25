// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicNowPlayingBridge.swift
//  Rivulet
//
//  Bridges MusicQueue state to MPNowPlayingInfoCenter and MPRemoteCommandCenter.
//  Configures system Now Playing with music-specific fields and remote commands.
//

import Foundation
import MediaPlayer
import UIKit

/// Bridges music playback state to the system Now Playing integration.
/// Handles artwork loading, remote commands (next/prev/shuffle/repeat), and metadata display.
@MainActor
final class MusicNowPlayingBridge {

    // MARK: - Private State

    private var artworkTask: Task<Void, Never>?
    private var cachedArtwork: MPMediaItemArtwork?
    private var cachedArtworkThumb: String?
    private var commandTargets: [Any] = []

    // MARK: - Initialization

    init() {
        setupRemoteCommands()
    }

    // MARK: - Update Now Playing

    /// Full update when track changes
    func update(
        track: MusicTrack,
        queue: [MusicTrack],
        history: [MusicTrack],
        isPlaying: Bool,
        currentTime: TimeInterval,
        duration: TimeInterval
    ) {
        // Ensure audio session is active for Now Playing registration
        PlaybackAudioSessionConfigurator.activatePlaybackSession(
            mode: .default,
            owner: "MusicNowPlaying"
        )
        claimRemoteCommands()

        var info = [String: Any]()

        // Track metadata
        info[MPMediaItemPropertyTitle] = track.title
        info[MPMediaItemPropertyArtist] = track.artistName ?? "Unknown Artist"
        info[MPMediaItemPropertyAlbumTitle] = track.albumTitle ?? ""
        info[MPMediaItemPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue

        // Timing
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        // Queue position
        let totalCount = history.count + 1 + queue.count
        info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = history.count
        info[MPNowPlayingInfoPropertyPlaybackQueueCount] = totalCount

        // Track number
        if let trackNumber = track.trackNumber {
            info[MPMediaItemPropertyAlbumTrackNumber] = trackNumber
        }

        // Reuse cached artwork if same poster URL
        let artworkKey = track.artwork.poster?.absoluteString ?? ""
        if let artwork = cachedArtwork, cachedArtworkThumb == artworkKey {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        // Load artwork async
        loadArtwork(for: track)
    }

    /// Lightweight time update (called every few seconds)
    func updateTime(currentTime: TimeInterval, duration: TimeInterval, isPlaying: Bool) {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Update shuffle/repeat state display
    func updateShuffleRepeat(shuffle: Bool, repeat repeatMode: MusicRepeatMode) {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Clear all Now Playing info
    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        artworkTask?.cancel()
        artworkTask = nil
        cachedArtwork = nil
        cachedArtworkThumb = nil
    }

    // MARK: - Remote Commands

    /// Music's half of the one shared command center: next/previous, shuffle
    /// and repeat on; the video player's skip and seek off (their handlers do
    /// nothing without a video, and left enabled they compete with
    /// next/previous for the system's transport buttons). `NowPlayingService.attach` claims
    /// the other half. Both used to be set once, at each service's first use,
    /// so whichever player started second kept its layout for the whole
    /// session: after the first film, Music's next/previous stayed disabled.
    func claimRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changeShuffleModeCommand.isEnabled = true
        center.changeRepeatModeCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
    }

    // Every handler below stands down while a video owns Now Playing: both
    // players register targets on the same shared center, so a command sent
    // during a film can reach the queue too (see
    // `MusicQueue.videoOwnsNowPlaying`).
    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        // Play/Pause
        let playTarget = center.playCommand.addTarget { _ in
            Task { @MainActor in
                guard !MusicQueue.shared.videoOwnsNowPlaying else { return }
                MusicQueue.shared.play()
            }
            return .success
        }
        commandTargets.append(playTarget)

        let pauseTarget = center.pauseCommand.addTarget { _ in
            Task { @MainActor in
                guard !MusicQueue.shared.videoOwnsNowPlaying else { return }
                MusicQueue.shared.pause()
            }
            return .success
        }
        commandTargets.append(pauseTarget)

        let toggleTarget = center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in
                guard !MusicQueue.shared.videoOwnsNowPlaying else { return }
                MusicQueue.shared.togglePlayPause()
            }
            return .success
        }
        commandTargets.append(toggleTarget)

        // Next/Previous track
        center.nextTrackCommand.isEnabled = true
        let nextTarget = center.nextTrackCommand.addTarget { _ in
            Task { @MainActor in
                guard !MusicQueue.shared.videoOwnsNowPlaying else { return }
                MusicQueue.shared.skipToNext()
            }
            return .success
        }
        commandTargets.append(nextTarget)

        center.previousTrackCommand.isEnabled = true
        let prevTarget = center.previousTrackCommand.addTarget { _ in
            Task { @MainActor in
                guard !MusicQueue.shared.videoOwnsNowPlaying else { return }
                MusicQueue.shared.skipToPrevious()
            }
            return .success
        }
        commandTargets.append(prevTarget)

        // Seek
        center.changePlaybackPositionCommand.isEnabled = true
        let seekTarget = center.changePlaybackPositionCommand.addTarget { event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = positionEvent.positionTime
            Task { @MainActor in
                guard !MusicQueue.shared.videoOwnsNowPlaying else { return }
                MusicQueue.shared.seek(to: position)
            }
            return .success
        }
        commandTargets.append(seekTarget)

        // Shuffle
        center.changeShuffleModeCommand.isEnabled = true
        let shuffleTarget = center.changeShuffleModeCommand.addTarget { _ in
            Task { @MainActor in
                guard !MusicQueue.shared.videoOwnsNowPlaying else { return }
                MusicQueue.shared.toggleShuffle()
            }
            return .success
        }
        commandTargets.append(shuffleTarget)

        // Repeat
        center.changeRepeatModeCommand.isEnabled = true
        let repeatTarget = center.changeRepeatModeCommand.addTarget { _ in
            Task { @MainActor in
                guard !MusicQueue.shared.videoOwnsNowPlaying else { return }
                MusicQueue.shared.cycleRepeatMode()
            }
            return .success
        }
        commandTargets.append(repeatTarget)
    }

    // MARK: - Artwork Loading

    private func loadArtwork(for track: MusicTrack) {
        artworkTask?.cancel()
        guard let url = track.artwork.poster else {
            cachedArtwork = nil
            cachedArtworkThumb = nil
            return
        }
        let key = url.absoluteString
        if cachedArtworkThumb == key, cachedArtwork != nil { return }
        artworkTask = Task { @MainActor in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let image = UIImage(data: data) else { return }
                let mpArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.cachedArtwork = mpArtwork
                self.cachedArtworkThumb = key
                if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                    info[MPMediaItemPropertyArtwork] = mpArtwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                }
            } catch {}
        }
    }
}
