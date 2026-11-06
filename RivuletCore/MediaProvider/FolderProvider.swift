// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
// FolderProvider.swift
// Rivulet
//
// Folder seam. A MediaProvider that can list a library by its on-disk
// folders adopts it by extension, as PhotoProvider does.
//

import Foundation

nonisolated struct FolderEntry: Hashable, Sendable {
    enum Content: Hashable, Sendable {
        case folder(MediaItemRef, childCount: Int?)
        case video(MediaItem)
        case photo(PhotoItem)
    }

    let id: MediaItemRef
    let title: String
    let content: Content
}

nonisolated struct FolderPage: Sendable {
    let entries: [FolderEntry]
    let nextPage: Page?
}

protocol FolderProvider: Sendable {
    /// One page of a library's root (`folder` nil) or a folder: folders first, then files, by name.
    func folderPage(in library: MediaLibrary, folder: MediaItemRef?, page: Page) async throws -> FolderPage
}
