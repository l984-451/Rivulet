// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Cell wrapper around `HeroOverlayView`. Never focusable itself; forwards
// `preferredFocusEnvironments` so the engine sees the hero buttons directly.

import UIKit

@MainActor
final class HeroOverlayCell: UICollectionViewCell {
    static let reuseID = "HeroOverlayCell"

    let overlay = HeroOverlayView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        clipsToBounds = false
        contentView.clipsToBounds = false

        overlay.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: contentView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { false }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        return [overlay]
    }

    struct Configuration {
        let items: [PlexMetadata]
        let serverURL: String
        let authToken: String
        let initialIndex: Int
        let onIndexChanged: (Int, PlexMetadata, HeroPageDirection) -> Void
        let onInfo: (PlexMetadata) -> Void
        let onPlay: (PlexMetadata) -> Void
        let onFocusEntered: (() -> Void)?
    }

    /// MediaItem configuration, used by MediaLibraryViewController when `config.showHero` is set.
    struct MediaItemConfiguration {
        let items: [MediaItem]
        let initialIndex: Int
        let onIndexChanged: (Int, MediaItem, HeroPageDirection) -> Void
        let onPlay: (MediaItem) -> Void
        let onInfo: (MediaItem) -> Void
        var onToggleWatchlist: ((MediaItem) -> Void)? = nil
        /// The server badge for a slide, nil for none.
        var badge: ((MediaItem) -> String?)? = nil
    }

    func configure(with config: Configuration) {
        overlay.onIndexChanged = config.onIndexChanged
        overlay.onInfo = config.onInfo
        overlay.onPlay = config.onPlay
        overlay.onFocusEntered = config.onFocusEntered
        overlay.configure(
            items: config.items,
            serverURL: config.serverURL,
            authToken: config.authToken,
            initialIndex: config.initialIndex
        )
    }

    func configure(withMediaItems config: MediaItemConfiguration) {
        overlay.configure(
            mediaItems: config.items,
            initialIndex: config.initialIndex,
            onIndexChanged: config.onIndexChanged,
            onPlay: config.onPlay,
            onInfo: config.onInfo,
            onToggleWatchlist: config.onToggleWatchlist,
            badge: config.badge
        )
    }
}
