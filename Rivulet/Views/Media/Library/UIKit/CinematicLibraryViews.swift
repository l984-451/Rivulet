// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit

/// Shared measurements for the artwork/list composition, in the collection's coordinate space.
enum CinematicStyle {
    static let background = UIColor(white: 0.055, alpha: 1)
    static let secondaryText = UIColor(white: 0.76, alpha: 1)
    static let rowHeight: CGFloat = 112
    static func listLeading(in width: CGFloat) -> CGFloat { width * 0.46 }
    static func displayFont(size: CGFloat) -> UIFont {
        UIFont(name: "AvenirNext-UltraLight", size: size) ?? .systemFont(ofSize: size, weight: .light)
    }

    static func metadata(for item: MediaItem) -> String {
        [item.year.map(String.init), item.contentRating, item.editionTitle]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }
}

/// A native focusable row. The library's existing delegate owns selection, long press and paging.
final class CinematicLibraryCell: UICollectionViewCell {
    static let reuseID = "library.cinematicRow"
    private let titleLabel = UILabel()
    private let metadataLabel = UILabel()
    private let durationLabel = UILabel()
    private let watchedImage = UIImageView()
    private let separator = UIView()
    private let materialBackground = UIVisualEffectView(effect: UIGlassEffect(style: .regular))

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = Self.reuseID
        isAccessibilityElement = true
        contentView.layer.cornerRadius = 20
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        materialBackground.isUserInteractionEnabled = false
        materialBackground.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        materialBackground.frame = contentView.bounds
        contentView.addSubview(materialBackground)
        titleLabel.font = .systemFont(ofSize: 29, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        metadataLabel.font = .systemFont(ofSize: 21)
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 23, weight: .medium)
        durationLabel.textAlignment = .right
        durationLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        watchedImage.contentMode = .scaleAspectFit
        watchedImage.image = UIImage(systemName: "checkmark.circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24))
        for child in [titleLabel, metadataLabel, durationLabel, watchedImage, separator] {
            child.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(child)
        }
        NSLayoutConstraint.activate([
            watchedImage.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            watchedImage.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            watchedImage.widthAnchor.constraint(equalToConstant: 28),
            watchedImage.heightAnchor.constraint(equalToConstant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: watchedImage.trailingAnchor, constant: 22),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 23),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: durationLabel.leadingAnchor, constant: -24),
            metadataLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metadataLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
            metadataLabel.trailingAnchor.constraint(lessThanOrEqualTo: durationLabel.leadingAnchor, constant: -24),
            durationLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            durationLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1)
        ])
        applyFocus(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(item: MediaItem) {
        titleLabel.text = item.isGridPlaceholder ? String(localized: "Loading…") : item.title
        metadataLabel.text = item.isGridPlaceholder ? nil : CinematicStyle.metadata(for: item)
        durationLabel.text = item.runtime.flatMap { seconds in
            seconds > 0 ? String(localized: "\(Int(seconds / 60)) min") : nil
        }
        watchedImage.alpha = item.userState.isPlayed ? 1 : 0
        accessibilityLabel = [titleLabel.text, metadataLabel.text, durationLabel.text]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        accessibilityValue = item.userState.isPlayed ? String(localized: "Watched") : nil
        applyFocus(isFocused)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        titleLabel.text = nil
        metadataLabel.text = nil
        durationLabel.text = nil
        accessibilityLabel = nil
        accessibilityValue = nil
        watchedImage.alpha = 0
        applyFocus(false)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations { self.applyFocus(focused) }
    }

    private func applyFocus(_ focused: Bool) {
        contentView.backgroundColor = focused ? .white : UIColor.white.withAlphaComponent(0.06)
        materialBackground.alpha = focused ? 0 : 1
        titleLabel.textColor = focused ? .black : .white
        metadataLabel.textColor = focused ? UIColor(white: 0.27, alpha: 1) : CinematicStyle.secondaryText
        durationLabel.textColor = metadataLabel.textColor
        watchedImage.tintColor = titleLabel.textColor
        separator.backgroundColor = focused ? .clear : UIColor.white.withAlphaComponent(0.1)
    }
}

/// A fixed artwork panel beside the scrolling list. It never enters the focus graph.
/// Each selection cancels its predecessor, including the settling delay, so fast scrolling cannot
/// paint stale artwork or start an image request for every title passed on the way.
final class CinematicLibraryArtworkView: UIView {
    private let artworkView = UIImageView()
    private let placeholder = UIImageView(image: UIImage(systemName: "film"))
    private let titleLabel = UILabel()
    private let metadataLabel = UILabel()
    private let overviewLabel = UILabel()
    private let ambientView = AmbientBackdropView()
    private let divider = UIView()
    private var loadTask: Task<Void, Never>?
    private var currentURL: URL?
    private(set) var displayedItem: MediaItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true // The selected row already announces the title.
        backgroundColor = CinematicStyle.background
        artworkView.contentMode = .scaleAspectFit
        artworkView.clipsToBounds = true
        placeholder.tintColor = UIColor.white.withAlphaComponent(0.12)
        placeholder.contentMode = .scaleAspectFit
        ambientView.usesHeroEdgeColors = true
        ambientView.alpha = 0.35
        addSubview(ambientView)
        addSubview(placeholder)
        addSubview(artworkView)
        titleLabel.font = CinematicStyle.displayFont(size: 46)
        titleLabel.numberOfLines = 3
        titleLabel.textColor = .white
        metadataLabel.font = .systemFont(ofSize: 22, weight: .medium)
        metadataLabel.textColor = CinematicStyle.secondaryText
        metadataLabel.numberOfLines = 2
        overviewLabel.font = .systemFont(ofSize: 23)
        overviewLabel.numberOfLines = 3
        overviewLabel.textColor = CinematicStyle.secondaryText
        divider.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        for child in [titleLabel, metadataLabel, overviewLabel, divider] { addSubview(child) }
        NotificationCenter.default.addObserver(self, selector: #selector(descriptionChanged),
                                              name: .cinematicDescriptionDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { loadTask?.cancel() }

    @objc private func descriptionChanged() { setNeedsLayout() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let panelWidth = CinematicStyle.listLeading(in: bounds.width) - 42
        let margin: CGFloat = 72
        let textWidth = max(0, panelWidth - 2 * margin)
        ambientView.frame = bounds
        let showDescription = AppTheme.showsLibraryDescription && !(overviewLabel.text ?? "").isEmpty
        overviewLabel.isHidden = !showDescription
        divider.isHidden = !showDescription
        let overviewHeight = overviewLabel.sizeThatFits(CGSize(width: textWidth, height: 110)).height
        overviewLabel.frame = CGRect(x: margin, y: bounds.height - 72 - overviewHeight, width: textWidth, height: overviewHeight)
        divider.frame = CGRect(x: margin, y: overviewLabel.frame.minY - 26, width: textWidth, height: 1)
        let metadataHeight = metadataLabel.sizeThatFits(CGSize(width: textWidth, height: 64)).height
        let metadataBottom = showDescription ? divider.frame.minY - 24 : bounds.height - 72
        metadataLabel.frame = CGRect(x: margin, y: metadataBottom - metadataHeight, width: textWidth, height: metadataHeight)
        let titleHeight = titleLabel.sizeThatFits(CGSize(width: textWidth, height: 190)).height
        titleLabel.frame = CGRect(x: margin, y: metadataLabel.frame.minY - 16 - titleHeight, width: textWidth, height: titleHeight)

        // Reserve space for the text, then fit the entire image above it.
        // No scrim, mask or text is allowed to cover the artwork itself.
        let available = CGRect(x: 32, y: 24, width: max(0, panelWidth - 64),
                               height: max(0, titleLabel.frame.minY - 48))
        let imageSize = artworkView.image?.size ?? CGSize(width: 2, height: 3)
        let scale = min(available.width / max(1, imageSize.width), available.height / max(1, imageSize.height))
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        artworkView.frame = CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                                   width: size.width, height: size.height)
        placeholder.frame = CGRect(x: available.midX - 64, y: available.midY - 64, width: 128, height: 128)
    }

    func configure(item: MediaItem?) {
        guard item != displayedItem else { return }
        displayedItem = item
        titleLabel.text = item?.title
        metadataLabel.text = item.map { CinematicStyle.metadata(for: $0) }
        overviewLabel.text = item?.overview
        setNeedsLayout()
        let url = item?.artwork.poster ?? item?.artwork.backdrop ?? item?.artwork.thumbnail
        guard currentURL != url else { return }
        currentURL = url
        loadTask?.cancel()
        artworkView.layer.removeAllAnimations()
        artworkView.alpha = 1
        artworkView.image = nil
        ambientView.isHidden = url == nil
        guard let url else { return }
        if let cached = ImageCacheManager.shared.cachedImage(for: url, quality: .full) {
            ambientView.setAmbient(url: url)
            artworkView.image = cached
            setNeedsLayout()
            return
        }
        loadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.ambientView.setAmbient(url: url)
            let image = await ImageCacheManager.shared.image(for: url, quality: .full)
            guard !Task.isCancelled, let self, self.currentURL == url else { return }
            self.artworkView.image = image
            self.setNeedsLayout()
            guard image != nil, !UIAccessibility.isReduceMotionEnabled else { return }
            self.artworkView.alpha = 0
            UIView.animate(withDuration: 0.25) { self.artworkView.alpha = 1 }
        }
    }
}
