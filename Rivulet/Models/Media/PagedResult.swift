// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PagedResult.swift
//  Rivulet
//
//  Pagination primitives for provider browse methods.
//

import Foundation

struct Page: Sendable, Hashable {
    let offset: Int
    let limit: Int
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
