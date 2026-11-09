// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicLockupCell.swift
//  Rivulet
//
//  The Music tile: 320pt art over centred callout labels. Squares are a
//  system `TVPosterView` (1.125 focus scale, labels drop 20pt).
//  Circles are drawn here, because `TVMonogramView` paints a square glass
//  platter behind the focused circle on tvOS 26.
//

import UIKit
import TVUIKit

@MainActor
final class MusicLockupCell: UICollectionViewCell {
    enum Shape { case square, circle }

    /// Cell size for a lockup with `lines` label lines under the art.
    static func size(lines: Int) -> CGSize {
        CGSize(width: MusicMetrics.lockupArt,
               height: MusicMetrics.lockupArt + (lines == 2 ? MusicMetrics.lockupFooter : 53))
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

    private static let labelDrop: CGFloat = 8
    private let poster = TVPosterView()
    private let circleArt = UIImageView()
    private let circleShadow = UIView()
    private let circleTitle = UILabel()
    private var shape: Shape = .square
    private var artworkTask: Task<Void, Never>?
    /// What is showing or loading, so a reconfigure with the same artwork leaves it alone.
    private var artworkURL: URL?

    private var footer: TVLockupHeaderFooterView? { poster.footerView }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        contentView.clipsToBounds = false
        let art = MusicMetrics.lockupArt

        // The poster view reserves 20pt a side for its focus growth and sizes
        // itself, so it is hung 20pt outside the cell and the art fills the cell.
        poster.contentSize = CGSize(width: art, height: art)
        // Apple's title baseline sits 38pt under the art; the stock footer sets it at 30.
        // A negative bottom inset is what pushes the footer away from the art.
        poster.contentViewInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: -Self.labelDrop, trailing: 0)
        poster.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(poster)
        NSLayoutConstraint.activate([
            poster.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            poster.topAnchor.constraint(equalTo: contentView.topAnchor, constant: -20),
        ])

        circleShadow.frame = CGRect(x: 0, y: 0, width: art, height: art)
        circleShadow.layer.shadowColor = UIColor.black.cgColor
        circleShadow.layer.shadowRadius = 24
        circleShadow.layer.shadowOffset = CGSize(width: 0, height: 20)
        circleShadow.layer.shadowOpacity = 0
        circleShadow.layer.shadowPath = UIBezierPath(ovalIn: circleShadow.bounds).cgPath
        circleArt.frame = circleShadow.bounds
        circleArt.contentMode = .scaleAspectFill
        circleArt.clipsToBounds = true
        circleArt.layer.cornerRadius = art / 2
        circleShadow.addSubview(circleArt)
        contentView.addSubview(circleShadow)

        circleTitle.frame = CGRect(x: 0, y: art + Self.labelDrop, width: art, height: 38)
        circleTitle.font = .preferredFont(forTextStyle: .callout)
        circleTitle.textColor = .white
        circleTitle.textAlignment = .center
        // Clipped with the system's edge fade at rest, as the square tile's title is.
        circleTitle.enablesMarqueeWhenAncestorFocused = true
        contentView.addSubview(circleTitle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, subtitle: String?, artworkURL: URL?, shape: Shape) {
        self.shape = shape
        poster.isHidden = shape == .circle
        circleShadow.isHidden = shape == .square
        circleTitle.isHidden = shape == .square
        poster.title = title
        poster.subtitle = subtitle
        // A hidden label must not run a marquee.
        circleTitle.text = shape == .circle ? title : nil
        if artworkURL == nil || artworkURL != self.artworkURL {
            self.artworkURL = artworkURL
            setArt(MusicChrome.placeholder(shape == .circle ? "music.microphone" : "music.note"))
            artworkTask?.cancel()
            artworkTask = MusicChrome.loadArtwork(artworkURL) { [weak self] image in
                if let image { self?.setArt(image) }
            }
        }
        applyFocusAppearance(isFocused)
    }

    private func setArt(_ image: UIImage) {
        if shape == .square { poster.image = image } else { circleArt.image = image }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkTask?.cancel()
        artworkTask = nil
        artworkURL = nil
        poster.image = nil
        circleArt.image = nil
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

    /// Apple's tile: title white and bold on focus, subtitle grey at rest and
    /// white on focus. The circle also takes the poster's scale and label drop.
    private func applyFocusAppearance(_ focused: Bool) {
        let callout = UIFont.preferredFont(forTextStyle: .callout)
        let title = focused ? UIFont.systemFont(ofSize: callout.pointSize, weight: .bold) : callout
        footer?.titleLabel?.font = title
        footer?.titleLabel?.textColor = .white
        footer?.subtitleLabel?.textColor = focused ? .white : MusicMetrics.secondary
        // A marquee label can only clip: the subtitle scrolls while focused and ends in an
        // ellipsis at rest. Turning the marquee off does not restore the mode, hence the order.
        footer?.subtitleLabel?.enablesMarqueeWhenAncestorFocused = focused
        if !focused { footer?.subtitleLabel?.lineBreakMode = .byTruncatingTail }
        circleTitle.font = title
        guard shape == .circle else { return }
        circleShadow.transform = focused ? CGAffineTransform(scaleX: 1.125, y: 1.125) : .identity
        circleShadow.layer.shadowOpacity = focused ? 0.35 : 0
        circleTitle.transform = focused ? CGAffineTransform(translationX: 0, y: 20) : .identity
    }

    /// `TVPosterView` can strand its enlarged look when focus leaves the whole
    /// collection: clear it directly (same reset as `PosterCell`).
    func resetStaleFocusAppearance() {
        guard !isFocused else { return }
        func clear(_ view: UIView) {
            if !view.transform.isIdentity { view.transform = .identity }
            if !CATransform3DIsIdentity(view.layer.transform) { view.layer.transform = CATransform3DIdentity }
            view.motionEffects.forEach { view.removeMotionEffect($0) }
            view.subviews.forEach(clear)
        }
        clear(poster)
        applyFocusAppearance(false)
    }
}
