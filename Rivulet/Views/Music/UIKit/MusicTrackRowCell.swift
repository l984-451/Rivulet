// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicTrackRowCell.swift
//  Rivulet
//
//  One track row in two grammars: numbered (album, pitch 90) and thumbnail
//  (playlist and songs, pitch 110). No dividers and no rest background; the
//  focused row sits on a glass platter that outsets the column by 28pt.
//

import UIKit

@MainActor
final class MusicTrackRowCell: UICollectionViewCell {
    enum Style {
        case numbered, thumbnail
        var height: CGFloat { self == .numbered ? 90 : 110 }
    }

    /// How far the focus platter reaches past the column on each side.
    static let platterOutset: CGFloat = 28

    private let platter = MusicFocusPlatterView()
    private let thumb = UIImageView()
    private let thumbDim = UIView()
    private let number = MusicChrome.label(size: 29, weight: .regular)
    private let bars = MusicPlaybackBarsView()
    private let star = UIImageView(image: UIImage(
        systemName: "star.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)))
    private let title = MusicChrome.label(size: 31, weight: .medium)
    private let artist = MusicChrome.label(size: 29, weight: .regular)
    private let duration = MusicChrome.label(size: 29, weight: .regular)

    private var style: Style = .numbered
    private var isCurrent = false
    private var showsFocus = false
    private var artworkTask: Task<Void, Never>?
    /// What is showing or loading, so a reconfigure with the same artwork leaves it alone.
    private var artworkURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        contentView.clipsToBounds = false
        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        thumb.layer.cornerCurve = .continuous
        thumbDim.backgroundColor = UIColor(white: 0, alpha: 0.45)
        thumb.addSubview(thumbDim)
        number.textAlignment = .center
        star.tintColor = MusicMetrics.tertiary
        star.contentMode = .center
        duration.textAlignment = .right
        [platter, thumb, number, star, title, artist, duration, bars].forEach(contentView.addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `number` is nil in the thumbnail grammar. `artist` is nil when it would
    /// only repeat the album's artist.
    func configure(track: MusicTrack, style: Style, number: Int?, artist: String?,
                   isCurrent: Bool, isPlaying: Bool, isFavorite: Bool, loadsArtwork: Bool = true) {
        self.style = style
        self.isCurrent = isCurrent
        title.text = track.title
        self.artist.text = artist
        self.artist.isHidden = artist == nil
        duration.text = track.duration > 0 ? MusicChrome.clock(track.duration) : nil
        self.number.text = number.map(String.init)
        self.number.isHidden = style == .thumbnail || isCurrent
        star.isHidden = !isFavorite
        bars.isHidden = !isCurrent
        bars.isPlaying = isCurrent && isPlaying
        thumb.isHidden = style == .numbered
        thumbDim.isHidden = !isCurrent
        let url = loadsArtwork ? track.artwork.thumbnail ?? track.artwork.poster : nil
        if style == .thumbnail, url == nil || url != artworkURL {
            artworkURL = url
            thumb.image = MusicChrome.placeholder(side: 98)
            artworkTask?.cancel()
            artworkTask = MusicChrome.loadArtwork(url) { [weak self] image in
                if let image { self?.thumb.image = image }
            }
        }
        applyColors()
        setNeedsLayout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkTask?.cancel()
        artworkTask = nil
        artworkURL = nil
        thumb.image = nil
        showsFocus = false
        platter.alpha = 0
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        let outset = Self.platterOutset
        let platterHeight = bounds.height - (style == .numbered ? 8 : 16)
        platter.frame = CGRect(x: -outset, y: (bounds.height - platterHeight) / 2,
                               width: bounds.width + outset * 2, height: platterHeight)

        var textX: CGFloat = 72
        if style == .thumbnail {
            // Focused, the thumbnail fills the platter's left end (tvOS 27 capture).
            thumb.frame = showsFocus
                ? CGRect(x: -outset, y: platter.frame.minY, width: platterHeight, height: platterHeight)
                : CGRect(x: 0, y: (bounds.height - 90) / 2, width: 90, height: 90)
            thumb.layer.cornerRadius = showsFocus ? MusicFocusPlatterView.cornerRadius : 8
            thumb.layer.maskedCorners = showsFocus
                ? [.layerMinXMinYCorner, .layerMinXMaxYCorner]
                : [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            thumbDim.frame = thumb.bounds
            textX = thumb.frame.maxX + 24
            bars.center = thumb.center
        } else {
            number.frame = CGRect(x: 8, y: 0, width: 60, height: bounds.height)
            bars.center = number.center
        }
        bars.bounds.size = bars.intrinsicContentSize
        star.frame = CGRect(x: -32, y: 0, width: 24, height: bounds.height)
        star.alpha = style == .thumbnail && showsFocus ? 0 : 1

        duration.sizeToFit()
        let durationRight = bounds.width + (style == .thumbnail && showsFocus ? 5 : 0)
        duration.frame = CGRect(x: durationRight - duration.bounds.width, y: 0,
                                width: duration.bounds.width, height: bounds.height)

        let textWidth = duration.frame.minX - 24 - textX
        let titleHeight = ceil(title.font.lineHeight)
        if artist.isHidden {
            title.frame = CGRect(x: textX, y: (bounds.height - titleHeight) / 2, width: textWidth, height: titleHeight)
        } else {
            let artistHeight = ceil(artist.font.lineHeight)
            let top = (bounds.height - titleHeight - artistHeight) / 2
            title.frame = CGRect(x: textX, y: top, width: textWidth, height: titleHeight)
            artist.frame = CGRect(x: textX, y: top + titleHeight, width: textWidth, height: artistHeight)
        }
    }

    // MARK: - Focus

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.animateFocusChange(gained: focused) {
            self.showsFocus = focused
            self.platter.alpha = focused ? 1 : 0
            self.applyColors()
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
    }

    /// At rest an album row's title measures 57% white (tvOS 27.2.1), a playlist's 64% and the
    /// rest 38%. A focused row is white, its title semibold.
    private func applyColors() {
        let numbered = style == .numbered
        title.font = .systemFont(ofSize: 31, weight: numbered || showsFocus ? .semibold : .medium)
        title.textColor = UIColor(white: 1, alpha: showsFocus ? 1 : (numbered ? 0.57 : 0.64))
        artist.textColor = UIColor(white: 1, alpha: showsFocus ? 1 : 0.38)
        duration.textColor = UIColor(white: 1, alpha: showsFocus ? 1 : (numbered ? 0.35 : 0.38))
        number.textColor = UIColor(white: 1, alpha: showsFocus ? 1 : 0.55)
    }
}
