// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import UIKit

/// Lightweight memory cache for iOS hero and guide artwork. Plex's transcode
/// URLs already include their requested dimensions, so URL identity is also
/// the decode-size identity and one cache can safely serve every surface.
actor IOSArtworkCache {
    static let shared = IOSArtworkCache()

    private let images = NSCache<NSURL, UIImage>()
    private var downloads: [URL: Task<UIImage?, Never>] = [:]

    private init() {
        images.countLimit = 48
        images.totalCostLimit = 96 * 1024 * 1024
    }

    func image(for url: URL) async -> UIImage? {
        if let cached = images.object(forKey: url as NSURL) { return cached }
        if let existing = downloads[url] { return await existing.value }

        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  ((response as? HTTPURLResponse)?.statusCode ?? 200) < 400 else {
                return nil
            }
            return UIImage(data: data)
        }
        downloads[url] = task
        let image = await task.value
        downloads[url] = nil

        if let image {
            let pixels = image.cgImage.map { $0.width * $0.height }
                ?? Int(image.size.width * image.size.height)
            images.setObject(image, forKey: url as NSURL, cost: pixels * 4)
        }
        return image
    }
}
