// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ProviderPlayer.swift
//  Rivulet
//
//  The tvOS play entry point for any item that is not on the Plex path. Every
//  surface's Play routes a non-Plex item here.
//

import UIKit

enum ProviderPlayer {
    /// True while a play is preparing. A second press in that window is
    /// ignored, so one press presents one player.
    @MainActor private(set) static var isStarting = false

    /// Claims the start, or returns false when one is already preparing.
    @MainActor static func claimStart() -> Bool {
        guard !isStarting else { return false }
        isStarting = true
        return true
    }

    @MainActor static func finishStart() { isStarting = false }

    /// Where playback starts: the server's resume point unless the user
    /// chose the beginning. Zero means no resume point.
    static func startOffset(detailOffset: TimeInterval, fromBeginning: Bool) -> TimeInterval? {
        ProviderPlayback.startOffset(detailOffset: detailOffset, fromBeginning: fromBeginning)
    }

    /// A Plex item's resume point in seconds, gated on the shared resume policy
    /// as the selected server's play path does.
    static func plexStartOffset(_ metadata: PlexMetadata, fromBeginning: Bool) -> TimeInterval? {
        guard !fromBeginning, metadata.isInProgress else { return nil }
        return metadata.viewOffset.map { TimeInterval($0) / 1000 }
    }

    /// Play `item` from its own provider. A show or a season resolves to the
    /// episode Play means first, the same way the Plex path does. `playQueue`
    /// is the playlist `item` starts.
    @MainActor
    static func play(_ item: MediaItem, fromBeginning: Bool, sourceID: String? = nil,
                     playQueue: PlayQueue<PlaylistEntry>? = nil, explicitStartOffset: TimeInterval? = nil,
                     from presenter: UIViewController, onDismiss: (() -> Void)?) {
        guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else {
            presentError(MediaProviderError.notFound, from: presenter)
            return
        }
        guard claimStart() else { return }
        Task { @MainActor in
            defer { finishStart() }
            var target = item
            var explicitStartOffset = explicitStartOffset
            if item.kind == .show || item.kind == .season {
                target = await EpisodePicker.resolvePlayTarget(for: item, provider: provider) ?? item
                explicitStartOffset = nil  // an offset names a time in one title, not in a show
            }
            // The loading screen's art, fetched while the stream is resolved.
            async let loadingImages = HeroBackdropResolver.shared.playerLoadingImages(
                for: target.heroBackdropRequest())
            // Another Plex server's item takes the full Plex player with its own
            // server: markers, transcode fallback, content filter, BIF (#87).
            if let plex = provider as? PlexProvider {
                do {
                    let metadata = try await PlexNetworkManager.shared.getFullMetadata(
                        serverURL: plex.serverURL, authToken: plex.authToken, ratingKey: target.ref.itemID)
                    let (art, thumb) = await loadingImages
                    let viewModel = UniversalPlayerViewModel(
                        metadata: metadata, serverURL: plex.serverURL, authToken: plex.authToken,
                        startOffset: explicitStartOffset ?? plexStartOffset(metadata, fromBeginning: fromBeginning),
                        playQueue: playQueue,
                        loadingArtImage: art, loadingThumbImage: thumb, preferredMediaID: sourceID)
                    PlayerPresenter.present(viewModel: viewModel, from: presenter, onDismiss: onDismiss)
                } catch {
                    presentError(MediaProviderError.mapping(error), from: presenter)
                }
                return
            }
            do {
                let playback = try await ProviderPlayback.prepare(
                    item: target, provider: provider, version: sourceID.map(VersionChoice.source) ?? .best,
                    fromBeginning: fromBeginning, explicitStartOffset: explicitStartOffset, awaitingExtras: false)
                let (art, thumb) = await loadingImages
                let viewModel = UniversalPlayerViewModel(
                    providerPlayback: playback,
                    startOffset: explicitStartOffset ?? startOffset(detailOffset: playback.detail.item.userState.viewOffset,
                                                                   fromBeginning: fromBeginning),
                    playQueue: playQueue,
                    loadingArtImage: art,
                    loadingThumbImage: thumb,
                    preferredMediaID: sourceID)
                PlayerPresenter.present(viewModel: viewModel, from: presenter, onDismiss: onDismiss)
            } catch {
                presentError(error, from: presenter)
            }
        }
    }

    /// What the error popup says for a failed start.
    static func errorMessage(for error: Error) -> String {
        switch error as? MediaProviderError {
        case .transcodeRequired: String(localized: "This server can't stream this title to Apple TV.")
        case .unreachable: String(localized: "Couldn't reach the server.")
        case .unauthorized: String(localized: "The server didn't accept your sign-in.")
        default: String(localized: "Something went wrong starting playback.")
        }
    }

    @MainActor
    static func presentError(_ error: Error, from presenter: UIViewController) {
        let popup = ConfirmationPopupViewController(
            title: String(localized: "Couldn't Play"), message: errorMessage(for: error),
            confirmTitle: String(localized: "OK"), cancelTitle: nil, onConfirm: {})
        presenter.topmostPresented.present(popup, animated: true)
    }
}
