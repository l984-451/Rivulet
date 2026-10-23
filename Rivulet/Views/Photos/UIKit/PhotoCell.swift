// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PhotoCell.swift
//  Rivulet
//
//  A photo library tile: a square system poster lockup. Photos carry no
//  caption, clips a play badge, folders a title and an item count.
//

import UIKit
import TVUIKit

@MainActor
final class PhotoCell: UICollectionViewCell {
    static let reuseID = "PhotoCell"
    /// The Normal grid's square (see `PhotoGridViewController.columns`), not `MediaRowMetrics.music`.
    private static let tile = MediaRowMetrics.square(columns: DisplaySize.normal.posterColumns)

    /// The lockup frame; a folder adds the Music lockup's two-line footer under the art.
    static func size(for kind: PhotoItem.Kind) -> CGSize {
        var size = tile.frame
        if kind == .folder { size.height += MusicMetrics.lockupFooter - (tile.frame.height - tile.art.height) / 2 }
        return size
    }

    private let poster = TVPosterView()
    private let clipBadge = UIImageView(image: UIImage(systemName: "play.fill"))
    private var imageTask: Task<Void, Never>?
    private var imageURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        contentView.clipsToBounds = false

        // The poster sizes itself: the art plus the room it grows into on focus.
        poster.contentSize = Self.tile.art
        poster.imageView.contentMode = .scaleAspectFill
        poster.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(poster)

        clipBadge.tintColor = .white
        clipBadge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
        clipBadge.layer.shadowOpacity = 0.6
        clipBadge.layer.shadowRadius = 4
        clipBadge.layer.shadowOffset = .zero
        clipBadge.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(clipBadge)

        let inset = (Self.tile.frame.width - Self.tile.art.width) / 2 + 14
        NSLayoutConstraint.activate([
            poster.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            poster.topAnchor.constraint(equalTo: contentView.topAnchor),
            clipBadge.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset),
            clipBadge.topAnchor.constraint(equalTo: contentView.topAnchor,
                                           constant: Self.tile.frame.height - inset - 36)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: PhotoItem) {
        clipBadge.isHidden = item.kind != .clip
        poster.title = item.kind == .folder ? item.title : nil
        poster.subtitle = item.kind == .folder ? item.childCount.map { $0 == 1 ? "1 item" : "\($0) items" } : nil
        applyFocusAppearance(isFocused)
        guard item.thumbnail == nil || item.thumbnail != imageURL else { return }
        imageURL = item.thumbnail
        poster.image = MusicChrome.placeholder(item.kind == .folder ? "folder" : "photo", side: Self.tile.art.width)
        imageTask?.cancel()
        imageTask = MusicChrome.loadArtwork(item.thumbnail) { [weak self] image in
            if let image { self?.poster.image = image }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        imageTask = nil
        imageURL = nil
        poster.image = nil
        resetStaleFocusAppearance()
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({
            self.applyFocusAppearance(focused)
        }, completion: { [weak self] in
            if !focused { self?.resetStaleFocusAppearance() }
        })
    }

    /// The Music lockup's label colours: title white, count grey until focused.
    private func applyFocusAppearance(_ focused: Bool) {
        let footer = poster.footerView as? TVLockupHeaderFooterView
        footer?.titleLabel?.textColor = .white
        footer?.subtitleLabel?.textColor = focused ? .white : MusicMetrics.secondary
    }

    /// The poster can strand its enlarged look when focus leaves the whole
    /// collection: clear it directly (same reset as `MusicLockupCell`).
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
