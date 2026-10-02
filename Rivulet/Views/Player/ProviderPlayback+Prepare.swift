// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ProviderPlayback+Prepare.swift
//  Rivulet
//
//  The play entry point for any item that is not on the Plex path. Every
//  surface's Play routes a non-Plex item here; nothing in it knows which
//  backend it is talking to.
//

import UIKit

extension ProviderPlayback {
    /// Everything the player needs for `item`, fetched from its provider. The
    /// detail and the stream run concurrently; the extras wait for the stream
    /// so they ask about the source that will actually play.
    static func prepare(item: MediaItem, provider: any MediaProvider) async throws -> ProviderPlayback {
        async let detail = provider.fullDetail(for: item.ref)
        let stream = try await provider.resolveStream(for: item.ref, sourceID: nil)
        async let extras = provider.playbackExtras(for: item.ref, sourceID: stream.source.id)
        return try await ProviderPlayback(provider: provider, item: item, detail: detail,
                                          stream: stream, extras: extras)
    }
}

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
        fromBeginning || detailOffset <= 0 ? nil : detailOffset
    }

    /// Play `item` from its own provider. A show or a season resolves to the
    /// episode Play means first, the same way the Plex path does.
    @MainActor
    static func play(_ item: MediaItem, fromBeginning: Bool,
                     from presenter: UIViewController, onDismiss: (() -> Void)?) {
        guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else {
            presentError(MediaProviderError.notFound, from: presenter)
            return
        }
        guard claimStart() else { return }
        Task { @MainActor in
            defer { finishStart() }
            var target = item
            if item.kind == .show || item.kind == .season {
                target = await EpisodePicker.resolvePlayTarget(for: item, provider: provider) ?? item
            }
            // The loading screen's art, fetched while the stream is resolved.
            async let loadingImages = HeroBackdropResolver.shared.playerLoadingImages(
                for: target.heroBackdropRequest())
            do {
                let playback = try await ProviderPlayback.prepare(item: target, provider: provider)
                let (art, thumb) = await loadingImages
                let viewModel = UniversalPlayerViewModel(
                    providerPlayback: playback,
                    startOffset: startOffset(detailOffset: playback.detail.item.userState.viewOffset,
                                             fromBeginning: fromBeginning),
                    loadingArtImage: art,
                    loadingThumbImage: thumb)
                PlayerPresenter.present(viewModel: viewModel, from: presenter, onDismiss: onDismiss)
            } catch {
                presentError(error, from: presenter)
            }
        }
    }

    /// What the error popup says for a failed start.
    static func errorMessage(for error: Error) -> String {
        switch error as? MediaProviderError {
        case .transcodeRequired: "This server can't stream this title to Apple TV."
        case .unreachable: "Couldn't reach the server."
        case .unauthorized: "The server didn't accept your sign-in."
        default: "Something went wrong starting playback."
        }
    }

    @MainActor
    private static func presentError(_ error: Error, from presenter: UIViewController) {
        let popup = ConfirmationPopupViewController(
            title: "Couldn't Play", message: errorMessage(for: error),
            confirmTitle: "OK", cancelTitle: nil, onConfirm: {})
        presenter.topmostPresented.present(popup, animated: true)
    }
}
