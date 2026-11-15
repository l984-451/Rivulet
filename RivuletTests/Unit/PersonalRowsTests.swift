// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PersonalRowsTests.swift
//  RivuletTests
//
//  The favorites and playlist rows both apps fetch: which libraries ask, the per-profile
//  settings, and what stays when a fetch fails.
//

import XCTest
@testable import Rivulet

final class PersonalRowsTests: XCTestCase {

    private let userIdKey = "selectedPlexUserId"
    private let profileA = 987_654_321
    private let profileB = 987_654_322
    private var savedUserId: Any?

    override func setUp() {
        super.setUp()
        savedUserId = UserDefaults.standard.object(forKey: userIdKey)
        removeKeys()
        UserDefaults.standard.set(profileA, forKey: userIdKey)
    }

    override func tearDown() {
        removeKeys()
        if let savedUserId {
            UserDefaults.standard.set(savedUserId, forKey: userIdKey)
        } else {
            UserDefaults.standard.removeObject(forKey: userIdKey)
        }
        super.tearDown()
    }

    private func removeKeys() {
        for profile in [profileA, profileB] {
            for base in ["showHomeFavoriteMovies", "showHomeFavoriteShows", "hiddenHomeRowIdentifiers", "homeRowOrder"] {
                UserDefaults.standard.removeObject(forKey: "\(base)_user_\(profile)")
            }
        }
    }

    private func library(_ id: String, _ kind: MediaLibrary.LibraryKind, provider: String) -> MediaLibrary {
        MediaLibrary(id: id, providerID: provider, title: id, kind: kind)
    }

    func test_favoritesSettings_arePerProfile_andOffByDefault() {
        XCTAssertFalse(PersonalRows.showsFavorites(.movies))
        PersonalRows.setShowsFavorites(true, .movies)
        XCTAssertTrue(PersonalRows.showsFavorites(.movies))
        XCTAssertFalse(PersonalRows.showsFavorites(.shows))
        UserDefaults.standard.set(profileB, forKey: userIdKey)
        XCTAssertFalse(PersonalRows.showsFavorites(.movies))
    }

    func test_hiddenRowsAndOrder_arePerProfile() {
        HomeRowSettings.setHidden(true, for: "movie.recentlyadded.1")
        HomeRowOrder.placeLast("x", among: ["a", "b"])
        XCTAssertTrue(HomeRowSettings.isHidden("movie.recentlyadded.1"))
        XCTAssertEqual(HomeRowOrder.savedKeys, ["a", "b"])
        UserDefaults.standard.set(profileB, forKey: userIdKey)
        XCTAssertFalse(HomeRowSettings.isHidden("movie.recentlyadded.1"))
        XCTAssertEqual(HomeRowOrder.savedKeys, [])
    }

    /// One request per server and kind, from every library of that kind, on servers with favorites.
    func test_requests_groupLibrariesPerServerAndKind() {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        let jf = StubMediaProvider(id: "jellyfin:s", kind: .jellyfin)
        jf.favoritesSupported = true
        plex.favoritesSupported = true
        let none = StubMediaProvider(id: "emby:x", kind: .emby)
        let requests = PersonalRows.requests(
            libraries: [(plex, library("1", .movies, provider: "plex:a"), "1"),
                        (plex, library("2", .movies, provider: "plex:a"), "2"),
                        (plex, library("3", .shows, provider: "plex:a"), "3"),
                        (jf, library("m", .movies, provider: "jellyfin:s"), "jellyfin:s/m"),
                        (none, library("e", .movies, provider: "emby:x"), "emby:x/e")],
            kinds: [.movies])
        XCTAssertEqual(requests.map(\.provider.id), ["plex:a", "jellyfin:s"])
        XCTAssertEqual(requests[0].libraries.map(\.id), ["1", "2"])
        XCTAssertEqual(requests[0].libraryKey, "1", "placed with the first of its libraries")
    }

    func test_keeping_dropsRowsNothingAsksFor() {
        func row(_ identifier: String) -> PersonalRow {
            PersonalRow(id: identifier, providerID: "p", title: "", identifier: identifier, libraryKey: nil, items: [])
        }
        let pin = HomePlaylistPins.Pin(providerID: "p", playlistID: "1", title: "")
        let playlist = PersonalRows.playlistRowID(providerID: "p", playlistID: "1")
        let kept = PersonalRows.keeping([row(PersonalRows.favoritesIdentifier(.movies)),
                                         row(PersonalRows.favoritesIdentifier(.shows)), row(playlist), row("other")],
                                        kinds: [.shows], pins: [pin])
        XCTAssertEqual(kept.map(\.identifier), [PersonalRows.favoritesIdentifier(.shows), playlist])
    }

    func test_shelfIdentifier_dropsTheSelectedServersPrefixOnly() {
        XCTAssertEqual(HomeRowSettings.identifier(ofShelf: "plex:a|movie.recentlyadded.1", selectedProviderID: "plex:a"),
                       "movie.recentlyadded.1")
        XCTAssertEqual(HomeRowSettings.identifier(ofShelf: "jellyfin:s|m.recentlyAdded", selectedProviderID: "plex:a"),
                       "jellyfin:s|m.recentlyAdded")
        XCTAssertEqual(HomeRowSettings.continueWatchingIdentifiers(hasSelectedPlex: true, otherProviderIDs: ["jellyfin:s"]),
                       ["continueWatching", "jellyfin:s|continueWatching"])
    }
}
