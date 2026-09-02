// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LibraryAlphabetIndexTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class LibraryAlphabetIndexTests: XCTestCase {
    private let characters = [
        PlexFirstCharacter(title: "#", size: 3),
        PlexFirstCharacter(title: "A", size: 10),
        PlexFirstCharacter(title: "B", size: 0),
        PlexFirstCharacter(title: "C", size: 5)
    ]

    func test_ascending_offsetsArePrefixSums_andEmptyLettersDrop() {
        let index = LibraryAlphabetIndex(characters: characters, descending: false)
        XCTAssertEqual(index.entries.map(\.title), ["#", "A", "C"])
        XCTAssertEqual(index.entries.map(\.offset), [0, 3, 13])
    }

    func test_descending_walksTheListBackwards() {
        let index = LibraryAlphabetIndex(characters: characters, descending: true)
        XCTAssertEqual(index.entries.map(\.title), ["C", "A", "#"])
        XCTAssertEqual(index.entries.map(\.offset), [0, 5, 15])
    }

    func test_entryIndex_isTheLetterCoveringTheSlot() {
        let index = LibraryAlphabetIndex(characters: characters, descending: false)
        XCTAssertEqual(index.entryIndex(containing: 0), 0)   // "#" run: 0..<3
        XCTAssertEqual(index.entryIndex(containing: 12), 1)  // "A" run: 3..<13
        XCTAssertEqual(index.entryIndex(containing: 13), 2)  // "C" run: 13...
        XCTAssertNil(LibraryAlphabetIndex(characters: [], descending: false).entryIndex(containing: 0))
    }

    func test_decode_acceptsNumericAndStringSize() throws {
        let json = #"{"MediaContainer":{"size":2,"Directory":[{"key":"A","title":"A","size":4},{"key":"B","title":"B","size":"7"}]}}"#
        let container = try JSONDecoder().decode(PlexFirstCharacterContainer.self, from: Data(json.utf8))
        XCTAssertEqual(container.MediaContainer.Directory?.map(\.size), [4, 7])
    }
}
