// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyPhotoProvider.swift
//  Rivulet
//
//  Emby "Home Videos and Photos" libraries. Every assumption about what the server answers for
//  one lives in this file. Measured on Emby 4.10.2.
//

import Foundation

enum EmbyPhotoMapper {
    static func item(_ dto: EmbyItem, providerID: String, baseURL: URL) -> PhotoItem? {
        let kind: PhotoItem.Kind
        switch dto.type {
        case "PhotoAlbum", "Folder": kind = .folder
        case "Photo": kind = .photo
        case "Video": kind = .clip
        default: return nil
        }
        // A photo's own image; an album names a child's. A clip has none, and its image route is a 500.
        let source: (id: EmbyID?, tag: String?) = switch kind {
        case .photo: (dto.id, dto.imageTags?["Primary"])
        case .folder: (dto.primaryImageItemId, dto.primaryImageTag)
        case .clip: (nil, nil)
        }
        func image(_ size: [URLQueryItem]) -> URL? {
            guard let url = EmbyMediaMapper.imageURL(baseURL, itemID: source.id, type: "Primary", tag: source.tag)
            else { return nil }
            return url.appending(queryItems: size)
        }
        let side = "\(PhotoItem.thumbnailSide)"
        let (width, height) = PhotoItem.fullSize
        return PhotoItem(
            ref: MediaItemRef(providerID: providerID, itemID: dto.id.value),
            kind: kind,
            title: dto.name,
            date: date(dto, kind: kind),
            childCount: kind == .folder ? dto.recursiveItemCount : nil,
            // `FillWidth` and `FillHeight` are ignored (the full original comes back, 9 MB for HEIC);
            // `MaxWidth` and `MaxHeight` fit the box and the cell crops to fill. Quality defaults high.
            thumbnail: image([URLQueryItem(name: "MaxWidth", value: side), URLQueryItem(name: "MaxHeight", value: side),
                              URLQueryItem(name: "Quality", value: "90")]),
            full: kind == .photo ? image([URLQueryItem(name: "MaxWidth", value: "\(width)"),
                                          URLQueryItem(name: "MaxHeight", value: "\(height)")]) : nil,
            playable: kind == .clip ? EmbyMediaMapper.item(dto, providerID: providerID, baseURL: baseURL) : nil,
            isFavorite: dto.userData?.isFavorite == true,
            // Emby sends no EXIF and no coordinates, even when asked.
            details: kind == .folder ? nil : PhotoDetails(
                takenAt: EmbyJSON.date(dto.dateCreated), width: dto.width, height: dto.height,
                fileName: PhotoDetails.fileName(dto.path),
                // DateCreated is the camera's clock when EXIF gave a PremiereDate, else the file's instant.
                takenAtClock: kind == .photo && dto.premiereDate.map { !$0.hasPrefix("0001-") } == true
                    ? .wallClock : .instant))
    }

    /// A photo's PremiereDate is the camera's wall clock stamped Z, and DateCreated carries the same
    /// stamp: read its day in `zone`, the device's. Without EXIF only DateCreated is set, and it and a
    /// clip's dates are real instants.
    static func date(_ dto: EmbyItem, kind: PhotoItem.Kind, in zone: TimeZone = .current) -> Date? {
        if kind == .photo, let taken = dto.premiereDate, !taken.hasPrefix("0001-"),
           let day = try? Date(String(taken.prefix(10)),
                               strategy: Date.ISO8601FormatStyle(timeZone: zone).year().month().day()) {
            return day
        }
        return EmbyJSON.date(dto.premiereDate) ?? EmbyJSON.date(dto.dateCreated)
    }
}

extension EmbyProvider: PhotoProvider {
    var photoSorts: [PhotoQuery.Sort] { [.dateTaken, .name] }
    /// `SortBy=Random` repeats photos across pages, so the listing shuffles.
    var shufflesPhotosOnServer: Bool { false }
    var hasPhotoLocations: Bool { false }

    /// Asked for once, and `Recursive=false` is sent: Emby treats omission as false, but `true`
    /// adds the library's own physical Folder and every nested album.
    private func photoFolders(_ parent: URLQueryItem, query: PhotoQuery, page: Page) async throws -> EmbyQueryResult? {
        guard page.offset == 0, query.listsAlbums else { return nil }
        return try await client.get(itemsPath, [
            parent,
            URLQueryItem(name: "IncludeItemTypes", value: "PhotoAlbum,Folder"),
            URLQueryItem(name: "Recursive", value: "false"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "Fields", value: "RecursiveItemCount,ChildCount,DateCreated,PrimaryImageAspectRatio")
        ])
    }

    /// The photos-and-clips request for one page, less its `ParentId`.
    /// Date Taken is `DateCreated`: the EXIF capture time when there is one, else the file's date.
    static func photoQueryItems(_ query: PhotoQuery, folder: MediaItemRef?, page: Page) -> [URLQueryItem] {
        let types = switch query.show {
        case .all: "Photo,Video"
        case .photos: "Photo"
        case .videos: "Video"
        }
        let order = query.ascending ? "Ascending" : "Descending"
        var items = [
            URLQueryItem(name: "IncludeItemTypes", value: types),
            // The root lists every photo and clip in the library (without `Recursive` only the loose
            // files); a folder lists its own. Favorites are recursive.
            URLQueryItem(name: "Recursive", value: folder == nil || query.favoritesOnly ? "true" : "false"),
            URLQueryItem(name: "SortBy", value: query.sort == .name ? "SortName" : "DateCreated,SortName"),
            URLQueryItem(name: "SortOrder", value: query.sort == .name ? order : "\(order),Ascending"),
            URLQueryItem(name: "StartIndex", value: "\(page.offset)"),
            URLQueryItem(name: "Limit", value: "\(page.limit)"),
            URLQueryItem(name: "EnableTotalRecordCount", value: "true"),
            // `PremiereDate` is not a default field.
            URLQueryItem(name: "Fields", value: "DateCreated,PremiereDate,PrimaryImageAspectRatio,Path,Width,Height")
        ]
        if query.favoritesOnly { items.append(URLQueryItem(name: "Filters", value: "IsFavorite")) }
        if let days = query.days() {
            items.append(URLQueryItem(name: "MinPremiereDate", value: "\(days.first)T00:00:00Z"))
            items.append(URLQueryItem(name: "MaxPremiereDate", value: "\(days.last)T23:59:59Z"))
        }
        return items
    }

    /// `Years` is scoped by `ParentId` and type (4.10.2).
    func photoYears(in library: MediaLibrary) async throws -> [Int] {
        let result: EmbyNamedResult = try await client.get("Years", [
            URLQueryItem(name: "ParentId", value: library.id),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Photo")
        ])
        return (result.items ?? []).compactMap { $0.name.flatMap { Int($0) } }
    }

    func setPhotoFavorite(_ favorite: Bool, for ref: MediaItemRef) async throws {
        try await setFavorite(favorite, for: ref)
    }

    func photoPage(in library: MediaLibrary, folder: MediaItemRef?, query: PhotoQuery, page: Page) async throws -> PhotoPage {
        let parent = URLQueryItem(name: "ParentId", value: folder?.itemID ?? library.id)
        func map(_ result: EmbyQueryResult?) -> [PhotoItem] {
            (result?.items ?? []).compactMap { EmbyPhotoMapper.item($0, providerID: id, baseURL: baseURL) }
        }

        async let folderList = photoFolders(parent, query: query, page: page)
        let media: EmbyQueryResult = try await client.get(itemsPath, [parent] + Self.photoQueryItems(query, folder: folder, page: page))
        let next = Page(offset: page.offset + page.limit, limit: page.limit)
        return PhotoPage(folders: map(try await folderList).filter { $0.kind == .folder },
                         media: map(media).filter { $0.kind != .folder },
                         nextPage: next.offset < (media.totalRecordCount ?? 0) ? next : nil)
    }
}
