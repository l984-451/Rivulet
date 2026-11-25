// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class DiscoverRowsTests: XCTestCase {
    private func item(_ title: String) -> MediaItem {
        PersonFilmographyTestFixtures.playableItem(title: title, isMovie: true)
    }

    func test_keepsSectionOrderAndDropsFailedAndEmptyRows() async {
        let source = StubCatalog()
        source.items = [.tvTopRated: [item("C")], .moviePopular: [item("A")], .tvPopular: [item("B")]]
        source.failing = [.movieNowPlaying]
        let discover = DiscoverRows(source: source)
        await discover.load()
        XCTAssertEqual(discover.rows.map(\.section), [.moviePopular, .tvPopular, .tvTopRated])
        XCTAssertEqual(discover.rows.map { $0.items.map(\.title) }, [["A"], ["B"], ["C"]])
        XCTAssertFalse(discover.failed)
    }

    func test_flagsEverythingFailedThenRecoversOnReload() async {
        let source = StubCatalog()
        source.failing = Set(CuratedSection.allCases)
        let discover = DiscoverRows(source: source)
        XCTAssertFalse(discover.failed, "Not loaded yet is not failed")
        await discover.load()
        XCTAssertTrue(discover.rows.isEmpty)
        XCTAssertTrue(discover.failed)

        source.failing = []
        source.items = [.movieUpcoming: [item("D")]]
        await discover.load()
        XCTAssertEqual(discover.rows.map(\.section), [.movieUpcoming])
        XCTAssertFalse(discover.failed)
    }

    func test_noSourceIsFailed() async {
        let discover = DiscoverRows(source: nil)
        await discover.load()
        XCTAssertTrue(discover.failed)
    }
}

/// Answers each section from a table; a section in `failing` throws.
private final class StubCatalog: MetadataSource, @unchecked Sendable {
    var items: [CuratedSection: [MediaItem]] = [:]
    var failing: Set<CuratedSection> = []

    func curatedSection(_ section: CuratedSection) async throws -> [MediaItem] {
        if failing.contains(section) { throw MediaProviderError.unreachable }
        return items[section] ?? []
    }

    func itemDetail(_ ref: MediaItemRef) async throws -> MediaItemDetail { throw MediaProviderError.notFound }
    func search(_ query: String) async throws -> [MediaItem] { [] }
    func recommendations(for ref: MediaItemRef) async throws -> [MediaItem] { [] }
}
