// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexLibraryFilterValues.swift
//  Rivulet
//
//  `/library/sections/{id}/genre` and `/decade`: the values a section's `/all` accepts as
//  `genre=<key>` and `decade=<key>`.
//

import Foundation

nonisolated struct PlexFilterValue: Decodable, Sendable, Equatable {
    let key: String
    let title: String

    private enum CodingKeys: String, CodingKey { case key, title }

    init(key: String, title: String) {
        self.key = key
        self.title = title
    }

    /// Plex sends `key` as a string in most builds; tolerate a number.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? c.decode(String.self, forKey: .key) {
            key = text
        } else {
            key = String(try c.decode(Int.self, forKey: .key))
        }
        title = try c.decode(String.self, forKey: .title)
    }
}

nonisolated struct PlexFilterValueContainer: Decodable, Sendable {
    struct Inner: Decodable, Sendable { let Directory: [PlexFilterValue]? }
    let MediaContainer: Inner
}

extension LibraryFilterOptions {
    /// Plex's genre and decade lists as options. A decade key that is not a number is dropped.
    nonisolated init(plexGenres genres: [PlexFilterValue], decades: [PlexFilterValue]) {
        self.init(
            genres: genres.map { LibraryGenre(id: $0.key, name: $0.title) },
            decades: decades.compactMap { Int($0.key) }.sorted(by: >)
        )
    }
}
