// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicLockupCell.swift
//  Rivulet
//
//  The Music tile: 248pt art over two 25pt labels, left aligned under a square
//  and centred under a circle. Drawn here rather than a system `TVPosterView`
//  (1.125 focus scale) so focus grows the art 1.16 and drops the labels 20pt,
//  as Apple Music on tvOS 27.2.1 does.
//

import UIKit

@MainActor
final class MusicLockupCell: UICollectionViewCell {
    enum Shape { case square, circle }

    /// Cell size for a lockup with `lines` label lines under the art.
    static func size(lines: Int) -> CGSize {
        CGSize(width: MusicMetrics.lockupArt,
               height: MusicMetrics.lockupArt + (lines == 2 ? MusicMetrics.lockupLabels : 79))
    }

    /// Rows of lockups on the 40pt gap; the caller sets its own insets.
    static func gridSection(lines: Int) -> NSCollectionLayoutSection {
        let tile = size(lines: lines)
        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .absolute(tile.width), heightDimension: .absolute(tile.height)))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                               heightDimension: .absolute(tile.height)),
            subitems: [item])
        group.interItemSpacing = .fixed(MusicMetrics.lockupGap)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = MusicMetrics.lockupGap
        return section
    }

    /// Clears every visible lockup left looking focused (see `resetStaleFocusAppearance`).
    static func resetStaleFocus(in collectionView: UICollectionView) {
        for case let cell as MusicLockupCell in collectionView.visibleCells { cell.resetStaleFocusAppearance() }
    }

    private static let focusScale: CGFloat = 1.16
    private static let labelLine: CGFloat = 30
    private let artShadow = UIView()
    private let artView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private var shape: Shape = .square
    private var artworkTask: Task<Void, Never>?
    /// What is showing or loading, so a reconfigure with the same artwork leaves it alone.
    private var artworkURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        contentView.clipsToBounds = false
        let art = MusicMetrics.lockupArt

        artShadow.frame = CGRect(x: 0, y: 0, width: art, height: art)
        artShadow.layer.shadowColor = UIColor.black.cgColor
        artShadow.layer.shadowRadius = 24
        artShadow.layer.shadowOffset = CGSize(width: 0, height: 20)
        artShadow.layer.shadowOpacity = 0
        artView.frame = artShadow.bounds
        artView.contentMode = .scaleAspectFill
        artView.clipsToBounds = true
        artView.layer.cornerCurve = .continuous
        artShadow.addSubview(artView)
        contentView.addSubview(artShadow)

        // The title's baseline sits 35 under the art (cap top 11 into a 30pt line).
        titleLabel.frame = CGRect(x: 0, y: art + 11, width: art, height: Self.labelLine)
        subtitleLabel.frame = CGRect(x: 0, y: art + 11 + Self.labelLine, width: art, height: Self.labelLine)
        subtitleLabel.font = .systemFont(ofSize: 25)
        // Clipped with the system's edge fade at rest; the subtitle scrolls only while focused.
        titleLabel.enablesMarqueeWhenAncestorFocused = true
        [titleLabel, subtitleLabel].forEach(contentView.addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, subtitle: String?, artworkURL: URL?, shape: Shape) {
        self.shape = shape
        let art = MusicMetrics.lockupArt
        let radius: CGFloat = shape == .circle ? art / 2 : 20
        artView.layer.cornerRadius = radius
        artShadow.layer.shadowPath = UIBezierPath(roundedRect: artShadow.bounds, cornerRadius: radius).cgPath
        titleLabel.text = title
        titleLabel.textAlignment = shape == .circle ? .center : .left
        subtitleLabel.text = subtitle
        subtitleLabel.textAlignment = .left
        if artworkURL == nil || artworkURL != self.artworkURL {
            self.artworkURL = artworkURL
            artView.image = MusicChrome.placeholder(shape == .circle ? "music.microphone" : "music.note")
            artworkTask?.cancel()
            artworkTask = MusicChrome.loadArtwork(artworkURL) { [weak self] image in
                if let image { self?.artView.image = image }
            }
        }
        applyFocusAppearance(isFocused)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkTask?.cancel()
        artworkTask = nil
        artworkURL = nil
        artView.image = nil
        resetStaleFocusAppearance()
    }

    // MARK: - Focus

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self || context.nextFocusedView?.isDescendant(of: self) == true
        coordinator.addCoordinatedAnimations({ self.applyFocusAppearance(focused) }, completion: { [weak self] in
            guard let self, !focused else { return }
            self.resetStaleFocusAppearance()
        })
    }

    /// At rest the title reads 53% white and the artist 33%; focused, white and 62%.
    private func applyFocusAppearance(_ focused: Bool) {
        titleLabel.font = .systemFont(ofSize: 25, weight: focused ? .bold : .regular)
        titleLabel.textColor = UIColor(white: 1, alpha: focused ? 1 : 0.53)
        subtitleLabel.textColor = UIColor(white: 1, alpha: focused ? 0.62 : 0.33)
        // A marquee label can only clip: the subtitle scrolls while focused and ends in an
        // ellipsis at rest. Turning the marquee off does not restore the mode, hence the order.
        subtitleLabel.enablesMarqueeWhenAncestorFocused = focused
        if !focused { subtitleLabel.lineBreakMode = .byTruncatingTail }
        artShadow.transform = focused ? CGAffineTransform(scaleX: Self.focusScale, y: Self.focusScale) : .identity
        artShadow.layer.shadowOpacity = focused ? 0.35 : 0
        let drop = focused ? CGAffineTransform(translationX: 0, y: 20) : .identity
        titleLabel.transform = drop
        subtitleLabel.transform = drop
    }

    /// A tile can strand its enlarged look when focus leaves the whole collection:
    /// clear it directly (same reset as `PosterCell`).
    func resetStaleFocusAppearance() {
        guard !isFocused else { return }
        applyFocusAppearance(false)
    }
}
