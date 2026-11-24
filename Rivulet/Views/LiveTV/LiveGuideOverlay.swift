// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveGuideOverlay.swift
//  Rivulet
//
//  The guide laid over a playing channel (Right in the live player): the
//  existing guide, see-through, on the channel's own group and focused on it.
//  The channel plays on behind it. Built here so the UIKit player needs no
//  SwiftUI of its own.
//

import SwiftUI

@MainActor
enum LiveGuideOverlay {
    static func make(playing channel: UnifiedChannel,
                     onSelect: @escaping (UnifiedChannel) -> Void,
                     onClose: @escaping () -> Void) -> UIViewController {
        let host = UIHostingController(rootView: GuideLayoutView(
            sourceIdFilter: channel.sourceId,
            initialGroup: LiveGroupOrder.trimmed(channel.groupTitle),
            initialChannelId: channel.id,
            onExit: { _, _ in onClose() },
            overPlayer: true,
            onSelectChannel: onSelect))
        host.view.backgroundColor = .clear
        return host
    }

    /// What sits between the picture and the guide: the picture darkened under the programme's
    /// title, as AVKit dims under its controls, and one sheet of the player panes' glass under
    /// the pills and grid, rising from the bottom edge. UIKit, as the panes' glass is.
    static func backdrop() -> UIView {
        let backdrop = UIView()
        backdrop.isUserInteractionEnabled = false
        backdrop.backgroundColor = UIColor(white: 0, alpha: 0.35)
        let sheet = UIVisualEffectView(effect: {
            let effect = UIGlassEffect(style: .regular)
            effect.tintColor = UIColor(white: 0, alpha: 0.35)
            return effect
        }())
        sheet.clipsToBounds = true
        sheet.layer.cornerRadius = 54
        sheet.layer.cornerCurve = .continuous
        sheet.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        sheet.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(sheet)
        NSLayoutConstraint.activate([
            sheet.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: EPGTheme.infoBarHeight - 14),
            sheet.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: EPGTheme.pageMargin / 2),
            sheet.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -EPGTheme.pageMargin / 2),
            // Past the bottom edge, so only the top corners show.
            sheet.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: 60),
        ])
        return backdrop
    }
}
