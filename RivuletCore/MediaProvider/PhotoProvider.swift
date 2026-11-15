// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PhotoProvider.swift
//  Rivulet
//
//  The photo seam. A MediaProvider that can list photos adopts it by
//  extension; the page finds it by casting the registered provider.
//

import Foundation

protocol PhotoProvider: Sendable {
    /// The sorts this server can order photos by. Date Added is Plex only.
    var photoSorts: [PhotoQuery.Sort] { get }
    /// Whether a server-side random order pages without repeats (Plex); else the listing shuffles.
    var shufflesPhotosOnServer: Bool { get }
    /// Whether photos can carry a coordinate.
    var hasPhotoLocations: Bool { get }
    /// One page of a library's root (`folder` nil) or of a folder, in `query`'s order.
    /// Folders arrive on the first page only, and only for `query.listsAlbums`.
    func photoPage(in library: MediaLibrary, folder: MediaItemRef?, query: PhotoQuery, page: Page) async throws -> PhotoPage
    /// Marks or clears one photo or clip as a favorite.
    func setPhotoFavorite(_ favorite: Bool, for ref: MediaItemRef) async throws
    /// A photo's details as complete as the server has them, which may take a request of its own.
    func photoDetails(for item: PhotoItem) async throws -> PhotoDetails?
    /// The years the library's photos were taken in, as the server's date filter sees them.
    func photoYears(in library: MediaLibrary) async throws -> [Int]
}

extension PhotoProvider {
    /// The list already carries everything (Jellyfin, Emby).
    func photoDetails(for item: PhotoItem) async throws -> PhotoDetails? { item.details }
}
