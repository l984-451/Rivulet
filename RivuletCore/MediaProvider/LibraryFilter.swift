// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LibraryFilter.swift
//  Rivulet
//
//  What a video library page can narrow its Titles grid by: genre, decade
//  and unwatched. Session state per library; every provider maps it onto its
//  own query.
//

import Foundation

struct LibraryGenre: Hashable, Sendable {
    /// The provider's own genre id (Plex tag id, Jellyfin and Emby item id).
    let id: String
    let name: String
}

struct LibraryFilter: Equatable, Sendable {
    var genre: LibraryGenre?
    /// First year of the decade, e.g. 1990.
    var decade: Int?
    var unwatchedOnly = false

    static let none = LibraryFilter()

    var isActive: Bool { genre != nil || decade != nil || unwatchedOnly }

    /// Every year of the decade, for servers that filter by a year list.
    var decadeYears: [Int] { decade.map { Array($0..<($0 + 10)) } ?? [] }

    static func decadeTitle(_ decade: Int) -> String { "\(decade)s" }
}

struct LibraryFilterOptions: Equatable, Sendable {
    var genres: [LibraryGenre] = []
    /// Decades present, newest first.
    var decades: [Int] = []

    static func decades(fromYears years: [Int]) -> [Int] {
        Array(Set(years.filter { $0 > 0 }.map { $0 / 10 * 10 })).sorted(by: >)
    }
}
