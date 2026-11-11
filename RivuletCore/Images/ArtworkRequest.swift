// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Foundation

/// How the iOS and Mac artwork loaders ask for an image.
nonisolated enum ArtworkRequest {
    /// The Plex token rides a header, so the URL URLCache writes to disk never holds it.
    static func request(for url: URL) -> URLRequest {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var items = parts.percentEncodedQueryItems,
              let index = items.firstIndex(where: { $0.name == "X-Plex-Token" }) else {
            return URLRequest(url: url)
        }
        let token = items.remove(at: index).value?.removingPercentEncoding
        parts.percentEncodedQueryItems = items.isEmpty ? nil : items
        var request = URLRequest(url: parts.url ?? url)
        if let token { request.setValue(token, forHTTPHeaderField: "X-Plex-Token") }
        return request
    }

    /// A small memory tier (the loaders hold decoded images) and a real disk tier.
    static func makeCache() -> URLCache {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ArtworkURLCache", isDirectory: true)
        return URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024, directory: dir)
    }
}
