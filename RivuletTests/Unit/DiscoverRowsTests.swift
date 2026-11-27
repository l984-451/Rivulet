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

    // MARK: - Hero

    private func title(_ id: Int, _ type: TMDBMediaType, backdrop: Bool = true) -> MediaItem {
        TMDBMediaMapper.item(TMDBListItem(id: id, title: "\(type.rawValue) \(id)", overview: nil, posterPath: "/p.jpg",
                                          backdropPath: backdrop ? "/b.jpg" : nil, releaseDate: nil, voteAverage: nil,
                                          mediaType: type))
    }

    private func row(_ section: CuratedSection, _ items: [MediaItem]) -> DiscoverRows.Row {
        DiscoverRows.Row(section: section, items: items)
    }

    func test_heroTakesPopularMoviesAndTVInTurnFromThoseRowsOnly() {
        let rows = [row(.moviePopular, [title(1, .movie), title(2, .movie), title(3, .movie)]),
                    row(.movieTopRated, [title(9, .movie)]),
                    row(.tvPopular, [title(1, .tv)])]
        XCTAssertEqual(DiscoverRows.heroTitles(rows).map(\.title), ["movie 1", "tv 1", "movie 2", "movie 3"])
    }

    func test_heroPutsTitlesWithABackdropFirstAndStopsAtNine() {
        let movies = (1...10).map { title($0, .movie, backdrop: $0 != 1) }
        let shows = (1...10).map { title($0, .tv) }
        let hero = DiscoverRows.heroTitles([row(.moviePopular, movies), row(.tvPopular, shows)])
        XCTAssertEqual(hero.count, 9)
        XCTAssertEqual(hero.map(\.title), ["tv 1", "movie 2", "tv 2", "movie 3", "tv 3", "movie 4", "tv 4", "movie 5", "tv 5"])
        XCTAssertEqual(DiscoverRows.heroTitles([row(.moviePopular, [title(1, .movie, backdrop: false)])]).map(\.title),
                       ["movie 1"], "Without a better title, one with no backdrop still shows")
    }

    func test_heroIsEmptyWithoutItsRows() {
        XCTAssertTrue(DiscoverRows.heroTitles([row(.movieUpcoming, [title(1, .movie)])]).isEmpty)
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
