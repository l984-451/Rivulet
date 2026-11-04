// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
// EmbyFolderProvider.swift
// Rivulet
//
// Emby folder browsing. Measured on 4.10.2: `Items?ParentId=` walks the disk tree, and the
// library id lists the physical root's children directly.
//

import Foundation

enum EmbyFolderMapper {
    static func entry(_ dto: EmbyItem, providerID: String, baseURL: URL) -> FolderEntry? {
        let ref = MediaItemRef(providerID: providerID, itemID: dto.id.value)
        switch dto.type {
        case "Folder", "PhotoAlbum", "Series", "Season", "BoxSet":
            return FolderEntry(id: ref, title: dto.name, content: .folder(ref, childCount: dto.childCount))
        case "Photo":
            return EmbyPhotoMapper.item(dto, providerID: providerID, baseURL: baseURL)
                .map { FolderEntry(id: ref, title: dto.name, content: .photo($0)) }
        case "Video", "Movie", "Episode", "MusicVideo":
            return FolderEntry(id: ref, title: dto.name,
                               content: .video(EmbyMediaMapper.item(dto, providerID: providerID, baseURL: baseURL)))
        default:
            return nil
        }
    }
}

extension EmbyProvider: FolderProvider {
    /// Folders first is `IsFolder` ascending on Emby (descending puts them last, the reverse of
    /// Jellyfin), and ties are not broken by name, so `SortName` follows. `Filters=IsFolder` is
    /// never combined with `IncludeItemTypes`: that returned the whole library.
    func folderPage(in library: MediaLibrary, folder: MediaItemRef?, page: Page) async throws -> FolderPage {
        let result: EmbyQueryResult = try await client.get(itemsPath, [
            URLQueryItem(name: "ParentId", value: folder?.itemID ?? library.id),
            Self.listFields,
            URLQueryItem(name: "SortBy", value: "IsFolder,SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending,Ascending"),
            URLQueryItem(name: "StartIndex", value: "\(page.offset)"),
            URLQueryItem(name: "Limit", value: "\(page.limit)"),
            URLQueryItem(name: "EnableTotalRecordCount", value: "true")
        ])
        let next = Page(offset: page.offset + page.limit, limit: page.limit)
        return FolderPage(
            entries: (result.items ?? []).compactMap { EmbyFolderMapper.entry($0, providerID: id, baseURL: baseURL) },
            nextPage: next.offset < (result.totalRecordCount ?? 0) ? next : nil)
    }
}
