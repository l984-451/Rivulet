// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LibraryGUIDIndexTests.swift
//  RivuletTests

import XCTest
@testable import Rivulet

/// The index keeps entries, never full metadata (#409); tests build them from metadata.
func guidIndexEntries(_ items: [PlexMetadata]) -> [LibraryGUIDIndex.Entry] {
    items.compactMap { LibraryGUIDIndex.Entry($0, sectionID: "1") }
}

final class LibraryGUIDIndexTests: XCTestCase {

    func testParsesTMDBImdbTvdbGUIDs() async {
        var item = PlexMetadata(
            ratingKey: "1",
            guid: "plex://movie/abc",
            type: "movie",
            title: "Foo"
        )
        item.Guid = [
            PlexGuid(id: "tmdb://12345"),
            PlexGuid(id: "imdb://tt7654321"),
            PlexGuid(id: "tvdb://999")
        ]

        let index = LibraryGUIDIndex()
        await index.replace(with: guidIndexEntries([item]), completeness: .complete)

        let byTmdb = await index.lookup(tmdbId: 12345, type: .movie)
        XCTAssertEqual(byTmdb?.ratingKey, "1")

        let byTmdbGuid = await index.lookup(guid: "tmdb://12345")
        XCTAssertEqual(byTmdbGuid?.ratingKey, "1")

        let byImdb = await index.lookup(guid: "imdb://tt7654321")
        XCTAssertEqual(byImdb?.ratingKey, "1")

        let byTvdb = await index.lookup(guid: "tvdb://999")
        XCTAssertEqual(byTvdb?.ratingKey, "1")
    }

    func testIgnoresItemsWithoutExternalGUIDs() async {
        let item = PlexMetadata(ratingKey: "1", guid: "plex://movie/abc", type: "movie", title: "Foo")
        let index = LibraryGUIDIndex()
        await index.replace(with: guidIndexEntries([item]), completeness: .complete)

        let result = await index.lookup(tmdbId: 1, type: .movie)
        XCTAssertNil(result)
    }

    func testTypeAwareLookupSegregatesMovieFromTV() async {
        var movie = PlexMetadata(ratingKey: "1", type: "movie", title: "Foo")
        movie.Guid = [PlexGuid(id: "tmdb://100")]

        var show = PlexMetadata(ratingKey: "2", type: "show", title: "Bar")
        show.Guid = [PlexGuid(id: "tmdb://100")]

        let index = LibraryGUIDIndex()
        await index.replace(with: guidIndexEntries([movie, show]), completeness: .complete)

        let movieMatch = await index.lookup(tmdbId: 100, type: .movie)
        XCTAssertEqual(movieMatch?.ratingKey, "1")

        let showMatch = await index.lookup(tmdbId: 100, type: .tv)
        XCTAssertEqual(showMatch?.ratingKey, "2")
    }

    func testReplaceClearsPreviousState() async {
        var item1 = PlexMetadata(ratingKey: "1", type: "movie", title: "A")
        item1.Guid = [PlexGuid(id: "tmdb://1")]

        var item2 = PlexMetadata(ratingKey: "2", type: "movie", title: "B")
        item2.Guid = [PlexGuid(id: "tmdb://2")]

        let index = LibraryGUIDIndex()
        await index.replace(with: guidIndexEntries([item1]), completeness: .complete)
        await index.replace(with: guidIndexEntries([item2]), completeness: .complete)

        let stale = await index.lookup(tmdbId: 1, type: .movie)
        XCTAssertNil(stale)

        let fresh = await index.lookup(tmdbId: 2, type: .movie)
        XCTAssertEqual(fresh?.ratingKey, "2")
    }

    func testPartialBuildStillPopulatesTheInMemoryIndex() async {
        // A partial build is barred from writing the disk cache, but it must
        // still serve lookups for this launch: half the library is a better
        // answer than none while the server is flaky.
        var item = PlexMetadata(ratingKey: "1", type: "movie", title: "Foo")
        item.Guid = [PlexGuid(id: "tmdb://42")]

        let index = LibraryGUIDIndex()
        await index.replace(with: guidIndexEntries([item]), completeness: .partial)

        let match = await index.lookup(tmdbId: 42, type: .movie)
        XCTAssertEqual(match?.ratingKey, "1")
    }

    func testPartialBuildStillBlocksALateDiskHydrate() async {
        // hasFreshData has to be set for partial builds too. If it were not, a
        // hydrateFromDisk() that finished after the network build would replace
        // current-but-partial server data with last launch's disk snapshot.
        var item = PlexMetadata(ratingKey: "1", type: "movie", title: "Foo")
        item.Guid = [PlexGuid(id: "tmdb://42")]

        let index = LibraryGUIDIndex()
        await index.replace(with: guidIndexEntries([item]), completeness: .partial)

        let hydrated = await index.hydrateFromDisk()
        XCTAssertEqual(hydrated, 0, "a late hydrate must be a no-op after any live build")

        let match = await index.lookup(tmdbId: 42, type: .movie)
        XCTAssertEqual(match?.ratingKey, "1")
    }

    func testEveryReplaceBumpsGenerationRegardlessOfCompleteness() async {
        // Consumers such as the trending hero skip recomputation when the
        // generation hasn't moved, so a partial build must still advertise
        // itself as a change.
        var item = PlexMetadata(ratingKey: "1", type: "movie", title: "Foo")
        item.Guid = [PlexGuid(id: "tmdb://42")]

        let index = LibraryGUIDIndex()
        let start = await index.generation

        await index.replace(with: guidIndexEntries([item]), completeness: .complete)
        let afterComplete = await index.generation
        XCTAssertEqual(afterComplete, start + 1)

        await index.replace(with: guidIndexEntries([item]), completeness: .partial)
        let afterPartial = await index.generation
        XCTAssertEqual(afterPartial, start + 2)
    }

    func testIgnoresNonMovieNonShowItems() async {
        var episode = PlexMetadata(ratingKey: "1", type: "episode", title: "Ep1")
        episode.Guid = [PlexGuid(id: "tmdb://500")]

        let index = LibraryGUIDIndex()
        await index.replace(with: guidIndexEntries([episode]), completeness: .complete)

        // Episodes shouldn't be indexed by tmdbId — that index is movie/show only.
        let asMovie = await index.lookup(tmdbId: 500, type: .movie)
        XCTAssertNil(asMovie)

        let asTV = await index.lookup(tmdbId: 500, type: .tv)
        XCTAssertNil(asTV)
    }

    func testUnchangedStampsSkipRebuildButChangedOnesDoNot() async {
        var item = PlexMetadata(ratingKey: "1", type: "movie", title: "Foo")
        item.Guid = [PlexGuid(id: "tmdb://42")]
        let stamps = ["1": "1038/14513/1793061963"]

        let index = LibraryGUIDIndex()
        let emptyIsCurrent = await index.isCurrent(for: stamps)
        XCTAssertFalse(emptyIsCurrent, "an empty index always rebuilds")

        await index.replace(with: guidIndexEntries([item]), completeness: .partial, stamps: stamps)
        let same = await index.isCurrent(for: stamps)
        XCTAssertTrue(same)
        let added = await index.isCurrent(for: ["1": "1039/14513/1793061963"])
        XCTAssertFalse(added, "a new item moves the count")
        let newSection = await index.isCurrent(for: stamps.merging(["2": "10/5/1"]) { a, _ in a })
        XCTAssertFalse(newSection, "a newly visible section has no stamp yet")
    }

    func testSectionStampNeedsATotal() {
        XCTAssertNil(LibraryGUIDIndex.sectionStamp(totalSize: nil, newest: nil))
        let newest = PlexMetadata(ratingKey: "7", type: "movie", title: "X", updatedAt: 99)
        XCTAssertEqual(LibraryGUIDIndex.sectionStamp(totalSize: 3, newest: newest), "3/7/99")
    }
}
