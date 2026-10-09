// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PersonFilmographyProviderTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

// MARK: - Fixtures

enum PersonFilmographyTestFixtures {
    static func playableItem(title: String, isMovie: Bool) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: "plex:test", itemID: "rk-\(title)"),
            kind: isMovie ? .movie : .show,
            title: title,
            sortTitle: nil,
            overview: nil,
            year: nil,
            runtime: nil,
            parentRef: nil,
            grandparentRef: nil,
            episodeNumber: nil,
            seasonNumber: nil,
            childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil,
            grandparentArtwork: nil
        )
    }
}

// MARK: - Tests

final class PersonFilmographyProviderTests: XCTestCase {
    /// Cross-section filmography: movies AND shows both surface and bucket by
    /// kind. This is the regression guard for "only the Movies row loaded" —
    /// the server lookup returns titles from every library, not just origin.
    /// The portrait is the Plex thumb (never TMDB), so it never swaps after load.
    func test_filmographyBucketsMoviesAndShowsAndTmdbBio() async throws {
        let provider = PersonFilmographyProvider(
            serverFilmographyItems: { _ in
                [FilmographyEntry(item: PersonFilmographyTestFixtures.playableItem(title: "OnServerMovie", isMovie: true), isOnServer: true),
                 FilmographyEntry(item: PersonFilmographyTestFixtures.playableItem(title: "OnServerShow", isMovie: false), isOnServer: true)]
            },
            biography: { _ in "A bio." },
            knownFor: { _ in [] })
        let plexThumb = URL(string: "https://plex/role.jpg")
        let person = MediaPerson(id: "p", name: "Keanu Reeves", role: nil, imageURL: plexThumb,
                                 originActorId: "49",
                                 titleTmdbId: 123, titleIsMovie: true)
        let detail = try await provider.load(person: person)
        XCTAssertEqual(detail.movies.map(\.item.title), ["OnServerMovie"])
        XCTAssertEqual(detail.shows.map(\.item.title), ["OnServerShow"])
        XCTAssertTrue(detail.movies.allSatisfy(\.isOnServer))
        XCTAssertTrue(detail.shows.allSatisfy(\.isOnServer))
        XCTAssertEqual(detail.biography, "A bio.")
        // Portrait is always the Plex thumb — never a TMDB image.
        XCTAssertEqual(detail.portraitURL, plexThumb)
    }

    func test_emptyFilmographyWhenServerReturnsNone() async throws {
        let provider = PersonFilmographyProvider(
            serverFilmographyItems: { _ in [] },
            biography: { _ in nil },
            knownFor: { _ in [] })
        let person = MediaPerson(id: "p", name: "Nobody", role: nil, imageURL: URL(string: "https://x/p.jpg"))
        let detail = try await provider.load(person: person)
        XCTAssertTrue(detail.movies.isEmpty)
        XCTAssertTrue(detail.shows.isEmpty)
        XCTAssertNil(detail.biography)
    }

    /// Known For drops titles already on the server, matched by plex guid or by
    /// TMDB id within the same kind (movie and TV TMDB ids collide).
    func test_knownForExcludesOnServerTitles() {
        func entry(_ title: String, _ isMovie: Bool, guid: String?, tmdb: Int?, onServer: Bool) -> FilmographyEntry {
            FilmographyEntry(item: PersonFilmographyTestFixtures.playableItem(title: title, isMovie: isMovie),
                             isOnServer: onServer, guid: guid, tmdbId: tmdb)
        }
        let server = [entry("ServerByGuid", true, guid: "plex://movie/a", tmdb: nil, onServer: true),
                      entry("ServerByTmdb", true, guid: nil, tmdb: 7, onServer: true)]
        let knownFor = [entry("SameGuid", true, guid: "plex://movie/a", tmdb: 1, onServer: false),
                        entry("SameTmdbMovie", true, guid: "plex://movie/b", tmdb: 7, onServer: false),
                        entry("SameTmdbShow", false, guid: "plex://show/c", tmdb: 7, onServer: false),
                        entry("Elsewhere", true, guid: "plex://movie/d", tmdb: 9, onServer: false)]
        XCTAssertEqual(FilmographyEntry.excluding(server, from: knownFor).map(\.item.title),
                       ["SameTmdbShow", "Elsewhere"])
    }

    /// The server rows must not wait on Discover: load() never calls Known For.
    func test_loadDoesNotWaitForKnownFor() async throws {
        let provider = PersonFilmographyProvider(
            serverFilmographyItems: { _ in [] },
            biography: { _ in nil },
            knownFor: { _ in
                try? await Task.sleep(for: .seconds(30))
                return []
            })
        let start = ContinuousClock.now
        _ = try await provider.load(person: MediaPerson(id: "p", name: "X", role: nil, imageURL: nil))
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
    }

    func test_portraitIsAlwaysPlexThumb() async throws {
        let provider = PersonFilmographyProvider(
            serverFilmographyItems: { _ in [] },
            biography: { _ in nil },
            knownFor: { _ in [] })
        let thumb = URL(string: "https://plex/role.jpg")
        let person = MediaPerson(id: "p", name: "X", role: nil, imageURL: thumb,
                                 originActorId: "1")
        let detail = try await provider.load(person: person)
        XCTAssertNil(detail.biography)
        XCTAssertEqual(detail.portraitURL, thumb)
    }
}
