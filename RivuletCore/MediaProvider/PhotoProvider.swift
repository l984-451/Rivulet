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
    /// One page of a library's root (`folder` nil) or of a folder. Folders
    /// may arrive on any page; media is newest first.
    func photoPage(in library: MediaLibrary, folder: MediaItemRef?, page: Page) async throws -> PhotoPage
}
