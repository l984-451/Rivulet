// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexPhotoProvider.swift
//  Rivulet
//
//  Plex photo sections. Every assumption about how PMS answers for one lives
//  in this file, measured against a photo section on PMS 1.43.4.
//

import Foundation

enum PlexPhotoMapper {
    /// An album is told from a photo by its key alone: both are `type="photo"`.
    /// Albums carry no item count.
    static func item(_ meta: PlexMetadata, providerID: String, serverURL: String, authToken: String) -> PhotoItem? {
        guard let ratingKey = meta.ratingKey else { return nil }
        let kind: PhotoItem.Kind
        if meta.key?.hasSuffix("/children") == true {
            kind = .folder
        } else if meta.type == "clip" {
            kind = .clip
        } else if meta.type == "photo" {
            kind = .photo
        } else {
            return nil
        }
        func image(_ path: String?, cover: Bool) -> URL? {
            imageURL(path, serverURL: serverURL, authToken: authToken, cover: cover)
        }
        // A clip's Part is the video file, so its still is the thumb.
        let original = kind == .photo ? meta.Media?.first?.Part?.first?.key : nil
        let point = meta.Geolocation?.Coordinates
        return PhotoItem(
            ref: MediaItemRef(providerID: providerID, itemID: ratingKey),
            kind: kind,
            title: meta.title ?? "",
            date: date(meta),
            childCount: nil,
            thumbnail: image(meta.thumb, cover: true),
            full: kind == .folder ? nil : image(original ?? meta.thumb, cover: false),
            playable: kind == .clip
                ? PlexMediaMapper.item(meta, providerID: providerID, serverURL: serverURL, authToken: authToken)
                : nil,
            isFavorite: meta.userRating == 10,
            coordinate: point.map { PhotoCoordinate(latitude: $0.latitude, longitude: $0.longitude) },
            details: kind == .folder ? nil : details(meta))
    }

    /// EXIF comes on the item request only (PMS 1.43.4); a list entry has the size and file.
    static func details(_ meta: PlexMetadata) -> PhotoDetails {
        let media = meta.Media?.first
        return PhotoDetails(
            takenAt: meta.originallyAvailableAt == nil ? nil : date(meta),
            make: PhotoDetails.text(media?.make?.value),
            model: PhotoDetails.text(media?.model?.value),
            lens: PhotoDetails.text(media?.lens?.value),
            fNumber: media?.aperture?.value.flatMap(PhotoDetails.fNumber(plex:)),
            exposureSeconds: media?.exposure?.value.flatMap(PhotoDetails.exposureSeconds(plex:)),
            iso: media?.iso?.value.flatMap { Int($0) },
            width: media?.width,
            height: media?.height,
            fileName: PhotoDetails.fileName(media?.Part?.first?.file))
    }

    /// Date taken (`originallyAvailableAt`, a camera-local day, read in `zone`), else the file's date.
    static func date(_ meta: PlexMetadata, in zone: TimeZone = .current) -> Date? {
        if let taken = meta.originallyAvailableAt,
           let date = try? Date(taken, strategy: Date.ISO8601FormatStyle(timeZone: zone).year().month().day()) {
            return date
        }
        return meta.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// The server's image transcoder. `cover` fills a square tile; without it
    /// the image fits inside the screen. A fit must not send `minSize=1`: with
    /// it a portrait photo comes back screen-wide and several times the bytes.
    static func imageURL(_ path: String?, serverURL: String, authToken: String, cover: Bool) -> URL? {
        guard let path, !path.isEmpty, var components = URLComponents(string: "\(serverURL)/photo/:/transcode") else {
            return nil
        }
        let side = PhotoItem.thumbnailSide
        let (width, height) = cover ? (side, side) : PhotoItem.fullSize
        components.queryItems = [
            URLQueryItem(name: "url", value: path),
            URLQueryItem(name: "width", value: "\(width)"),
            URLQueryItem(name: "height", value: "\(height)"),
            URLQueryItem(name: "upscale", value: "0")
        ] + (cover ? [URLQueryItem(name: "minSize", value: "1")] : [])
          + [URLQueryItem(name: "X-Plex-Token", value: authToken)]
        return components.url
    }
}

extension PlexProvider: PhotoProvider {
    var photoSorts: [PhotoQuery.Sort] { [.dateTaken, .dateAdded, .name] }
    /// `sort=random` pages without repeats; each `start=0` reshuffles.
    var shufflesPhotosOnServer: Bool { true }
    var hasPhotoLocations: Bool { true }

    /// The photos-and-clips request for one page.
    static func photoQueryItems(_ query: PhotoQuery, folder: MediaItemRef?, page: Page) -> [URLQueryItem] {
        let field = switch query.sort {
        case .dateTaken: "originallyAvailableAt"
        case .dateAdded: "addedAt"
        case .name: "titleSort"
        }
        let type = switch query.show {
        case .all: "13,12"
        case .photos: "13"
        case .videos: "12"
        }
        var items = [
            URLQueryItem(name: "X-Plex-Container-Start", value: "\(page.offset)"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "\(page.limit)"),
            URLQueryItem(name: "sort", value: query.shuffled ? "random" : field + (query.ascending ? "" : ":desc")),
            URLQueryItem(name: "type", value: type),
            // With no parent PMS lists only the photos loose at the root;
            // `clusterZoomLevel=1` makes that every photo and clip in the section.
            folder.map { URLQueryItem(name: "parent", value: $0.itemID) }
                ?? URLQueryItem(name: "clusterZoomLevel", value: "1"),
            URLQueryItem(name: "includeGeolocation", value: "1")
        ]
        if query.favoritesOnly { items.append(URLQueryItem(name: "userRating", value: "10")) }
        if let range = query.takenBetween, let days = query.days(),
           let after = Calendar.current.date(byAdding: .day, value: 1, to: range.upperBound) {
            // PMS reads `<=` a day as before that day starts, so the last day is asked as the day after.
            let next = after.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
            items.append(URLQueryItem(name: "originallyAvailableAt>", value: days.first))
            items.append(URLQueryItem(name: "originallyAvailableAt<", value: next))
        }
        return items
    }

    /// Years of `originallyAvailableAt`. Photos only: `type=13,12` is a 400 (PMS 1.43.4).
    func photoYears(in library: MediaLibrary) async throws -> [Int] {
        try await plexCall {
            guard let url = URL(string: "\(serverURL)/library/sections/\(library.id)/year?type=13") else {
                throw PlexAPIError.invalidURL
            }
            let container: PlexFilterValueContainer = try await networkManager.request(
                url, headers: networkManager.plexHeaders(authToken: authToken))
            return (container.MediaContainer.Directory ?? []).compactMap { Int($0.key) }
        }
    }

    /// A photo favorite is `rating=10`; clearing sends `-1`, which drops any rating set elsewhere.
    func setPhotoFavorite(_ favorite: Bool, for ref: MediaItemRef) async throws {
        try await plexCall {
            try await networkManager.setRating(serverURL: serverURL, authToken: authToken,
                                               ratingKey: ref.itemID, rating: favorite ? 10 : nil)
        }
    }

    /// EXIF comes on the item request only, laid over what the list gave.
    func photoDetails(for item: PhotoItem) async throws -> PhotoDetails? {
        guard item.kind == .photo else { return item.details }
        return try await plexCall {
            let meta = try await networkManager.getMetadata(serverURL: serverURL, authToken: authToken,
                                                            ratingKey: item.ref.itemID)
            return PlexPhotoMapper.details(meta).merged(over: item.details)
        }
    }

    /// One level: its albums once (type 14), then its photos and clips (types 13, 12), paged.
    func photoPage(in library: MediaLibrary, folder: MediaItemRef?, query: PhotoQuery, page: Page) async throws -> PhotoPage {
        try await plexCall {
            func map(_ metas: [PlexMetadata]) -> [PhotoItem] {
                metas.compactMap {
                    PlexPhotoMapper.item($0, providerID: id, serverURL: serverURL, authToken: authToken)
                }
            }
            // ponytail: one request of 1000 albums; page it if a level ever has more.
            func albums() async throws -> [PlexMetadata] {
                guard page.offset == 0, query.listsAlbums else { return [] }
                return try await networkManager.getLibraryItemsWithTotal(
                    serverURL: serverURL, authToken: authToken, sectionId: library.id,
                    size: 1000, sort: "titleSort", type: 14,
                    filters: folder.map { [URLQueryItem(name: "parent", value: $0.itemID)] } ?? []).items
            }
            async let albumList = albums()
            guard var components = URLComponents(string: "\(serverURL)/library/sections/\(library.id)/all") else {
                throw PlexAPIError.invalidURL
            }
            components.queryItems = Self.photoQueryItems(query, folder: folder, page: page)
            guard let url = components.url else { throw PlexAPIError.invalidURL }
            let photos: PlexMediaContainerWrapper = try await networkManager.request(
                url, headers: networkManager.plexHeaders(authToken: authToken))
            let next = Page(offset: page.offset + page.limit, limit: page.limit)
            let more = next.offset < (photos.MediaContainer.totalSize ?? 0)
            return PhotoPage(folders: map(try await albumList).filter { $0.kind == .folder },
                             media: map(photos.MediaContainer.Metadata ?? []).filter { $0.kind != .folder },
                             nextPage: more ? next : nil)
        }
    }
}
