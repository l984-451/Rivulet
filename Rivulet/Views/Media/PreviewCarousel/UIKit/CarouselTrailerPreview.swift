// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  The trailer that takes over the centred card's artwork after a few seconds, as the Apple TV
//  app's does: one AetherPlayer on its own render surface inside the backdrop panel, faded in on
//  the first frame and gone again when the trailer ends. It fills its card the way the artwork
//  does and never changes the TV's display mode.

import AVFoundation
import Combine
import UIKit
import os.log

private let trailerPreviewLog = Logger(subsystem: "com.rivulet.app", category: "TrailerPreview")

@MainActor
final class CarouselTrailerPreview {

    /// Seconds the artwork shows before the trailer starts.
    static let artworkDwell: TimeInterval = 6.5

    /// The video surface; the host places it over the artwork while a trailer plays.
    let surface: UIView = AetherPlayer.makeRenderSurface()

    /// The trailer ended or failed and the surface has faded out: the artwork shows again.
    var onFinished: (() -> Void)?

    var isActive: Bool { player != nil }

    private var player: AetherPlayer?
    private var stateObserver: AnyCancellable?
    private var loadTask: Task<Void, Never>?
    /// Bumped on every start and stop, so a late load or state change can't act on a newer session.
    private var session: UInt64 = 0

    init() {
        surface.isUserInteractionEnabled = false
        surface.clipsToBounds = true
        surface.alpha = 0
    }

    /// Resolves the trailer's stream and plays it on the surface. `server` is the Plex server the
    /// item on screen lives on; other providers resolve through their own stream call.
    func start(_ trailer: MediaItemDetail.Extra, server: PlexServerAddress?) {
        stop()
        session &+= 1
        let session = session
        let player = AetherPlayer()
        player.suppressesDisplayCriteria = true
        // Fills the card as the artwork does, cropping a wider trailer rather than letterboxing it.
        player.videoGravity = .resizeAspectFill
        player.bind(surface: surface)
        self.player = player

        stateObserver = player.playbackStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, self.session == session else { return }
                switch state {
                case .playing:
                    UIView.animate(withDuration: 0.6) { self.surface.alpha = 1 }
                case .ended, .failed:
                    self.finish()
                default:
                    break
                }
            }

        loadTask = Task { [weak self] in
            let stream = await Self.resolveStream(trailer, server: server)
            guard let self, self.session == session else { return }
            guard let stream else { self.finish(); return }
            do {
                try await player.load(url: stream.url, headers: stream.headers, startTime: nil)
                guard self.session == session else { return }
                player.play()
            } catch {
                trailerPreviewLog.error("trailer load failed: \(error.localizedDescription, privacy: .public)")
                self.finish()
            }
        }
    }

    /// Stops playback and hides the surface at once.
    func stop() {
        session &+= 1
        loadTask?.cancel()
        loadTask = nil
        stateObserver = nil
        surface.layer.removeAllAnimations()
        surface.alpha = 0
        if let player {
            player.stop()
            player.unbind(surface: surface)
        }
        player = nil
    }

    /// The trailer ran out: fade the surface away over the artwork, then release the player.
    private func finish() {
        guard let player else { return }
        session &+= 1
        loadTask?.cancel()
        loadTask = nil
        stateObserver = nil
        self.player = nil
        UIView.animate(withDuration: 0.6, animations: { self.surface.alpha = 0 }) { [weak self] _ in
            player.stop()
            guard let self else { return }
            player.unbind(surface: self.surface)
            self.onFinished?()
        }
    }

    // MARK: - Stream resolution

    private struct Stream {
        let url: URL
        let headers: [String: String]?
    }

    /// The same routes `ExtraPlayer` plays: a Plex IVA extra is an absolute part path, a user-added
    /// extra a library ratingKey whose metadata names the part, and any other provider's extra is a
    /// library item of its own.
    private static func resolveStream(_ trailer: MediaItemDetail.Extra, server: PlexServerAddress?) async -> Stream? {
        let key = trailer.playbackKey ?? trailer.id
        if let provider = MediaProviderRegistry.shared.provider(for: trailer.providerID), provider.kind != .plex {
            let ref = MediaItemRef(providerID: trailer.providerID, itemID: key)
            guard let url = try? await provider.resolveStream(for: ref, sourceID: nil).source.streamURL else { return nil }
            return Stream(url: url, headers: nil)
        }
        guard let server = server ?? MediaProviderRegistry.shared.plexServer(for: trailer.providerID),
              let serverURL = URL(string: server.address) else { return nil }
        let partKey: String
        switch ExtraPlaybackKey.route(for: key) {
        case .directPartPath(let path):
            partKey = path
        case .libraryMetadata(let ratingKey):
            guard let metadata = try? await PlexNetworkManager.shared.getMetadata(
                    serverURL: server.address, authToken: server.token, ratingKey: ratingKey),
                  let key = metadata.Media?.first?.Part?.first?.key else { return nil }
            partKey = key
        }
        guard let url = ContentRouter.directPlayURL(partKey: partKey, serverURL: serverURL, authToken: server.token) else {
            return nil
        }
        return Stream(url: url, headers: ["X-Plex-Token": server.token])
    }
}
