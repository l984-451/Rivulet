// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PhotoMemoryCell.swift
//  Rivulet
//
//  A memories row card: the cover photo filled, a bottom scrim, the title at
//  the bottom leading corner (the Playlists card's style, on the large tile).
//

import UIKit
import TVUIKit

@MainActor
final class PhotoMemoryCell: UICollectionViewCell {
    static let reuseID = "PhotoMemoryCell"
    static let tile = MediaRowMetrics.feature

    private let card = TVCardView()
    private let artworkView = UIImageView()
    private let scrim = GradientView(.axial, from: CGPoint(x: 0.5, y: 0), to: CGPoint(x: 0.5, y: 1),
                                     alphas: [0, 0.65], locations: nil)
    private let titleLabel = UILabel()
    private var loadTask: Task<Void, Never>?
    private var cover: PhotoItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.clipsToBounds = false
        clipsToBounds = false

        card.translatesAutoresizingMaskIntoConstraints = false
        card.contentSize = Self.tile.frame
        contentView.addSubview(card)

        let content = card.contentView
        content.backgroundColor = UIColor(white: 1, alpha: 0.1)
        content.clipsToBounds = true
        content.layer.cornerRadius = 20
        content.layer.cornerCurve = .continuous

        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        titleLabel.font = .systemFont(ofSize: 38, weight: .bold)
        titleLabel.textColor = .white
        for view in [artworkView, scrim, titleLabel] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            card.widthAnchor.constraint(equalToConstant: Self.tile.frame.width),
            card.heightAnchor.constraint(equalToConstant: Self.tile.frame.height),

            artworkView.topAnchor.constraint(equalTo: content.topAnchor),
            artworkView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            artworkView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            artworkView.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scrim.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scrim.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrim.heightAnchor.constraint(equalTo: content.heightAnchor, multiplier: 0.45),

            // 999: TVCardView lays its content out at zero width first.
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 36).withPriority(999),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -36)
                .withPriority(999),
            titleLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -32)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ memory: PhotoMemory) {
        titleLabel.text = memory.title
        guard memory.cover?.ref != cover?.ref || artworkView.image == nil else { return }
        cover = memory.cover
        loadTask?.cancel()
        artworkView.image = memory.cover?.thumbnail.flatMap { ImageCacheManager.shared.cachedImage(for: $0) }
        guard let cover = memory.cover else {
            artworkView.image = MusicChrome.placeholder("map", side: MediaRowMetrics.feature.art.height)
            return
        }
        // The 520 px thumbnail first, then the full photo decoded to the card's size.
        loadTask = Task { [weak self] in
            for url in [cover.thumbnail, cover.full].compactMap({ $0 }) {
                let image = await ImageCacheManager.shared.image(for: url)
                guard !Task.isCancelled else { return }
                if let image { self?.artworkView.image = image }
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        cover = nil
        artworkView.image = nil
    }
}
