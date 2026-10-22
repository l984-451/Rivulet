// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ContinueWatchingCell.swift
//  Rivulet
//
//  Continue Watching tile, a clone of the Apple TV app's Up Next card,
//  sized by MediaRowMetrics:
//
//    one bitmap from `ContinueWatchingCardCompositor`: the 16:9 still, then
//      its mirrored, blurred continuation in the bottom 48pt
//    title logo on the edge and at the height the still's analysis picks
//      (`ContinueWatchingCardPlacement`; text fallback)
//    status row 14pt from the bottom-left (play glyph + progress + "S1, E2 · 35m")
//
//  Wrapped in `TVCardView` for native tvOS focus motion (parallax, glow).
//

import UIKit
import TVUIKit

@MainActor
final class ContinueWatchingCell: UICollectionViewCell {
    static let reuseID = "ContinueWatchingCell"

    private let card = TVCardView()
    private let artworkImageView = UIImageView()
    private let placeholderView = UIView()
    private let placeholderIcon = UIImageView()
    private let titleLogoView = ContinueWatchingTitleLogoView()
    private let infoBar = MediaProgressInfoBar()

    private var artworkLoadTask: Task<Void, Never>?
    private var currentArtworkURL: URL?

    // TVCardView resets its platter to the system radius on every focus change, and a larger clip shows
    // the platter past the corners (#343). That radius is 20pt on tvOS 27 and 12pt on tvOS 26: read off
    // the platter on an Apple TV 4K 1st gen (tvOS 26.6), 13.76pt at the focused card's 1.1465 scale,
    // where the 20pt clip left its near-white fill showing in every corner.
    private let cornerRadius: CGFloat = {
        if #available(tvOS 27, *) { return 20 }
        return 12
    }()

    fileprivate static let geometry = ContinueWatchingCardCompositor.Geometry(
        cardWidth: MediaRowMetrics.continueWatching.art.width)

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        contentView.clipsToBounds = false
        clipsToBounds = false

        // TVCardView provides Apple's tvOS focus motion (parallax + glow).
        card.translatesAutoresizingMaskIntoConstraints = false
        card.contentSize = CGSize(width: MediaRowMetrics.cwWidth, height: MediaRowMetrics.cwHeight)
        contentView.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            card.widthAnchor.constraint(equalToConstant: MediaRowMetrics.cwWidth),
            card.heightAnchor.constraint(equalToConstant: MediaRowMetrics.cwHeight)
        ])

        // No resting drop shadow (ATV+ reference: cards float clean over the
        // page background; see Docs/atv_ref/below_home_hero_ref.md).

        // Placeholder underlay, visible until the artwork resolves.
        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        placeholderView.backgroundColor = UIColor(white: 1, alpha: 0.1)
        card.contentView.addSubview(placeholderView)

        // Placeholder for empty and failed loads; the icon shows only on failure.
        placeholderIcon.translatesAutoresizingMaskIntoConstraints = false
        placeholderIcon.contentMode = .scaleAspectFit
        placeholderIcon.tintColor = UIColor.white.withAlphaComponent(0.3)
        placeholderIcon.isHidden = true
        placeholderView.addSubview(placeholderIcon)

        // Artwork: the compositor's bitmap, already the card's size.
        artworkImageView.translatesAutoresizingMaskIntoConstraints = false
        artworkImageView.contentMode = .scaleAspectFill
        artworkImageView.clipsToBounds = true
        card.contentView.addSubview(artworkImageView)

        // Title logo (Plex clearLogo, falling back to the title).
        titleLogoView.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(titleLogoView)

        // Bottom info bar.
        infoBar.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(infoBar)
        card.contentView.layer.borderColor = Self.restingRim

        let pad = ContinueWatchingCardCompositor.padding
        NSLayoutConstraint.activate([
            placeholderView.topAnchor.constraint(equalTo: card.contentView.topAnchor),
            placeholderView.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
            placeholderView.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            placeholderView.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),

            placeholderIcon.centerXAnchor.constraint(equalTo: placeholderView.centerXAnchor),
            placeholderIcon.centerYAnchor.constraint(equalTo: placeholderView.centerYAnchor),
            placeholderIcon.widthAnchor.constraint(equalToConstant: 32),
            placeholderIcon.heightAnchor.constraint(equalToConstant: 32),

            artworkImageView.topAnchor.constraint(equalTo: card.contentView.topAnchor),
            artworkImageView.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
            artworkImageView.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            artworkImageView.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),


            titleLogoView.topAnchor.constraint(equalTo: card.contentView.topAnchor),
            titleLogoView.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
            titleLogoView.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            titleLogoView.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),

            // Apple's status row: 14pt from the card's edges.
            infoBar.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: pad).withPriority(999),
            infoBar.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -pad).withPriority(999),
            infoBar.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -pad)
        ])
    }

    /// The status row's glyph, label and bar fill follow focus, on the focus clock.
    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let nowFocused = context.nextFocusedView === self
                      || context.nextFocusedView?.isDescendant(of: self) == true
        coordinator.addCoordinatedAnimations({ self.infoBar.setFocused(nowFocused) }, completion: nil)
        // Apple's floating view clears its rim while focused.
        card.contentView.layer.borderColor = nowFocused ? UIColor.clear.cgColor : Self.restingRim
    }

    private static let restingRim = UIColor(white: 1, alpha: 0.03).cgColor

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.contentView.layer.cornerRadius = cornerRadius
        card.contentView.layer.cornerCurve = .continuous
        card.contentView.clipsToBounds = true
        // The rim Apple's floating view draws at rest (its highlightStyle is private).
        card.contentView.layer.borderWidth = 1
        CATransaction.commit()
    }

    // MARK: - Configure

    func configure(item: PlexMetadata) {
        // Title-logo view fetches the clearLogo asynchronously (with a
        // text fallback if there is none).
        let url = artworkURL(for: item)
        titleLogoView.configure(item: item, artworkURL: url)

        // Info bar: play icon + (optional) progress capsule + info text.
        infoBar.configure(item: item)

        loadArtwork(from: url, failureIcon: failurePlaceholderImage(for: item))
    }

    /// MediaItem path. All artwork URLs are already resolved — no serverURL/token needed.
    func configure(item: MediaItem) {
        let (logoURL, url) = Self.urls(for: item)
        titleLogoView.configure(logoURL: logoURL, fallbackTitle: item.title, artworkURL: url)

        infoBar.configure(item: item)

        loadArtwork(from: url, failureKind: item.kind)
    }

    /// Episodes and shows prefer the show's logo; the still is backdrop, then thumbnail.
    private static func urls(for item: MediaItem) -> (logo: URL?, artwork: URL?) {
        (item.grandparentArtwork?.logo ?? item.artwork.logo,
         item.grandparentArtwork?.backdrop ?? item.artwork.backdrop ?? item.artwork.thumbnail)
    }

    /// Builds the card and title for items about to scroll in, so a card
    /// arriving at the screen edge is already finished.
    static func prewarm(_ items: some Sequence<MediaItem>, scale: CGFloat) {
        for item in items {
            let (logoURL, url) = urls(for: item)
            ContinueWatchingTitleLogoView.prewarm(logoURL: logoURL, title: item.title, artworkURL: url, scale: scale)
            guard let url, ContinueWatchingCardCompositor.cached(.card, for: url, geometry: geometry, scale: scale) == nil
            else { continue }
            Task { _ = await ContinueWatchingCardCompositor.image(.card, for: url, geometry: geometry, scale: scale) }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
        currentArtworkURL = nil
        artworkImageView.image = nil
        placeholderView.isHidden = false
        placeholderIcon.isHidden = true
        titleLogoView.prepareForReuse()
        infoBar.reset()
    }

    // MARK: - Artwork

    /// MediaItem path: resolves failure icon via MediaKind then delegates.
    private func loadArtwork(from url: URL?, failureKind: MediaKind) {
        loadArtwork(from: url, failureIcon: failurePlaceholderImage(for: failureKind))
    }

    private func loadArtwork(from url: URL?, failureIcon: UIImage?) {
        artworkLoadTask?.cancel()
        guard let url else {
            artworkImageView.image = nil
            currentArtworkURL = nil
            placeholderView.isHidden = false
            placeholderIcon.image = failureIcon
            placeholderIcon.isHidden = false
            return
        }
        if currentArtworkURL == url, artworkImageView.image != nil {
            placeholderView.isHidden = true
            return
        }
        currentArtworkURL = url
        let geometry = Self.geometry, scale = traitCollection.displayScale
        if let built = ContinueWatchingCardCompositor.cached(.card, for: url, geometry: geometry, scale: scale) {
            artworkImageView.image = built
            placeholderView.isHidden = true
            return
        }
        artworkImageView.image = nil
        placeholderView.isHidden = false
        placeholderIcon.isHidden = true  // hidden during loading
        let key = url.absoluteString as AnyHashable
        artworkLoadTask = Task { [weak self] in
            let image: UIImage? = await Perf.interval(.imageDecode, key: key) {
                await ContinueWatchingCardCompositor.image(.card, for: url, geometry: geometry, scale: scale)
            }
            await MainActor.run {
                guard let self, self.currentArtworkURL == url else { return }
                if let image {
                    self.artworkImageView.image = image
                    self.placeholderView.isHidden = true
                } else {
                    self.placeholderIcon.image = failureIcon
                    self.placeholderIcon.isHidden = false
                }
            }
        }
    }

    private func artworkURL(for item: PlexMetadata) -> URL? {
        guard let serverURL = PlexAuthManager.shared.selectedServerURL,
              let token = PlexAuthManager.shared.selectedServerToken
        else { return nil }
        // Episodes prefer grandparentArt; otherwise art > thumb.
        let path: String?
        if item.type == "episode" {
            path = item.grandparentArt ?? item.art ?? item.thumb
        } else {
            path = item.art ?? item.thumb
        }
        guard let path else { return nil }
        return URL(string: "\(serverURL)\(path)?X-Plex-Token=\(token)")
    }

    /// PlexMetadata failure icon: "film" for movies, "play.rectangle" otherwise.
    private func failurePlaceholderImage(for item: PlexMetadata) -> UIImage? {
        let name = item.type == "movie" ? "film" : "play.rectangle"
        return UIImage(systemName: name)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 32, weight: .light))
    }

    /// MediaItem failure icon — maps MediaKind to a system image name.
    private func failurePlaceholderImage(for kind: MediaKind) -> UIImage? {
        let name: String
        switch kind {
        case .movie:   name = "film"
        case .show:    name = "tv"
        case .season:  name = "number.square"
        case .episode: name = "play.rectangle"
        case .person:  name = "person"
        default:       name = "photo"
        }
        return UIImage(systemName: name)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 32, weight: .light))
    }
}

// MARK: - Title Logo (Plex clearLogo fetch)

/// The item's clearLogo (the show's, for episodes) in the slot the still's
/// analysis picks: either edge, any height. Falls back to the title as text.
/// Nothing shows until the slot is known or a second passes, so the title never moves.
@MainActor
private final class ContinueWatchingTitleLogoView: UIView {
    private typealias Compositor = ContinueWatchingCardCompositor

    private let imageView = UIImageView()
    private let titleLabel = UILabel()
    private var imageTop: NSLayoutConstraint!
    private var labelCenterY: NSLayoutConstraint!

    private var fetchTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var currentItemKey: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        // Fallback title: 30pt bold, white, soft drop shadow.
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = Self.titleFont
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1
        titleLabel.shadowOffset = CGSize(width: 0, height: 2)
        titleLabel.alpha = 0
        addSubview(titleLabel)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.alpha = 0
        addSubview(imageView)

        // The compositor's title bitmap: the title box plus room for its shadow.
        let geometry = ContinueWatchingCell.geometry
        let box = geometry.titleBox.insetBy(dx: -Compositor.titleShadowPad, dy: -Compositor.titleShadowPad)
        imageTop = imageView.topAnchor.constraint(equalTo: topAnchor, constant: box.minY)
        labelCenterY = titleLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: geometry.titleBox.midY)
        NSLayoutConstraint.activate([
            // 999s: tolerate TVCardView's transient zero-width layout pass.
            // Left and right, not leading and trailing: the slot is scored on the artwork's pixels.
            titleLabel.leftAnchor.constraint(equalTo: leftAnchor, constant: geometry.titleBox.minX),
            labelCenterY,
            titleLabel.rightAnchor.constraint(equalTo: rightAnchor, constant: -geometry.titleBox.minX).withPriority(999),

            imageView.leftAnchor.constraint(equalTo: leftAnchor, constant: box.minX),
            imageTop,
            imageView.widthAnchor.constraint(equalToConstant: box.width).withPriority(999),
            imageView.heightAnchor.constraint(equalToConstant: box.height)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(item: PlexMetadata, artworkURL: URL?) {
        configure(key: "\(item.ratingKey ?? "")|\(artworkURL?.absoluteString ?? "")",
                  title: displayTitle(for: item), artworkURL: artworkURL) {
            await Self.resolveLogoURL(for: item)
        }
    }

    /// MediaItem path. The logo URL is already resolved.
    func configure(logoURL: URL?, fallbackTitle: String, artworkURL: URL?) {
        configure(key: Self.key(logoURL: logoURL, title: fallbackTitle, artworkURL: artworkURL),
                  title: fallbackTitle, artworkURL: artworkURL) { logoURL }
    }

    private static func key(logoURL: URL?, title: String, artworkURL: URL?) -> String {
        "\(logoURL?.absoluteString ?? title)|\(artworkURL?.absoluteString ?? "")"
    }

    // MARK: Prepared titles

    /// A title worked out ahead: the bitmap (nil for text) and the slot it sits in.
    private final class Prepared {
        let image: UIImage?
        let logoSize: CGSize?
        let placement: Compositor.Placement
        init(image: UIImage?, logoSize: CGSize?, placement: Compositor.Placement) {
            self.image = image
            self.logoSize = logoSize
            self.placement = placement
        }
    }

    private static let prepared: NSCache<NSString, Prepared> = {
        let cache = NSCache<NSString, Prepared>()
        cache.countLimit = 60
        return cache
    }()
    private static var preparing: [String: Task<(Prepared, keep: Bool), Never>] = [:]

    private static let titleFont = UIFont.systemFont(ofSize: 30, weight: .bold)

    private static func textSize(_ title: String) -> CGSize {
        let size = (title as NSString).size(withAttributes: [.font: titleFont])
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    /// Works out a title once per item and scale; callers share one in-flight run.
    private static func prepare(key: String, title: String, artworkURL: URL?, scale: CGFloat,
                                logoURL: @escaping () async -> URL?) async -> Prepared {
        let cacheKey = "\(key)#\(scale)"
        if let done = prepared.object(forKey: cacheKey as NSString) { return done }
        if let running = preparing[cacheKey] { return await running.value.0 }
        let geometry = ContinueWatchingCell.geometry
        let textSize = textSize(title)
        let task = Task { () -> (Prepared, keep: Bool) in
            async let analysed = signals(for: artworkURL)
            var logo: (url: URL, size: CGSize)?
            let url = await logoURL()
            if let url, let size = await ImageCacheManager.shared.image(for: url)?.size {
                logo = (url, size)
            }
            let placement = Compositor.placement(signals: await analysed, logoSize: logo?.size,
                                                 textSize: textSize, geometry: geometry)
            var image: UIImage?
            if let logo {
                image = await Compositor.image(placement.strongShadow ? .titleStrong : .title, for: logo.url,
                                               geometry: geometry, scale: scale)
            }
            // A logo that failed to load is not kept: the next display tries again.
            let keep = url == nil || image != nil
            return (Prepared(image: image, logoSize: logo?.size, placement: placement), keep)
        }
        preparing[cacheKey] = task
        let (result, keep) = await task.value
        preparing[cacheKey] = nil
        if keep { prepared.setObject(result, forKey: cacheKey as NSString) }
        return result
    }

    static func prewarm(logoURL: URL?, title: String, artworkURL: URL?, scale: CGFloat) {
        let key = key(logoURL: logoURL, title: title, artworkURL: artworkURL)
        guard prepared.object(forKey: "\(key)#\(scale)" as NSString) == nil else { return }
        Task { _ = await prepare(key: key, title: title, artworkURL: artworkURL, scale: scale) { logoURL } }
    }

    /// Loads the logo and the still's analysis side by side, then shows the
    /// logo (or the title) once, in the slot they pick.
    private func configure(key: String, title: String, artworkURL: URL?, logoURL: @escaping () async -> URL?) {
        titleLabel.text = title
        // Same item: shown already, or on its way.
        guard key != currentItemKey else { return }
        fetchTask?.cancel()
        deadlineTask?.cancel()
        imageView.image = nil
        imageView.alpha = 0
        titleLabel.alpha = 0
        currentItemKey = key

        let geometry = ContinueWatchingCell.geometry, scale = traitCollection.displayScale
        let textSize = Self.textSize(title)
        // Worked out ahead (or shown before): in place at once, no fade.
        if let done = Self.prepared.object(forKey: "\(key)#\(scale)" as NSString) {
            show(done.image, logoSize: done.logoSize, placement: done.placement, animated: false)
            return
        }
        fetchTask = Task { [weak self] in
            let done = await Self.prepare(key: key, title: title, artworkURL: artworkURL, scale: scale, logoURL: logoURL)
            guard !Task.isCancelled, let self, self.currentItemKey == key else { return }
            self.show(done.image, logoSize: done.logoSize, placement: done.placement)
        }
        // Slow server: show the text in the default slot rather than nothing.
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.currentItemKey == key,
                  self.imageView.alpha == 0, self.titleLabel.alpha == 0 else { return }
            self.show(nil, logoSize: nil, placement: Compositor.restingPlacement(
                for: geometry.titleFootprint(logoSize: nil, textSize: textSize), geometry: geometry))
        }
    }

    private static func signals(for artworkURL: URL?) async -> Compositor.Signals {
        guard let artworkURL else { return .none }
        return await Compositor.signals(for: artworkURL)
    }

    func prepareForReuse() {
        fetchTask?.cancel()
        fetchTask = nil
        deadlineTask?.cancel()
        currentItemKey = nil
        imageView.image = nil
        imageView.alpha = 0
        titleLabel.alpha = 0
        titleLabel.text = nil
    }

    private func displayTitle(for item: PlexMetadata) -> String {
        if item.type == "episode" {
            return item.grandparentTitle ?? item.title ?? "Unknown"
        }
        return item.title ?? "Unknown"
    }

    /// Both configure paths end here: move to the slot, then fade in.
    private func show(_ image: UIImage?, logoSize: CGSize?, placement: Compositor.Placement, animated: Bool = true) {
        let geometry = ContinueWatchingCell.geometry
        let box = geometry.titleBox.offsetBy(dx: 0, dy: placement.offset)
        imageTop.constant = box.minY - Compositor.titleShadowPad
        // A title already on screen keeps its slot.
        if titleLabel.alpha == 0 {
            labelCenterY.constant = box.midY
            titleLabel.textAlignment = placement.side == .leading ? .left : .right
            titleLabel.shadowColor = UIColor.black.withAlphaComponent(placement.strongShadow ? 0.8 : 0.5)
        }
        imageView.image = image
        // The bitmap holds the logo on the box's leading edge: carry it to its
        // slot, so a smaller or trailing logo keeps the edge it sits on.
        let resting = geometry.titleFootprint(logoSize: logoSize)
        let slot = geometry.titleRect(resting, side: placement.side, scale: placement.scale)
        imageView.transform = CGAffineTransform(
            translationX: slot.midX - box.midX - (resting.midX - box.midX) * placement.scale, y: 0)
            .scaledBy(x: placement.scale, y: placement.scale)
        layoutIfNeeded()
        let reveal = {
            self.imageView.alpha = image == nil ? 0 : 1
            self.titleLabel.alpha = image == nil ? 1 : 0
        }
        if animated {
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseInOut], animations: reveal)
        } else {
            reveal()
        }
    }

    /// Resolve the clearLogo URL — for episodes/shows, fetch the
    /// grandparent metadata (hub items don't carry the Image array).
    /// Caches the full-metadata response via PlexDataStore for reuse.
    private static func resolveLogoURL(for item: PlexMetadata) async -> URL? {
        guard let serverURL = PlexAuthManager.shared.selectedServerURL,
              let token = PlexAuthManager.shared.selectedServerToken else {
            return nil
        }
        // The hub item already carries grandparentRatingKey, so resolve the
        // source key directly (one metadata fetch) via the shared resolver.
        guard let ratingKey = TopShelfLogoResolver.sourceRatingKey(for: item) else { return nil }

        // Plain metadata, not `getFullMetadata`: the only field read below is
        // `clearLogoPath`, and the seven include params buy nothing here while
        // costing 28% more bytes and twice the latency. This runs once per
        // visible cell, so it is the app's one per-item metadata fan-out and
        // showed up in Sentry as an N+1 (RIVULET-V).
        let sourceMetadata: PlexMetadata
        if let cached = PlexDataStore.shared.getCachedLogoMetadata(for: ratingKey) {
            sourceMetadata = cached
        } else {
            do {
                let fetched = try await PlexNetworkManager.shared.getMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
                PlexDataStore.shared.cacheLogoMetadata(fetched, for: ratingKey)
                sourceMetadata = fetched
            } catch {
                return nil
            }
        }

        let urlString = TopShelfLogoResolver.logoURLString(from: sourceMetadata, serverURL: serverURL, token: token)
        return urlString.isEmpty ? nil : URL(string: urlString)
    }
}

// Info bar moved to `Rivulet/Views/Media/UIKit/Cells/MediaProgressInfoBar.swift`
// for reuse by PosterCell (in-progress items in Recently Added /
// Personalized Recommendations rows render the same composition).

extension ContinueWatchingCell: PreviewSourceTile {
    var previewArtworkView: UIView { card.contentView }
    var previewCornerRadius: CGFloat { cornerRadius }
    var previewArtworkLoaded: Bool { artworkImageView.image != nil }
}
