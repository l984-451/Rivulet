// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LibraryAlphabetIndex.swift
//  Rivulet
//
//  Per-letter item counts for a library section, and the letter → grid
//  offset table the alphabet bar jumps by.
//

import Foundation

/// One `Directory` entry from `/library/sections/{id}/firstCharacter`: how
/// many items in the section have a sort title starting with `title`
/// ("#" for digits and symbols, then the letters the library contains).
nonisolated struct PlexFirstCharacter: Decodable, Sendable, Equatable {
    let title: String
    let size: Int

    init(title: String, size: Int) {
        self.title = title
        self.size = size
    }

    private enum CodingKeys: String, CodingKey { case title, size }

    /// `size` is a number in PMS JSON, but it is an attribute string in the
    /// XML this container mirrors, so accept either rather than lose the bar
    /// to a server that emits the string form.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        if let n = try? c.decode(Int.self, forKey: .size) {
            size = n
        } else {
            size = Int(try c.decode(String.self, forKey: .size)) ?? 0
        }
    }
}

nonisolated struct PlexFirstCharacterContainer: Decodable, Sendable {
    let MediaContainer: PlexFirstCharacterMediaContainer
}

nonisolated struct PlexFirstCharacterMediaContainer: Decodable, Sendable {
    let Directory: [PlexFirstCharacter]?
}

/// Letter → grid offset table for the library alphabet bar. Plex lists the
/// characters in title-sort order with a count each, so a letter's offset in
/// a `titleSort:asc` grid is the sum of the counts before it; a descending
/// grid walks the same list backwards. Empty characters are dropped so every
/// letter shown has something under it.
nonisolated struct LibraryAlphabetIndex: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let title: String
        let offset: Int
    }

    let entries: [Entry]

    init(characters: [PlexFirstCharacter], descending: Bool) {
        let ordered = descending ? Array(characters.reversed()) : characters
        var offset = 0
        var entries: [Entry] = []
        for character in ordered where character.size > 0 {
            entries.append(Entry(title: character.title, offset: offset))
            offset += character.size
        }
        self.entries = entries
    }

    /// The entry whose run of titles contains grid slot `slot`: the last
    /// entry whose offset is at or before it.
    func entryIndex(containing slot: Int) -> Int? {
        entries.lastIndex(where: { $0.offset <= slot })
    }
}
