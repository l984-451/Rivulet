// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LibraryCollectionsRowTests.swift
//  RivuletTests
//
//  Where a library page puts its Collections row among its hub rows. Row
//  flags mirror the hub orders measured on PMS 1.43.4 (Movies: inprogress,
//  recentlyreleased, recentlyadded, genre...). An admin can reorder hubs in
//  Plex's Manage Recommendations, and a promotion adds a custom.collection
//  hub, so a discovery row can come before Continue Watching.
//

import XCTest
@testable import Rivulet

final class LibraryCollectionsRowTests: XCTestCase {
    private typealias Row = (isContinueWatching: Bool, isRecent: Bool)
    private let cw: Row = (isContinueWatching: true, isRecent: false)
    private let recent: Row = (isContinueWatching: false, isRecent: true)
    private let other: Row = (isContinueWatching: false, isRecent: false)

    private func index(_ rows: [Row]) -> Int {
        PlexHomeViewController.collectionsRowInsertionIndex(rows: rows)
    }

    /// Measured Movies order: the row follows Recently Added.
    func test_measuredOrder_followsLastRecentRow() {
        XCTAssertEqual(index([cw, recent, recent, other]), 3)
    }

    func test_onlyDiscoveryRows_goesFirst() {
        XCTAssertEqual(index([other]), 0)
    }

    func test_essentialRowsOnly_goesLast() {
        XCTAssertEqual(index([cw, recent]), 2)
    }

    func test_noHubRows_goesFirst() {
        XCTAssertEqual(index([]), 0)
    }

    /// Recent Rows off: the gate drops the recent rows before this runs.
    func test_recentRowsOff_followsContinueWatching() {
        XCTAssertEqual(index([cw, other]), 1)
    }

    /// A genre hub moved above Continue Watching must not drag the row up.
    func test_discoveryRowAboveContinueWatching_stillFollowsRecentRow() {
        XCTAssertEqual(index([other, cw, recent]), 3)
    }

    /// A promoted custom.collection hub ahead of Continue Watching.
    func test_promotedCollectionHubFirst_stillFollowsRecentRow() {
        XCTAssertEqual(index([other, cw, recent, other]), 3)
    }

    /// Identifiers and German titles measured on PMS 1.43.4.
    func test_recentRows_matchWhenPlexTranslatesTheTitle() {
        func isRecent(_ id: String, _ title: String) -> Bool {
            PlexHomeViewController.isRecentRow(CachedHomeHub(id: id, title: title, isContinueWatching: false, hubIdentifier: id, items: []))
        }
        XCTAssertTrue(isRecent("tv.recentlyaired.2", "Kürzlich veröffentlichte Folgen"))
        XCTAssertTrue(isRecent("tv.recentlyadded.2", "Zuletzt in TV Shows hinzugefügt"))
        XCTAssertTrue(isRecent("movie.recentlyreleased.1", "Zuletzt veröffentlichte Filme"))
        XCTAssertFalse(isRecent("tv.recentlyviewed.2", "Kürzlich gesehene Folgen"))
        XCTAssertFalse(isRecent("movie.topunwatched.1", "Top-Auswahl ungesehener Filme"))
    }

    func test_heroFallback_recognisesRecentlyAddedInAnyLanguage() {
        func isAdded(_ id: String, _ title: String) -> Bool {
            var hub = PlexHub(hubIdentifier: id)
            hub.title = title
            return PlexHomeViewController.isRecentlyAdded(hub)
        }
        XCTAssertTrue(isAdded("home.movies.recent", "Zuletzt hinzugefügte Filme"))
        XCTAssertTrue(isAdded("movie.recentlyadded.1", "Zuletzt in Movies hinzugefügt"))
        XCTAssertFalse(isAdded("home.continue", "Fortsetzen"))
        XCTAssertFalse(isAdded("music.recent.played.3", "Kürzlich gespielte Musik"))
    }
}
