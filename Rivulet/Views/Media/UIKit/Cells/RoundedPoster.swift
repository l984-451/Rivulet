// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Artwork preserves source transparency; corners are applied at the view level.

import UIKit

nonisolated enum RoundedPoster {
    /// The resting corner, in points. Overlays on a poster use the same value.
    static let cornerRadius: CGFloat = 20

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 64 << 20
        return cache
    }()

    private static let queue = DispatchQueue(label: "rivulet.rounded-poster", qos: .userInitiated)

    @MainActor
    static func configureImageView(_ imageView: UIImageView) {
        configureViewCorners(imageView)
        imageView.masksFocusEffectToContents = false
    }

    @MainActor
    static func configureViewCorners(_ view: UIView) {
        view.cornerConfiguration = .uniformCorners(radius: .fixed(cornerRadius))
        view.layer.cornerCurve = .continuous
    }

    /// Prepared artwork, without waiting: from this cache, or drawn here from the image
    /// cache's decoded copy. Nil when the source isn't decoded yet.
    static func cached(for url: URL, shape: Shape) -> UIImage? {
        let key = shape.key(url)
        if let hit = cache.object(forKey: key) { return hit }
        guard let source = ImageCacheManager.shared.cachedImage(for: url)?.cgImage else { return nil }
        return store(render(source, shape: shape), key)
    }

    /// Prepared artwork, loading the source through the image cache and drawing off the main thread.
    static func image(for url: URL, shape: Shape) async -> UIImage? {
        let key = shape.key(url)
        if let hit = cache.object(forKey: key) { return hit }
        guard let source = await ImageCacheManager.shared.image(for: url)?.cgImage else { return nil }
        let rendered = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: render(source, shape: shape)) }
        }
        return store(rendered, key)
    }

    /// Image size and scale for one tile.
    struct Shape: Sendable {
        let size: CGSize
        let scale: CGFloat

        /// Fills the host size that TVPosterView scales the image to on focus.
        @MainActor init(tile: MediaRowMetrics.Tile, scale: CGFloat) {
            size = tile.hostSize
            self.scale = scale
        }

        fileprivate func key(_ url: URL) -> NSString {
            "\(Int(size.width * scale))x\(Int(size.height * scale))#\(url.absoluteString)" as NSString
        }
    }

    static func render(_ source: CGImage, shape: Shape) -> UIImage {
        let size = shape.size
        let format = UIGraphicsImageRendererFormat.layeredArtwork(scale: shape.scale)
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let srcW = CGFloat(source.width), srcH = CGFloat(source.height)
            let fill = max(size.width / srcW, size.height / srcH)
            let drawSize = CGSize(width: srcW * fill, height: srcH * fill)
            UIImage(cgImage: source).draw(in: CGRect(x: (size.width - drawSize.width) / 2,
                                                     y: (size.height - drawSize.height) / 2,
                                                     width: drawSize.width, height: drawSize.height))
        }
    }

    private static func store(_ image: UIImage, _ key: NSString) -> UIImage {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: key, cost: cost)
        return image
    }
}

extension UIGraphicsImageRendererFormat {
    /// For artwork drawn with transparency that a focus-layered view shows (TVPosterView,
    /// `adjustsImageWhenAncestorFocused`). Standard range always: a wide-colour display's default is
    /// 16-bit float, and UIKit's shadow check reads past the end of such an image (SIGSEGV in vImage).
    nonisolated static func layeredArtwork(scale: CGFloat? = nil) -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        if let scale { format.scale = scale }
        format.preferredRange = .standard
        return format
    }
}
