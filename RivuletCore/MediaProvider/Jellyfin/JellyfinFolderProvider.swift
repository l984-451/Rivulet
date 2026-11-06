// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
// JellyfinFolderProvider.swift
// Rivulet
//
// Jellyfin folder browsing. Measured on 12.1: `Items?parentId=` walks the disk
// tree; a folder holding only pictures comes back as PhotoAlbum.
//

import Foundation

enum JellyfinFolderMapper {
    static func entry(_ dto: JFItem, providerID: String, baseURL: URL) -> FolderEntry? {
        guard let itemID = dto.id else { return nil }
        let ref = MediaItemRef(providerID: providerID, itemID: itemID)
        let title = dto.name ?? ""
        switch dto.type {
        case "Folder", "PhotoAlbum", "Series", "Season", "BoxSet":
            return FolderEntry(id: ref, title: title, content: .folder(ref, childCount: dto.childCount))
        case "Photo":
            return JellyfinPhotoMapper.item(dto, providerID: providerID, baseURL: baseURL)
                .map { FolderEntry(id: ref, title: title, content: .photo($0)) }
        case "Video", "Movie", "Episode", "MusicVideo":
            return FolderEntry(id: ref, title: title,
                               content: .video(JellyfinMediaMapper.item(dto, providerID: providerID, baseURL: baseURL)))
        default:
            return nil
        }
    }
}

extension JellyfinProvider: FolderProvider {
    func folderPage(in library: MediaLibrary, folder: MediaItemRef?, page: Page) async throws -> FolderPage {
        let result: JFQueryResult = try await client.get("Items", [
            URLQueryItem(name: "parentId", value: folder?.itemID ?? library.id),
            URLQueryItem(name: "fields", value: "Path,ChildCount,RecursiveItemCount,DateCreated,MediaSourceCount"),
            URLQueryItem(name: "sortBy", value: "IsFolder,SortName"),
            URLQueryItem(name: "sortOrder", value: "Descending,Ascending"),
            URLQueryItem(name: "startIndex", value: "\(page.offset)"),
            URLQueryItem(name: "limit", value: "\(page.limit)"),
            URLQueryItem(name: "enableTotalRecordCount", value: "true")
        ])
        let next = Page(offset: page.offset + page.limit, limit: page.limit)
        return FolderPage(
            entries: (result.items ?? []).compactMap {
                JellyfinFolderMapper.entry($0, providerID: id, baseURL: client.baseURL)
            },
            nextPage: next.offset < (result.totalRecordCount ?? 0) ? next : nil)
    }
}
