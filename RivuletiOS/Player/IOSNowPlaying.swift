// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import MediaPlayer
import UIKit

/// The system Now Playing card (Lock Screen, Control Center, AirPlay) and its
/// remote commands. The only owner: the engine's own Now Playing session stays
/// off on the video path (`ownsVideoNowPlayingSession` defaults to false).
@MainActor
final class IOSNowPlaying {
    struct Item: Equatable {
        var title: String
        var subtitle: String?
        var artworkURL: URL?
        var isLive: Bool
    }

    struct Commands {
        var play: () -> Void
        var pause: () -> Void
        var skip: (Double) -> Void
        /// nil disables position seeking (live).
        var seek: ((Double) -> Void)?
    }

    private var item: Item?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?
    private var targets: [(MPRemoteCommand, Any)] = []

    func start(_ item: Item, commands: Commands, skipBackward: Double, skipForward: Double) {
        stop()
        self.item = item
        register(commands, skipBackward: skipBackward, skipForward: skipForward)
        if let url = item.artworkURL {
            artworkTask = Task { [weak self] in
                guard let image = await IOSArtworkCache.shared.image(for: url), !Task.isCancelled else { return }
                // The handler may run off main; it only reads the captured image.
                self?.artwork = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
                self?.publishArtwork()
            }
        }
    }

    /// Elapsed, rate and duration; the system extrapolates between calls.
    func update(elapsed: Double, duration: Double, rate: Float) {
        guard let item else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPNowPlayingInfoPropertyIsLiveStream: item.isLive,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue
        ]
        if let subtitle = item.subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        if !item.isLive, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = rate > 0 ? .playing : .paused
    }

    func stop() {
        artworkTask?.cancel()
        artworkTask = nil
        artwork = nil
        item = nil
        for (command, target) in targets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        targets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func publishArtwork() {
        guard let artwork, var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func register(_ commands: Commands, skipBackward: Double, skipForward: Double) {
        let center = MPRemoteCommandCenter.shared()
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBackward)]
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForward)]
        center.changePlaybackPositionCommand.isEnabled = commands.seek != nil

        add(center.playCommand) { _ in commands.play(); return .success }
        add(center.pauseCommand) { _ in commands.pause(); return .success }
        add(center.togglePlayPauseCommand) { _ in
            MPNowPlayingInfoCenter.default().playbackState == .playing ? commands.pause() : commands.play()
            return .success
        }
        add(center.skipBackwardCommand) { _ in commands.skip(-skipBackward); return .success }
        add(center.skipForwardCommand) { _ in commands.skip(skipForward); return .success }
        if let seek = commands.seek {
            add(center.changePlaybackPositionCommand) { event in
                guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
                seek(event.positionTime)
                return .success
            }
        }
    }

    private func add(_ command: MPRemoteCommand, handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        command.isEnabled = true
        targets.append((command, command.addTarget(handler: handler)))
    }
}
