// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
// PlexFolderProvider.swift
// Rivulet
//
// Plex folder browsing. Measured on PMS 1.43.4: `/library/sections/<id>/folder`
// rows for folders carry only `key` and `title`, with no ratingKey.
//

import Foundation

enum PlexFolderMapper {
    static func entries(_ rows: [PlexMetadata], providerID: String, serverURL: String, authToken: String) -> [FolderEntry] {
        rows.compactMap { row in
            let title = row.title ?? ""
            // No ratingKey means a folder; its id is the `parent` in its key.
            guard let ratingKey = row.ratingKey else {
                guard let key = row.key,
                      let parent = URLComponents(string: key)?.queryItems?.first(where: { $0.name == "parent" })?.value
                else { return nil }
                let ref = MediaItemRef(providerID: providerID, itemID: parent)
                return FolderEntry(id: ref, title: title, content: .folder(ref, childCount: nil))
            }
            let ref = MediaItemRef(providerID: providerID, itemID: ratingKey)
            if row.type == "photo" {
                guard let photo = PlexPhotoMapper.item(row, providerID: providerID, serverURL: serverURL, authToken: authToken),
                      photo.kind != .folder else { return nil }
                return FolderEntry(id: ref, title: title, content: .photo(photo))
            }
            let video = PlexMediaMapper.item(row, providerID: providerID, serverURL: serverURL, authToken: authToken)
            return FolderEntry(id: ref, title: title, content: .video(video))
        }
    }
}

extension PlexProvider: FolderProvider {
    func folderPage(in library: MediaLibrary, folder: MediaItemRef?, page: Page) async throws -> FolderPage {
        try await plexCall {
            let result = try await networkManager.getFolder(
                serverURL: serverURL, authToken: authToken, sectionId: library.id,
                parent: folder?.itemID, start: page.offset, size: page.limit)
            let next = Page(offset: page.offset + page.limit, limit: page.limit)
            return FolderPage(
                entries: PlexFolderMapper.entries(result.items, providerID: id, serverURL: serverURL, authToken: authToken),
                nextPage: next.offset < (result.totalSize ?? 0) ? next : nil)
        }
    }
}
