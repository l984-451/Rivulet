// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// The title line under a tile (Settings → Titles Under Posters), shared by the poster,
// watchlist and Continue Watching cells.

import UIKit

@MainActor
final class PosterCaption {
    private let label = UILabel()
    /// The year under a movie's or show's title (Settings → Year Under Titles).
    private let yearLabel = UILabel()
    /// False for a caption that never shows a year (Continue Watching), so its tile lifts by the title line only.
    private let carriesYear: Bool
    /// The tile's vertical centring; lifted by half the caption so the artwork keeps its row position.
    private let tileCenterY: NSLayoutConstraint

    /// Pins the label under `host` (the focused tile's extent), `inset` inside `leading` and `trailing`.
    init(in contentView: UIView, under host: UIView,
         leading: NSLayoutXAxisAnchor, trailing: NSLayoutXAxisAnchor, inset: CGFloat = 0,
         tileCenterY: NSLayoutConstraint, carriesYear: Bool = true) {
        self.tileCenterY = tileCenterY
        self.carriesYear = carriesYear
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 24, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        // A cut-off title scrolls while its tile holds focus, as the Apple TV app's do.
        label.enablesMarqueeWhenAncestorFocused = true
        label.isHidden = true
        contentView.addSubview(label)
        yearLabel.translatesAutoresizingMaskIntoConstraints = false
        yearLabel.font = .systemFont(ofSize: 21, weight: .regular)
        yearLabel.isHidden = true
        contentView.addSubview(yearLabel)
        setFocused(false)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: host.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: leading, constant: inset),
            label.trailingAnchor.constraint(equalTo: trailing, constant: -inset),
            yearLabel.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 1),
            yearLabel.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            yearLabel.trailingAnchor.constraint(equalTo: label.trailingAnchor)
        ])
    }

    /// nil: the cell has no caption row. Any string, even empty, means the row is
    /// `MediaRowMetrics.posterCaptionHeight` taller and the tile is lifted to make room.
    /// `year` shows on its own line while Year Under Titles is on (`year(for:)`).
    func set(_ text: String?, year: Int? = nil) {
        label.text = text
        label.isHidden = (text ?? "").isEmpty
        let shownYear = carriesYear && MediaRowMetrics.showsPosterYears ? year : nil
        yearLabel.text = shownYear.map(String.init)
        yearLabel.isHidden = label.isHidden || shownYear == nil
        let height = carriesYear ? MediaRowMetrics.posterCaptionHeight : MediaRowMetrics.posterTitleLineHeight
        tileCenterY.constant = text == nil ? 0 : -height / 2
    }

    func setFocused(_ focused: Bool) {
        label.textColor = UIColor.white.withAlphaComponent(focused ? 1 : 0.6)
        yearLabel.textColor = UIColor.white.withAlphaComponent(focused ? 0.7 : 0.4)
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

    /// The year line's value: a movie's or show's year; nil for episodes, seasons and the rest,
    /// whose line already names them.
    static func year(for item: MediaItem) -> Int? {
        item.kind == .movie || item.kind == .show ? item.year : nil
    }
}
