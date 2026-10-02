// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerPresenter.swift
//  Rivulet
//
//  Single source of truth for building the playback presentation host.
//  Aether is the only VOD engine; every VOD session presents through
//  PlayerContainerViewController.
//

import SwiftUI
import UIKit

@MainActor
enum PlayerPresenter {

    /// Build the UIViewController to present for the given playback session.
    static func makeViewController(
        viewModel: UniversalPlayerViewModel,
        onDismiss: (() -> Void)? = nil
    ) -> UIViewController {
        let inputCoordinator = PlaybackInputCoordinator()
        let playerView = UniversalPlayerView(
            viewModel: viewModel,
            inputCoordinator: inputCoordinator
        )
        let vc = PlayerContainerViewController(
            rootView: playerView,
            viewModel: viewModel,
            inputCoordinator: inputCoordinator
        )
        vc.onDismiss = onDismiss
        return vc
    }

    /// Only the Plex path needs the Plex server. A provider item has already
    /// resolved its stream from its own server, so Plex being offline is no
    /// reason to refuse it.
    static func requiresPlexConnection(for source: PlaybackSource) -> Bool {
        if case .plex = source { return true }
        return false
    }

    /// Present a playback session, walking to whatever is actually on screen
    /// above `presenter`. Every VOD play path goes through here, which makes
    /// it the one place the offline gate has to live: returns false when the
    /// Plex server is unreachable on a Plex item, having shown the popup
    /// instead. A Retry that reconnects re-runs the presentation.
    @discardableResult
    static func present(
        viewModel: UniversalPlayerViewModel,
        from presenter: UIViewController,
        animated: Bool = true,
        onDismiss: (() -> Void)? = nil
    ) -> Bool {
        if requiresPlexConnection(for: viewModel.source) {
            let allowed = ConnectionAlert.allowPlayback(from: presenter) {
                present(viewModel: viewModel, from: presenter,
                        animated: animated, onDismiss: onDismiss)
            }
            guard allowed else { return false }
        }
        let vc = makeViewController(viewModel: viewModel, onDismiss: onDismiss)
        presenter.topmostPresented.present(vc, animated: animated)
        return true
    }
}
