// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class SidebarArrangementTests: XCTestCase {
    private typealias A = SidebarArrangement

    func test_appRowKeys_areNeverProviderKeys_andKeepTheirServer() {
        let playlists = A.playlists(server: "jellyfin:srv")
        XCTAssertFalse(LibrarySettingsManager.isProviderKey(playlists))
        XCTAssertFalse(LibrarySettingsManager.isProviderKey(A.liveTV(source: "plex:http://pms:32400")))
        XCTAssertTrue(LibrarySettingsManager.isProviderKey("jellyfin:srv/lib-m"))
        XCTAssertEqual(A.server(ofKey: playlists), "jellyfin:srv")
        XCTAssertEqual(A.server(ofKey: A.playlists(server: "")), "")
        XCTAssertEqual(A.server(ofKey: "12"), "")
        XCTAssertEqual(A.server(ofKey: "plex:test/1"), "plex:test")
        XCTAssertNil(A.server(ofKey: A.discover))
        XCTAssertNil(A.server(ofKey: A.liveTV(source: "m3u")))
    }

    func test_seed_keepsTodaysLayout() {
        XCTAssertEqual(A.seed(libraryOrder: ["1", "2"], discoverAbove: true, liveTVAbove: false),
                       [A.discover, A.watchlist, A.favorites, A.librariesAnchor, "1", "2", A.liveTV])
        XCTAssertEqual(A.seed(libraryOrder: ["1"], discoverAbove: false, liveTVAbove: true),
                       [A.watchlist, A.favorites, A.liveTV, A.librariesAnchor, "1", A.discover])
    }

    func test_favorites_joinAnOrderStoredBeforeThem_besideTheWatchlist() {
        let old = [A.discover, A.watchlist, A.librariesAnchor, "1", A.liveTV]
        XCTAssertEqual(A.insert(A.favorites, into: old),
                       [A.discover, A.watchlist, A.favorites, A.librariesAnchor, "1", A.liveTV])
        // The watchlist moved below the libraries: Favorites follow it there.
        let moved = [A.discover, A.librariesAnchor, "1", A.watchlist, A.liveTV]
        XCTAssertEqual(A.insert(A.favorites, into: moved),
                       [A.discover, A.librariesAnchor, "1", A.watchlist, A.favorites, A.liveTV])
        // No watchlist row stored: after Discover, else above the libraries.
        XCTAssertEqual(A.insert(A.favorites, into: [A.discover, A.librariesAnchor, "1"]),
                       [A.discover, A.favorites, A.librariesAnchor, "1"])
        XCTAssertEqual(A.insert(A.favorites, into: [A.librariesAnchor, "1"]),
                       [A.favorites, A.librariesAnchor, "1"])
    }

    func test_newRows_goNextToTheirKin() {
        let order = A.seed(libraryOrder: ["1", "plex:test/1"], discoverAbove: true, liveTVAbove: false)
        // A fresh install's first library goes at the anchor, not after Live TV.
        XCTAssertEqual(A.arrange(["1", A.liveTV], order: A.seed(libraryOrder: [], discoverAbove: true, liveTVAbove: false)),
                       ["1", A.liveTV])
        // A server's playlists after its last library; a new library before them.
        let withPlaylists = A.insert(A.playlists(server: ""), into: order)
        XCTAssertEqual(A.arrange(["1", "2", A.playlists(server: ""), "plex:test/1"], order: withPlaylists),
                       ["1", "2", A.playlists(server: ""), "plex:test/1"])
        // Split Live TV sources follow the combined row's place, in turn.
        XCTAssertEqual(A.arrange([A.discover, "1", A.liveTV(source: "a"), A.liveTV(source: "b")], order: order),
                       [A.discover, "1", A.liveTV(source: "a"), A.liveTV(source: "b")])
    }

    func test_move_staysAmongVisibleRows_andKeepsHiddenOnesInPlace() {
        let order = [A.discover, A.watchlist, A.librariesAnchor, "1", "2", A.liveTV]
        let visible = [A.discover, "1", "2", A.liveTV]   // the watchlist is hidden
        let moved = A.move("1", up: true, visible: visible, order: order)
        XCTAssertEqual(A.arrange(visible, order: moved), ["1", A.discover, "2", A.liveTV])
        XCTAssertTrue(moved.contains(A.watchlist) && moved.contains(A.librariesAnchor))
        XCTAssertEqual(A.move(A.discover, up: true, visible: visible, order: order), order)
        XCTAssertEqual(A.move(A.liveTV, up: false, visible: visible, order: order), order)
    }

    func test_sections_groupedRunsGetTheirServer_mixedGetNone() {
        let grouped = A.sections([A.discover, "1", A.playlists(server: ""), "plex:t/1", A.liveTV])
        XCTAssertTrue(grouped.grouped)
        XCTAssertEqual(grouped.sections.map(\.server), [nil, "", "plex:t", nil])
        XCTAssertEqual(grouped.sections[1].keys, ["1", A.playlists(server: "")])

        // Any row splitting a server's run ends the headers too.
        XCTAssertFalse(A.sections(["1", A.discover, "2"]).grouped)

        let mixed = A.sections([A.discover, "1", "plex:t/1", "2", A.liveTV])
        XCTAssertFalse(mixed.grouped)
        XCTAssertEqual(mixed.sections, [A.Section(server: nil, keys: [A.discover, "1", "plex:t/1", "2", A.liveTV])])
    }
}
