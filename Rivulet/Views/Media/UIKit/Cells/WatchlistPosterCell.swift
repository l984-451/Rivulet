// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Poster tile for the Watchlist hub row: 20pt continuous mask, `TVPosterView` focus motion,
// and a film/tv symbol placeholder when there is no poster. Caption stays nil, as in `PosterCell`.

import UIKit
import TVUIKit

@MainActor
final class WatchlistPosterCell: UICollectionViewCell {
    static let reuseID = "WatchlistPosterCell"

    private let posterView = TVPosterView()
    /// Overlay clipped to the same rounded rect — shows the placeholder
    /// gradient + icon when there is no poster URL or the load fails.
    private let placeholderView = UIView()
    private let placeholderGradient = CAGradientLayer()
    private let placeholderIcon = UIImageView()

    private var imageLoadTask: Task<Void, Never>?
    private var currentURL: URL?
    /// True once real artwork is showing; `posterView.image` is never nil.
    private var hasArtwork = false

    private let cornerRadius: CGFloat = 20
    /// Re-read from `MediaRowMetrics` on every configure, so a reused cell follows a Display Size change.
    private var tile = MediaRowMetrics.poster
    private var posterWidthConstraint: NSLayoutConstraint!
    private var posterHeightConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        contentView.clipsToBounds = false
        clipsToBounds = false

        // No resting drop shadow, matching the Apple TV app.

        posterView.translatesAutoresizingMaskIntoConstraints = false
        posterView.image = PosterCell.blankArtwork
        contentView.addSubview(posterView)

        // Placeholder underlay (dark gradient + centred SF symbol). Visible
        // when posterURL is nil or the load fails. Sits behind the poster
        // image so the image hides it once loaded.
        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        placeholderView.clipsToBounds = true
        placeholderView.layer.cornerRadius = cornerRadius
        placeholderView.layer.cornerCurve = .continuous
        placeholderGradient.colors = [
            UIColor(white: 0.18, alpha: 1.0).cgColor,
            UIColor(white: 0.12, alpha: 1.0).cgColor
        ]
        placeholderGradient.startPoint = CGPoint(x: 0.5, y: 0)
        placeholderGradient.endPoint = CGPoint(x: 0.5, y: 1)
        placeholderView.layer.addSublayer(placeholderGradient)

        placeholderIcon.translatesAutoresizingMaskIntoConstraints = false
        placeholderIcon.contentMode = .scaleAspectFit
        placeholderIcon.tintColor = UIColor.white.withAlphaComponent(0.3)
        placeholderView.addSubview(placeholderIcon)

        // Insert placeholder below the poster view so the image covers it.
        contentView.insertSubview(placeholderView, belowSubview: posterView)

        posterWidthConstraint = posterView.widthAnchor.constraint(equalToConstant: tile.hostSize.width)
        posterHeightConstraint = posterView.heightAnchor.constraint(equalToConstant: tile.hostSize.height)
        NSLayoutConstraint.activate([
            posterView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            posterView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            posterWidthConstraint,
            posterHeightConstraint,

            placeholderView.topAnchor.constraint(equalTo: posterView.imageView.topAnchor),
            placeholderView.bottomAnchor.constraint(equalTo: posterView.imageView.bottomAnchor),
            placeholderView.leadingAnchor.constraint(equalTo: posterView.imageView.leadingAnchor),
            placeholderView.trailingAnchor.constraint(equalTo: posterView.imageView.trailingAnchor),

            placeholderIcon.centerXAnchor.constraint(equalTo: placeholderView.centerXAnchor),
            placeholderIcon.centerYAnchor.constraint(equalTo: placeholderView.centerYAnchor),
            placeholderIcon.widthAnchor.constraint(equalToConstant: 32),
            placeholderIcon.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    /// Trims TVUIKit's focus growth to the tile's.
    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let nowFocused = context.nextFocusedView === self
                      || context.nextFocusedView?.isDescendant(of: self) == true
        coordinator.addCoordinatedAnimations({
            self.posterView.transform = nowFocused ? self.tile.focusScale : .identity
        }, completion: nil)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Keep the gradient sized to the placeholder bounds (no implicit
        // animation so it doesn't interpolate the frame on every layout
        // pass when the cell is recycled).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeholderGradient.frame = placeholderView.bounds
        CATransaction.commit()
    }

    func configure(item: PlexWatchlistItem) {
        applyPosterSize()
        // `film` for movies, `tv` for shows.
        let iconName = item.type == .movie ? "film" : "tv"
        let icon = UIImage(systemName: iconName)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 32, weight: .light))
        loadImage(from: item.posterURL, failureIcon: icon)
    }

    /// MediaItem path. Artwork URLs are already resolved — no serverURL/token needed.
    func configure(item: MediaItem) {
        applyPosterSize()
        loadImage(from: item.artwork.poster, failureIcon: failureIconImage(for: item.kind))
    }

    private func applyPosterSize() {
        tile = MediaRowMetrics.poster
        let host = tile.hostSize
        if posterWidthConstraint.constant != host.width { posterWidthConstraint.constant = host.width }
        if posterHeightConstraint.constant != host.height { posterHeightConstraint.constant = host.height }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageLoadTask?.cancel()
        imageLoadTask = nil
        currentURL = nil
        clearArtwork()
        placeholderView.isHidden = false
        placeholderIcon.image = nil
    }

    private func loadImage(from url: URL?, failureIcon: UIImage?) {
        imageLoadTask?.cancel()
        // Update the placeholder icon regardless of whether we have a URL.
        placeholderIcon.image = failureIcon
        guard let url else {
            clearArtwork()
            currentURL = nil
            // No URL: show placeholder (no fade-out animation needed).
            placeholderView.isHidden = false
            return
        }
        if currentURL == url, hasArtwork {
            placeholderView.isHidden = true
            return
        }
        currentURL = url
        // Memory hit paints in this pass, so a tile realized for the carousel
        // exit has artwork to fly to.
        if let cached = ImageCacheManager.shared.cachedImage(for: url) {
            posterView.image = cached
            hasArtwork = true
            placeholderView.isHidden = true
            return
        }
        placeholderView.isHidden = false  // visible while loading
        let key = url.absoluteString as AnyHashable
        imageLoadTask = Task { [weak self] in
            let image: UIImage? = await Perf.interval(.imageDecode, key: key) {
                await ImageCacheManager.shared.image(for: url)
            }
            await MainActor.run {
                guard let self, self.currentURL == url else { return }
                if let image {
                    self.posterView.image = image
                    self.hasArtwork = true
                    self.placeholderView.isHidden = true
                } else {
                    // Load failed: keep placeholder visible.
                    self.placeholderView.isHidden = false
                }
            }
        }
    }

    private func clearArtwork() {
        posterView.image = PosterCell.blankArtwork
        hasArtwork = false
    }

    /// MediaItem failure icon -- maps MediaKind to a system image name.
    private func failureIconImage(for kind: MediaKind) -> UIImage? {
        let name: String
        switch kind {
        case .movie:      name = "film"
        case .show:       name = "tv"
        case .season:     name = "number.square"
        case .episode:    name = "play.rectangle"
        case .person:     name = "person"
        default:          name = "photo"
        }
        return UIImage(systemName: name)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 32, weight: .light))
    }
}

extension WatchlistPosterCell: PreviewSourceTile {
    var previewArtworkView: UIView { posterView.imageView }
    var previewCornerRadius: CGFloat { cornerRadius }
    var previewArtworkLoaded: Bool { hasArtwork }
}
