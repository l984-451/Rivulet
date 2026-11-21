// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveChannelPresenter.swift
//  Rivulet
//
//  Playing a channel from a page that has no corner player (Search, the
//  List): full screen on the glass rail, Back ends it, and multiview and
//  Watch with Scores hand over as they do from What's On. The programme menu
//  from such a page as well.
//

import UIKit

@MainActor
enum LiveChannelPresenter {
    /// `sourceIdFilter`: the source a page shows (the List's sidebar entry), which multiview keeps.
    /// `onDismiss`: the channel on screen when Back ended it, for the page to focus.
    static func play(_ channel: UnifiedChannel, from presenter: UIViewController,
                     adopting session: LiveTVSessionHandoff? = nil, animated: Bool = true,
                     sourceIdFilter: String? = nil, onDismiss: ((UnifiedChannel) -> Void)? = nil) {
        let player = LiveTVAetherPlayerViewController(channel: channel, adopting: session)
        player.modalPresentationStyle = .fullScreen
        player.onOpenMultiview = { [weak presenter] session in
            guard let presenter else { return }
            presentMultiview(adopting: session, adding: nil, from: presenter, fromPlayer: true,
                             sourceIdFilter: sourceIdFilter, onDismiss: onDismiss)
        }
        player.onWatchWithScores = { [weak presenter, weak player] in
            player?.openMultiview { session in
                guard let presenter else { return }
                presentMultiview(adopting: session, adding: nil, from: presenter, fromPlayer: true, scores: true,
                                 sourceIdFilter: sourceIdFilter, onDismiss: onDismiss)
            }
        }
        if let onDismiss { player.onDismiss = onDismiss }
        presenter.present(player, animated: animated)
    }

    /// `fromPlayer`: the full-screen player just closed without animation, and
    /// multiview takes over its picture (see `entersFromFullScreen`).
    static func presentMultiview(adopting session: LiveTVSessionHandoff?, adding channel: UnifiedChannel?,
                                 from presenter: UIViewController, fromPlayer: Bool = false, scores: Bool = false,
                                 sourceIdFilter: String? = nil, onDismiss: ((UnifiedChannel) -> Void)? = nil) {
        let multiview = LiveMultiviewViewController(adopting: session, adding: channel, sourceIdFilter: sourceIdFilter)
        multiview.entersFromFullScreen = fromPlayer
        multiview.startsWithScores = scores
        multiview.onWatchFullScreen = { [weak presenter] session in
            guard let presenter else { return }
            play(session.channel, from: presenter, adopting: session, animated: false,
                 sourceIdFilter: sourceIdFilter, onDismiss: onDismiss)
        }
        presenter.present(multiview, animated: !fromPlayer)
    }

    /// The programme menu for a channel and what it airs.
    static func presentMenu(channel: UnifiedChannel, program: UnifiedProgram?, from presenter: UIViewController,
                            sourceFrame: CGRect?, sourceIdFilter: String? = nil,
                            onDismiss: ((UnifiedChannel) -> Void)? = nil) {
        LiveProgramMenu.present(
            program: program, channel: channel, from: presenter, sourceFrame: sourceFrame,
            onWatch: { [weak presenter] channel in
                guard let presenter else { return }
                play(channel, from: presenter, sourceIdFilter: sourceIdFilter, onDismiss: onDismiss)
            },
            onMultiview: { [weak presenter] channel in
                guard let presenter else { return }
                presentMultiview(adopting: nil, adding: channel, from: presenter,
                                 sourceIdFilter: sourceIdFilter, onDismiss: onDismiss)
            })
    }
}
