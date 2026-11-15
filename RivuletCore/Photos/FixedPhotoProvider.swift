// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  FixedPhotoProvider.swift
//  Rivulet
//
//  A listing of photos already in hand, one page, for a viewer over them.
//  Favorites and details go to `server` when there is one.
//

import Foundation

nonisolated struct FixedPhotoProvider: PhotoProvider {
    let items: [PhotoItem]
    let server: (any PhotoProvider)?

    init(items: [PhotoItem], server: (any PhotoProvider)? = nil) {
        self.items = items
        self.server = server
    }

    var photoSorts: [PhotoQuery.Sort] { [] }
    var shufflesPhotosOnServer: Bool { true }
    var hasPhotoLocations: Bool { false }

    func photoPage(in library: MediaLibrary, folder: MediaItemRef?, query: PhotoQuery, page: Page) async throws -> PhotoPage {
        PhotoPage(folders: [], media: query.shuffled ? items.shuffled() : items, nextPage: nil)
    }

    func photoYears(in library: MediaLibrary) async throws -> [Int] {
        Set(items.compactMap { $0.date.map { Calendar.current.component(.year, from: $0) } }).sorted(by: >)
    }

    func setPhotoFavorite(_ favorite: Bool, for ref: MediaItemRef) async throws {
        guard let server else { throw MediaProviderError.backendSpecific(underlying: "favorites not supported") }
        try await server.setPhotoFavorite(favorite, for: ref)
    }

    func photoDetails(for item: PhotoItem) async throws -> PhotoDetails? {
        try await server?.photoDetails(for: item) ?? item.details
    }
}
