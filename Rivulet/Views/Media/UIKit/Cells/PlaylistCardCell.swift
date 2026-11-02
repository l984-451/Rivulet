// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Playlists grid tile: 16:9 art in a
// `TVCardView`, a constant bottom scrim, the title always at the bottom leading corner.

import UIKit
import TVUIKit

@MainActor
final class PlaylistCardCell: UICollectionViewCell {
    static let reuseID = "PlaylistCardCell"

    private let card = TVCardView()
    private let artworkView = UIImageView()
    private let scrim = GradientView(.axial, from: CGPoint(x: 0.5, y: 0), to: CGPoint(x: 0.5, y: 1),
                                     alphas: [0, 0.65], locations: nil)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private var loadTask: Task<Void, Never>?
    private var currentURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.clipsToBounds = false
        clipsToBounds = false

        let tile = MediaRowMetrics.playlist
        card.translatesAutoresizingMaskIntoConstraints = false
        card.contentSize = tile.frame
        contentView.addSubview(card)

        let content = card.contentView
        content.backgroundColor = UIColor(white: 1, alpha: 0.1)
        content.clipsToBounds = true
        content.layer.cornerRadius = 20
        content.layer.cornerCurve = .continuous

        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true

        titleLabel.font = .systemFont(ofSize: 32, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        subtitleLabel.font = .systemFont(ofSize: 24, weight: .medium)
        subtitleLabel.textColor = UIColor(white: 1, alpha: 0.7)
        subtitleLabel.text = String(localized: "Smart Playlist")

        let text = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        text.axis = .vertical
        text.spacing = 4
        for view in [artworkView, scrim, text] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            card.widthAnchor.constraint(equalToConstant: tile.frame.width),
            card.heightAnchor.constraint(equalToConstant: tile.frame.height),

            artworkView.topAnchor.constraint(equalTo: content.topAnchor),
            artworkView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            artworkView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            artworkView.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scrim.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scrim.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrim.heightAnchor.constraint(equalTo: content.heightAnchor, multiplier: 0.45),

            // 999: TVCardView lays its content out at zero width first.
            text.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30).withPriority(999),
            text.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -30).withPriority(999),
            text.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(item: MediaItem, isSmart: Bool) {
        titleLabel.text = item.title
        subtitleLabel.isHidden = !isSmart
        loadArtwork(item.artwork.backdrop ?? item.artwork.poster)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        currentURL = nil
        artworkView.image = nil
        titleLabel.text = nil
    }

    private func loadArtwork(_ url: URL?) {
        guard url != currentURL || artworkView.image == nil else { return }
        loadTask?.cancel()
        currentURL = url
        artworkView.image = nil
        guard let url else { return }
        if let cached = ImageCacheManager.shared.cachedImage(for: url) {
            artworkView.image = cached
            return
        }
        loadTask = Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url)
            guard let self, self.currentURL == url else { return }
            self.artworkView.image = image
        }
    }
}
