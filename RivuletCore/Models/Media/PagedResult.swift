// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PagedResult.swift
//  Rivulet
//
//  Pagination primitives for provider browse methods.
//

import Foundation

nonisolated struct Page: Sendable, Hashable, Codable {
    let offset: Int
    let limit: Int
    let cursor: String?

    init(offset: Int, limit: Int, cursor: String? = nil) {
        self.offset = offset
        self.limit = limit
        self.cursor = cursor
    }
}

struct PagedResult<T: Sendable>: Sendable {
    let items: [T]
    let total: Int
    let nextPage: Page?
}

enum SortOption: Sendable, Hashable, Codable {
    case titleAsc
    case titleDesc
    case releaseDateDesc
    case releaseDateAsc
    case addedAtDesc
    case addedAtAsc
    case ratingDesc
    /// TV libraries: shows by their newest episode.
    case lastContentAddedDesc
}
