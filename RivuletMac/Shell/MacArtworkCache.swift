// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import AppKit

/// Memory cache for every piece of Mac artwork. Plex's transcode URLs carry
/// their requested size, so URL identity is also decode-size identity.
actor MacArtworkCache {
    static let shared = MacArtworkCache()

    nonisolated(unsafe) private let images = NSCache<NSURL, NSImage>()
    private var downloads: [URL: Task<NSImage?, Never>] = [:]
    /// Trusts the self-signed certificates a raw-IP or plex.direct server presents, as the API client does.
    private static let session = URLSession(configuration: .default, delegate: PlexCertificateDelegate(), delegateQueue: nil)

    private init() {
        images.countLimit = 400
        images.totalCostLimit = 160 * 1024 * 1024
    }

    func clear() {
        images.removeAllObjects()
    }

    /// Read synchronously so a recreated tile shows its art on the first frame.
    nonisolated func cachedImage(for url: URL) -> NSImage? {
        images.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> NSImage? {
        if let cached = images.object(forKey: url as NSURL) { return cached }
        if let existing = downloads[url] { return await existing.value }

        let task = Task.detached(priority: .userInitiated) { () -> NSImage? in
            let fetched = url.isFileURL
                ? (try? Data(contentsOf: url)).map { ($0, URLResponse()) }
                : try? await Self.session.data(from: url)
            guard let (data, response) = fetched,
                  ((response as? HTTPURLResponse)?.statusCode ?? 200) < 400 else { return nil }
            if let image = NSImage(data: data) { return image }
            guard let svg = await SVGRasterizer.decode(data, maxPixelSize: 512) else { return nil }
            return NSImage(cgImage: svg, size: NSSize(width: svg.width, height: svg.height))
        }
        downloads[url] = task
        let image = await task.value
        downloads[url] = nil

        if let image {
            let pixels = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh }
                ?? Int(image.size.width * image.size.height)
            images.setObject(image, forKey: url as NSURL, cost: max(1, pixels) * 4)
        }
        return image
    }
}

extension NSImage {
    var cgImageRepresentation: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
