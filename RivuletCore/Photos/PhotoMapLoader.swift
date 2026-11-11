// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PhotoMapLoader.swift
//  Rivulet
//
//  Every located photo in a library, for the map. Kept for the app session,
//  in memory only: coordinates are never logged or written to disk.
//

import Foundation

@MainActor
final class PhotoMapLoader {
    private static var cache: [String: [PhotoItem]] = [:]

    let provider: any PhotoProvider
    let library: MediaLibrary
    let pageSize: Int

    init(provider: any PhotoProvider, library: MediaLibrary, pageSize: Int = 1000) {
        self.provider = provider
        self.library = library
        self.pageSize = pageSize
    }

    private var key: String { "\(library.providerID)|\(library.id)" }

    /// Pages through every photo with `show: .photos`, keeping those with a coordinate;
    /// calls back with each page's located photos. A cached library answers in one call.
    func load(onPage: @escaping ([PhotoItem]) -> Void) async {
        if let cached = Self.cache[key] {
            onPage(cached)
            return
        }
        var query = PhotoQuery.default
        query.show = .photos
        var page: Page? = Page(offset: 0, limit: pageSize)
        var located: [PhotoItem] = []
        while let current = page, !Task.isCancelled {
            guard let result = try? await provider.photoPage(in: library, folder: nil, query: query, page: current) else {
                return  // A failed page leaves nothing cached, so the next open tries again.
            }
            let found = result.media.filter { $0.coordinate != nil }
            located += found
            onPage(found)
            page = result.nextPage
        }
        if page == nil { Self.cache[key] = located }
    }

    static func clearCache() { cache = [:] }

    /// Located photos grouped into square cells `cell` degrees wide, for maps with no clustering of their own.
    /// ponytail: a fixed grid, so a group can split across a cell edge; distance clustering if that reads badly.
    nonisolated static func clusters(_ items: [PhotoItem], cell: Double) -> [[PhotoItem]] {
        guard cell > 0 else { return items.map { [$0] } }
        return places(items, cell: cell).map(\.photos)
    }

    /// Located photos grouped into cells `cell` degrees wide, newest place first by its newest photo.
    nonisolated static func places(_ items: [PhotoItem], cell: Double = 0.1) -> [PhotoPlace] {
        var groups: [PhotoPlace.ID: [PhotoItem]] = [:]
        for item in items {
            guard let point = item.coordinate else { continue }
            let id = PhotoPlace.ID(latitude: Int((point.latitude / cell).rounded(.down)),
                                   longitude: Int((point.longitude / cell).rounded(.down)))
            groups[id, default: []].append(item)
        }
        let newer = { (a: PhotoItem, b: PhotoItem) in (a.date ?? .distantPast) > (b.date ?? .distantPast) }
        return groups.map { PhotoPlace(id: $0.key, photos: $0.value.sorted(by: newer)) }.sorted {
            if newer($0.photos[0], $1.photos[0]) { return true }
            if newer($1.photos[0], $0.photos[0]) { return false }
            return ($0.id.latitude, $0.id.longitude) < ($1.id.latitude, $1.id.longitude)
        }
    }
}

/// One grid cell's located photos, for the tvOS map's list of places.
nonisolated struct PhotoPlace: Identifiable, Hashable, Sendable {
    struct ID: Hashable, Sendable {
        let latitude: Int
        let longitude: Int
    }

    let id: ID
    /// Newest first, never empty.
    let photos: [PhotoItem]
}
