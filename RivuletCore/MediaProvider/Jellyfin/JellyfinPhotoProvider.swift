// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  JellyfinPhotoProvider.swift
//  Rivulet
//
//  Jellyfin "Home Videos and Photos" libraries. Every assumption about what
//  the server answers for one lives in this file. Measured on Jellyfin 12.1.
//

import Foundation

enum JellyfinPhotoMapper {
    static func item(_ dto: JFItem, providerID: String, baseURL: URL) -> PhotoItem? {
        guard let id = dto.id else { return nil }
        let kind: PhotoItem.Kind
        switch dto.type {
        case "PhotoAlbum", "Folder": kind = .folder
        case "Photo": kind = .photo
        case "Video": kind = .clip
        default: return nil
        }
        let side = "\(PhotoItem.thumbnailSide)"
        let (width, height) = PhotoItem.fullSize
        func image(_ size: [URLQueryItem]) -> URL? {
            guard let url = JellyfinMediaMapper.imageURL(baseURL, itemID: id, type: "Primary",
                                                         tag: dto.imageTags?["Primary"]) else { return nil }
            return url.appending(queryItems: size + [URLQueryItem(name: "quality", value: "90")])
        }
        return PhotoItem(
            ref: MediaItemRef(providerID: providerID, itemID: id),
            kind: kind,
            title: dto.name ?? "",
            date: date(dto, kind: kind),
            childCount: kind == .folder ? dto.recursiveItemCount : nil,
            thumbnail: image([URLQueryItem(name: "fillWidth", value: side),
                              URLQueryItem(name: "fillHeight", value: side)]),
            full: kind == .folder ? nil : image([URLQueryItem(name: "maxWidth", value: "\(width)"),
                                                 URLQueryItem(name: "maxHeight", value: "\(height)")]),
            playable: kind == .clip
                ? JellyfinMediaMapper.item(dto, providerID: providerID, baseURL: baseURL)
                : nil,
            isFavorite: dto.userData?.isFavorite == true,
            coordinate: dto.latitude.flatMap { lat in
                dto.longitude.map { PhotoCoordinate(latitude: lat, longitude: $0) }
            },
            details: kind == .folder ? nil : PhotoDetails(
                takenAt: dto.dateCreated.flatMap(JellyfinMediaMapper.parseDate),
                make: PhotoDetails.text(dto.cameraMake),
                model: PhotoDetails.text(dto.cameraModel),
                fNumber: dto.aperture.map(PhotoDetails.fNumber(apex:)),
                exposureSeconds: dto.exposureTime,
                iso: dto.isoSpeedRating,
                focalLength: dto.focalLength,
                width: dto.width,
                height: dto.height,
                fileName: PhotoDetails.fileName(dto.path),
                // DateCreated is the camera's clock when EXIF gave a PremiereDate, else the file's instant.
                takenAtClock: kind == .photo && dto.premiereDate != nil ? .wallClock : .instant))
    }

    /// A photo's PremiereDate is the camera's wall clock stamped Z: read its
    /// day in `zone`, the device's. A clip's, and DateCreated, are instants.
    static func date(_ dto: JFItem, kind: PhotoItem.Kind, in zone: TimeZone = .current) -> Date? {
        if kind == .photo, let taken = dto.premiereDate,
           let day = try? Date(String(taken.prefix(10)),
                               strategy: Date.ISO8601FormatStyle(timeZone: zone).year().month().day()) {
            return day
        }
        return (dto.premiereDate ?? dto.dateCreated).flatMap(JellyfinMediaMapper.parseDate)
    }
}

extension JellyfinProvider: PhotoProvider {
    /// What a "homevideos" view holds, by two counts with no items.
    /// Throws on a failed probe, so the store keeps the libraries it had.
    func homeVideosContent(libraryID: String) async throws -> HomeVideosContent {
        func count(_ type: String) async throws -> Int {
            let result: JFQueryResult = try await client.get("Items", [
                URLQueryItem(name: "parentId", value: libraryID),
                URLQueryItem(name: "recursive", value: "true"),
                URLQueryItem(name: "includeItemTypes", value: type),
                URLQueryItem(name: "limit", value: "0"),
                URLQueryItem(name: "enableTotalRecordCount", value: "true")
            ])
            return result.totalRecordCount ?? 0
        }
        if try await count("Photo") == 0 { return .videos }
        return try await count("Video") > 0 ? .videos : .photosOnly
    }

    var photoSorts: [PhotoQuery.Sort] { [.dateTaken, .name] }
    /// `sortBy=Random` repeats photos across pages, so the listing shuffles.
    var shufflesPhotosOnServer: Bool { false }
    var hasPhotoLocations: Bool { true }

    /// The photos-and-clips request for one page, less its `parentId`.
    /// Date Taken is `DateCreated`: the EXIF capture time when there is one, else the file's date.
    static func photoQueryItems(_ query: PhotoQuery, folder: MediaItemRef?, page: Page) -> [URLQueryItem] {
        let types = switch query.show {
        case .all: "Photo,Video"
        case .photos: "Photo"
        case .videos: "Video"
        }
        var items = [
            URLQueryItem(name: "fields", value: "DateCreated,RecursiveItemCount,Path,Width,Height"),
            URLQueryItem(name: "includeItemTypes", value: types),
            URLQueryItem(name: "sortBy", value: query.sort == .name ? "SortName" : "DateCreated,SortName"),
            URLQueryItem(name: "sortOrder", value: query.ascending ? "Ascending" : "Descending"),
            URLQueryItem(name: "startIndex", value: "\(page.offset)"),
            URLQueryItem(name: "limit", value: "\(page.limit)"),
            URLQueryItem(name: "enableTotalRecordCount", value: "true")
        ]
        // The root lists every photo in the library; a folder lists its own. Favorites are recursive.
        if folder == nil || query.favoritesOnly { items.append(URLQueryItem(name: "recursive", value: "true")) }
        if query.favoritesOnly { items.append(URLQueryItem(name: "filters", value: "IsFavorite")) }
        // A photo's PremiereDate is the camera's wall clock stamped Z, so the days go as they are.
        if let days = query.days() {
            items.append(URLQueryItem(name: "minPremiereDate", value: "\(days.first)T00:00:00Z"))
            items.append(URLQueryItem(name: "maxPremiereDate", value: "\(days.last)T23:59:59Z"))
        }
        return items
    }

    /// `Years` is ProductionYear, set only for photos with an EXIF date: the same photos
    /// `minPremiereDate` finds (12.1). Others carry no taken date for a filter to match.
    func photoYears(in library: MediaLibrary) async throws -> [Int] {
        let result: JFQueryResult = try await client.get("Years", [
            URLQueryItem(name: "parentId", value: library.id),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "includeItemTypes", value: "Photo")
        ])
        return (result.items ?? []).compactMap { $0.name.flatMap { Int($0) } }
    }

    func setPhotoFavorite(_ favorite: Bool, for ref: MediaItemRef) async throws {
        try await setFavorite(favorite, for: ref)
    }

    func photoPage(in library: MediaLibrary, folder: MediaItemRef?, query: PhotoQuery, page: Page) async throws -> PhotoPage {
        let parent = URLQueryItem(name: "parentId", value: folder?.itemID ?? library.id)
        func map(_ result: JFQueryResult?) -> [PhotoItem] {
            (result?.items ?? []).compactMap {
                JellyfinPhotoMapper.item($0, providerID: id, baseURL: client.baseURL)
            }
        }

        // Asked for once. Without `recursive=false` a library id recurses by
        // itself: nested albums and the library's own Folder join the root.
        func folders() async throws -> JFQueryResult? {
            guard page.offset == 0, query.listsAlbums else { return nil }
            return try await client.get("Items", [
                parent,
                URLQueryItem(name: "fields", value: "DateCreated,RecursiveItemCount"),
                URLQueryItem(name: "includeItemTypes", value: "PhotoAlbum,Folder"),
                URLQueryItem(name: "recursive", value: "false"),
                URLQueryItem(name: "sortBy", value: "SortName")
            ])
        }
        async let folderList = folders()
        // `userId` brings each photo's UserData (its favorite); `filters=IsFavorite` without it is a 500 on 12.1.
        let user = URLQueryItem(name: "userId", value: userID)
        let media: JFQueryResult = try await client.get("Items", [parent, user] + Self.photoQueryItems(query, folder: folder, page: page))
        let next = Page(offset: page.offset + page.limit, limit: page.limit)
        return PhotoPage(folders: map(try await folderList).filter { $0.kind == .folder },
                         media: map(media).filter { $0.kind != .folder },
                         nextPage: next.offset < (media.totalRecordCount ?? 0) ? next : nil)
    }
}
