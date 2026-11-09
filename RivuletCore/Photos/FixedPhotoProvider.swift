// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  FixedPhotoProvider.swift
//  Rivulet
//
//  A listing of photos already in hand, one page, for a viewer over them.
//

import Foundation

nonisolated struct FixedPhotoProvider: PhotoProvider {
    let items: [PhotoItem]

    init(items: [PhotoItem]) { self.items = items }

    var photoSorts: [PhotoQuery.Sort] { [] }
    var shufflesPhotosOnServer: Bool { true }
    var hasPhotoLocations: Bool { false }

    func photoPage(in library: MediaLibrary, folder: MediaItemRef?, query: PhotoQuery, page: Page) async throws -> PhotoPage {
        PhotoPage(folders: [], media: query.shuffled ? items.shuffled() : items, nextPage: nil)
    }

    func setPhotoFavorite(_ favorite: Bool, for ref: MediaItemRef) async throws {
        throw MediaProviderError.backendSpecific(underlying: "favorites not supported")
    }
}
