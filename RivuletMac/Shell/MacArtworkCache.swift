// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import AppKit
import ImageIO

/// Memory cache for every piece of Mac artwork. Plex's transcode URLs carry
/// their requested size, so URL identity is also decode-size identity.
actor MacArtworkCache {
    static let shared = MacArtworkCache()

    nonisolated(unsafe) private let images = NSCache<NSURL, NSImage>()
    /// One shared fetch per URL, cancelled once every caller waiting on it is cancelled.
    private struct Download {
        let id: UUID
        let task: Task<NSImage?, Never>
        var waiters: Int
    }
    private var downloads: [URL: Download] = [:]
    /// Trusts the self-signed certificates a raw-IP or plex.direct server presents, as the API client does.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = urlCache
        return URLSession(configuration: config, delegate: PlexCertificateDelegate(), delegateQueue: nil)
    }()
    private static let urlCache = ArtworkRequest.makeCache()

    private init() {
        images.countLimit = 400
        images.totalCostLimit = 160 * 1024 * 1024
    }

    func clear() {
        images.removeAllObjects()
        Self.urlCache.removeAllCachedResponses()
    }

    /// Read synchronously so a recreated tile shows its art on the first frame.
    nonisolated func cachedImage(for url: URL) -> NSImage? {
        images.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> NSImage? {
        if let cached = images.object(forKey: url as NSURL) { return cached }
        if var existing = downloads[url] {
            existing.waiters += 1
            downloads[url] = existing
            return await wait(for: existing, url: url)
        }

        let task = Task.detached(priority: .userInitiated) { () -> NSImage? in
            let fetched = url.isFileURL
                ? (try? Data(contentsOf: url)).map { ($0, URLResponse()) }
                : try? await Self.session.data(for: ArtworkRequest.request(for: url))
            guard let (data, response) = fetched,
                  ((response as? HTTPURLResponse)?.statusCode ?? 200) < 400 else { return nil }
            if let image = Self.decode(data) { return image }
            guard let svg = await SVGRasterizer.decode(data, maxPixelSize: 512) else { return nil }
            return NSImage(cgImage: svg, size: NSSize(width: svg.width, height: svg.height))
        }
        let download = Download(id: UUID(), task: task, waiters: 1)
        downloads[url] = download
        return await wait(for: download, url: url)
    }

    private func wait(for download: Download, url: URL) async -> NSImage? {
        let image = await withTaskCancellationHandler {
            await download.task.value
        } onCancel: {
            Task { await self.dropWaiter(for: url, id: download.id) }
        }
        if downloads[url]?.id == download.id { downloads[url] = nil }
        if let image {
            let pixels = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh }
                ?? Int(image.size.width * image.size.height)
            images.setObject(image, forKey: url as NSURL, cost: max(1, pixels) * 4)
        }
        return image
    }

    private func dropWaiter(for url: URL, id: UUID) {
        guard var download = downloads[url], download.id == id else { return }
        download.waiters -= 1
        if download.waiters > 0 {
            downloads[url] = download
        } else {
            downloads[url] = nil
            download.task.cancel()
        }
    }

    /// Decodes at full size here, off the main thread; NSImage(data:) would decode at first draw.
    /// The point size is what NSImage(data:) reports, so layout reading it is unchanged.
    private nonisolated static func decode(_ data: Data) -> NSImage? {
        guard let reference = NSImage(data: data), let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let longSide = max(props?[kCGImagePropertyPixelWidth] as? Int ?? 0, props?[kCGImagePropertyPixelHeight] as? Int ?? 0)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longSide
        ]
        guard longSide > 0, let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return reference }
        return NSImage(cgImage: cg, size: reference.size)
    }
}

extension NSImage {
    var cgImageRepresentation: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
