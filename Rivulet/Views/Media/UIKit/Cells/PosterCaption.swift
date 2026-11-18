// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// The title line under a tile (Settings → Titles Under Posters), shared by the poster,
// watchlist and Continue Watching cells.

import UIKit

@MainActor
final class PosterCaption {
    private let label = UILabel()
    /// The tile's vertical centring; lifted by half the caption so the artwork keeps its row position.
    private let tileCenterY: NSLayoutConstraint

    /// Pins the label under `host` (the focused tile's extent), `inset` inside `leading` and `trailing`.
    init(in contentView: UIView, under host: UIView,
         leading: NSLayoutXAxisAnchor, trailing: NSLayoutXAxisAnchor, inset: CGFloat = 0,
         tileCenterY: NSLayoutConstraint) {
        self.tileCenterY = tileCenterY
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 24, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        // A cut-off title scrolls while its tile holds focus, as the Apple TV app's do.
        label.enablesMarqueeWhenAncestorFocused = true
        label.isHidden = true
        contentView.addSubview(label)
        setFocused(false)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: host.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: leading, constant: inset),
            label.trailingAnchor.constraint(equalTo: trailing, constant: -inset)
        ])
    }

    /// nil: the cell has no caption row. Any string, even empty, means the row is
    /// `MediaRowMetrics.posterCaptionHeight` taller and the tile is lifted to make room.
    func set(_ text: String?) {
        label.text = text
        label.isHidden = (text ?? "").isEmpty
        tileCenterY.constant = text == nil ? 0 : -MediaRowMetrics.posterCaptionHeight / 2
    }

    func setFocused(_ focused: Bool) {
        label.textColor = UIColor.white.withAlphaComponent(focused ? 1 : 0.6)
    }

    /// A poster's caption: an episode names itself (the art is its show's), a season its show.
    static func text(for item: MediaItem) -> String {
        switch item.kind {
        case .episode:
            guard let season = item.seasonNumber, let episode = item.episodeNumber else { return item.title }
            return String(localized: "S\(season) E\(episode) · \(item.title)")
        case .season: return item.seriesTitle ?? item.title
        default: return item.title
        }
    }
}
