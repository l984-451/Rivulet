// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HomeCollectionPinsTests.swift
//  RivuletTests
//
//  Collections pinned to Home in Rivulet (P2 of the collections spec).
//
//  The store is JSON in UserDefaults under a per-profile key, so these tests
//  point `selectedPlexUserId` at throwaway ids and restore it afterwards. The
//  projection's per-pin decision is a pure static because `PlexDataStore` is a
//  private-init singleton (the constraint `HomePromotedHubRowsTests`
//  documents).
//
//  Rating keys and titles come from the home PMS 1.43.4: James Bond is
//  collection 9144 in Movies, Dr. No (55929) is its first member, Newly
//  Released is 118573. The library uuids are fake on purpose: the test host is
//  the app, its `PlexDataStore` reacts to `changedNotification`, and a real
//  uuid would make a signed-in simulator fetch and draw the test pins.
//

import XCTest
@testable import Rivulet

@MainActor
final class HomeCollectionPinsTests: XCTestCase {

    private typealias Pin = HomeCollectionPins.Pin

    private let userIdKey = "selectedPlexUserId"
    private let profileA = 987_654_321
    private let profileB = 987_654_322
    private var savedUserId: Any?

    private let movies = "test-library-movies"
    private let tv = "test-library-tv"

    private var bond: Pin { Pin(ratingKey: "9144", libraryUUID: movies, title: "James Bond") }
    private var newlyReleased: Pin { Pin(ratingKey: "118573", libraryUUID: movies, title: "Newly Released") }
    private let members = [PlexMetadata(ratingKey: "55929", title: "Dr. No")]

    override func setUp() {
        super.setUp()
        savedUserId = UserDefaults.standard.object(forKey: userIdKey)
        removeTestPins()
        UserDefaults.standard.set(profileA, forKey: userIdKey)
    }

    override func tearDown() {
        removeTestPins()
        if let savedUserId {
            UserDefaults.standard.set(savedUserId, forKey: userIdKey)
        } else {
            UserDefaults.standard.removeObject(forKey: userIdKey)
        }
        super.tearDown()
    }

    private func removeTestPins() {
        for profile in [profileA, profileB] {
            UserDefaults.standard.removeObject(forKey: "homeCollectionPins_user_\(profile)")
            UserDefaults.standard.removeObject(forKey: "libraryCollectionPins_user_\(profile)")
        }
    }

    // MARK: - Derived keys

    func test_derivedKeys() {
        XCTAssertEqual(bond.id, "test-library-movies/9144")
        XCTAssertEqual(bond.rowIdentifier, "rivulet.pin.collection.9144")
        XCTAssertEqual(bond.childrenKey, "/library/collections/9144/children")
        XCTAssertFalse(PlexDataStore.isContinueWatchingFamily(hubIdentifier: bond.rowIdentifier),
                       "a pin row must never get the Continue Watching resume tiles")
    }

    // MARK: - Persistence

    func test_pins_roundTripInPinOrder() throws {
        XCTAssertEqual(HomeCollectionPins.pins, [])
        HomeCollectionPins.pin(bond)
        HomeCollectionPins.pin(newlyReleased)
        XCTAssertEqual(HomeCollectionPins.pins, [bond, newlyReleased])

        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: "homeCollectionPins_user_\(profileA)"),
                                 "stored under the profile-suffixed key")
        XCTAssertEqual(try JSONDecoder().decode([Pin].self, from: data), [bond, newlyReleased],
                       "stored as a JSON array")
    }

    func test_pin_twiceKeepsOneEntry() {
        HomeCollectionPins.pin(bond)
        HomeCollectionPins.pin(bond)
        XCTAssertEqual(HomeCollectionPins.pins, [bond])
    }

    func test_isPinned_matchesRatingKeyAndLibrary() {
        HomeCollectionPins.pin(bond)
        XCTAssertTrue(HomeCollectionPins.isPinned(ratingKey: "9144", libraryUUID: movies))
        XCTAssertFalse(HomeCollectionPins.isPinned(ratingKey: "9144", libraryUUID: tv),
                       "the same ratingKey in another library is a different pin")
        XCTAssertFalse(HomeCollectionPins.isPinned(ratingKey: "118573", libraryUUID: movies))
    }

    func test_unpin_removesOnlyThatPinAndIsIdempotent() {
        HomeCollectionPins.pin(bond)
        HomeCollectionPins.pin(newlyReleased)
        HomeCollectionPins.unpin(ratingKey: "9144", libraryUUID: movies)
        XCTAssertEqual(HomeCollectionPins.pins, [newlyReleased])

        // Two pin loaders can both see the same 404; the second unpin must not
        // post again and start another fetch round.
        let posted = expectation(forNotification: HomeCollectionPins.changedNotification, object: nil)
        posted.isInverted = true
        HomeCollectionPins.unpin(ratingKey: "9144", libraryUUID: movies)
        wait(for: [posted], timeout: 0.2)
    }

    /// Settings' hold-Select reorder: one slot per call, and a move off
    /// either end writes and posts nothing.
    func test_move_swapsOneSlotAndStopsAtTheEnds() {
        let spy = Pin(ratingKey: "1", libraryUUID: movies, title: "Spy")
        HomeCollectionPins.pin(bond)
        HomeCollectionPins.pin(newlyReleased)
        HomeCollectionPins.pin(spy)

        HomeCollectionPins.move(spy, up: true)
        XCTAssertEqual(HomeCollectionPins.pins, [bond, spy, newlyReleased])
        HomeCollectionPins.move(spy, up: false)
        XCTAssertEqual(HomeCollectionPins.pins, [bond, newlyReleased, spy])

        let posted = expectation(forNotification: HomeCollectionPins.changedNotification, object: nil)
        posted.isInverted = true
        HomeCollectionPins.move(bond, up: true)
        HomeCollectionPins.move(spy, up: false)
        wait(for: [posted], timeout: 0.1)
        XCTAssertEqual(HomeCollectionPins.pins, [bond, newlyReleased, spy])
    }

    // MARK: - Library pins

    /// One collection can be a Home row, a library row, or both: the two
    /// lists are stored apart and an action on one never touches the other.
    func test_libraryPins_areStoredApartFromHomePins() {
        HomeCollectionPins.pin(bond, in: .library)
        XCTAssertEqual(HomeCollectionPins.pins(in: .library), [bond])
        XCTAssertEqual(HomeCollectionPins.pins, [], "a library pin is not a Home pin")
        XCTAssertTrue(HomeCollectionPins.isPinned(ratingKey: "9144", libraryUUID: movies, in: .library))
        XCTAssertFalse(HomeCollectionPins.isPinned(ratingKey: "9144", libraryUUID: movies))

        HomeCollectionPins.pin(bond)
        HomeCollectionPins.unpin(ratingKey: "9144", libraryUUID: movies, in: .library)
        XCTAssertEqual(HomeCollectionPins.pins(in: .library), [])
        XCTAssertEqual(HomeCollectionPins.pins, [bond], "unpinning from the library leaves the Home pin")
    }

    func test_updateTitles_renamesLibraryPinsToo() {
        HomeCollectionPins.pin(bond, in: .library)
        HomeCollectionPins.updateTitles(from: [PlexMetadata(ratingKey: "9144", title: "007")], libraryUUID: movies)
        XCTAssertEqual(HomeCollectionPins.pins(in: .library).first?.title, "007")
    }

    /// The library page draws its own pins, in pin order, after the
    /// Collections row. A pin from another library, one Plex already shows
    /// as a hub on this page, and one with nothing fetched draw no row.
    func test_libraryPinRows_filtersToDrawableRowsInPinOrder() {
        let spy = Pin(ratingKey: "1", libraryUUID: movies, title: "Spy")
        let otherLibrary = Pin(ratingKey: "2", libraryUUID: tv, title: "Other")
        let empty = Pin(ratingKey: "3", libraryUUID: movies, title: "Empty")
        let unfetched = Pin(ratingKey: "4", libraryUUID: movies, title: "Unfetched")
        let rows = PlexHomeViewController.libraryPinRows(
            pins: [spy, otherLibrary, newlyReleased, empty, unfetched, bond],
            libraryUUID: movies,
            hubKeys: [newlyReleased.childrenKey],
            fetched: [spy.id: members, otherLibrary.id: members, newlyReleased.id: members,
                      empty.id: [], bond.id: members])
        XCTAssertEqual(rows.map(\.pin), [spy, bond])
        XCTAssertEqual(rows.first?.items.map(\.ratingKey), ["55929"])
    }

    func test_pins_arePerProfile() {
        HomeCollectionPins.pin(bond)
        UserDefaults.standard.set(profileB, forKey: userIdKey)
        XCTAssertEqual(HomeCollectionPins.pins, [], "another Plex Home profile sees none of A's pins")
        UserDefaults.standard.set(profileA, forKey: userIdKey)
        XCTAssertEqual(HomeCollectionPins.pins, [bond])
    }

    /// `PlexDataStore.loadPinnedCollections` keeps its fetch results only while
    /// this key is unchanged: same key keeps them, a different key drops them.
    /// It must follow `selectedPlexUserId` (the first sign-in moves the base
    /// key to a profile key) and stay put otherwise.
    func test_storageKey_changesOnlyWithSelectedProfile() {
        let keyA = HomeCollectionPins.storageKey
        XCTAssertEqual(keyA, "homeCollectionPins_user_\(profileA)")
        XCTAssertEqual(HomeCollectionPins.storageKey, keyA, "unchanged profile keeps the key")
        UserDefaults.standard.set(profileB, forKey: userIdKey)
        XCTAssertNotEqual(HomeCollectionPins.storageKey, keyA, "another profile drops the results")
        UserDefaults.standard.removeObject(forKey: userIdKey)
        XCTAssertEqual(HomeCollectionPins.storageKey, "homeCollectionPins", "no profile yet uses the base key")
    }

    func test_pin_postsChangedNotification() {
        expectation(forNotification: HomeCollectionPins.changedNotification, object: nil)
        HomeCollectionPins.pin(bond)
        waitForExpectations(timeout: 1)
    }

    // MARK: - updateTitles

    func test_updateTitles_adoptsRenameInThatLibraryOnly() {
        HomeCollectionPins.pin(bond)
        HomeCollectionPins.pin(Pin(ratingKey: "9144", libraryUUID: tv, title: "James Bond"))
        HomeCollectionPins.updateTitles(
            from: [PlexMetadata(ratingKey: "9144", title: "007 Collection")],
            libraryUUID: movies
        )
        XCTAssertEqual(HomeCollectionPins.pins.map(\.title), ["007 Collection", "James Bond"])
    }

    /// The library page calls this on every refresh, so a no-op must not post
    /// (each post re-fetches every pin).
    func test_updateTitles_writesNothingWhenNoTitleDiffers() {
        HomeCollectionPins.pin(bond)
        let posted = expectation(forNotification: HomeCollectionPins.changedNotification, object: nil)
        posted.isInverted = true
        HomeCollectionPins.updateTitles(
            from: [PlexMetadata(ratingKey: "9144", title: "James Bond"),
                   PlexMetadata(ratingKey: "118573", title: "Newly Released")],
            libraryUUID: movies
        )
        wait(for: [posted], timeout: 0.2)
        XCTAssertEqual(HomeCollectionPins.pins, [bond])
    }

    // MARK: - Projection decision (spec §9 test 4)

    func test_pinRow_promotedDuplicateIsOmitted() {
        XCTAssertEqual(
            PlexDataStore.pinRowDecision(isPromotedDuplicate: true, fetched: members, hasCachedRow: true),
            .omit, "Plex already promotes this collection's hub, and P1 wins")
    }

    func test_pinRow_loadedNonEmptyRenders() {
        XCTAssertEqual(
            PlexDataStore.pinRowDecision(isPromotedDuplicate: false, fetched: members, hasCachedRow: false),
            .render)
    }

    func test_pinRow_notFetchedCarriesOverOnlyACachedRow() {
        XCTAssertEqual(
            PlexDataStore.pinRowDecision(isPromotedDuplicate: false, fetched: nil, hasCachedRow: true),
            .carryOver, "an early projection must not wipe the warm-launch row (#236)")
        XCTAssertEqual(
            PlexDataStore.pinRowDecision(isPromotedDuplicate: false, fetched: nil, hasCachedRow: false),
            .omit, "nothing cached, nothing to carry")
    }

    func test_pinRow_fetchedEmptyIsOmitted() {
        XCTAssertEqual(
            PlexDataStore.pinRowDecision(isPromotedDuplicate: false, fetched: [], hasCachedRow: true),
            .omit, "a collection with no members right now draws no row; the pin stays")
    }

    // MARK: - Promoted hub keys

    /// The duplicate test in `projectHomeItems` and the tile menu's "Pin to
    /// Home" offer both ask this, so they must read one derivation. Only
    /// promoted hubs count (a library page lists every hub, promoted or not),
    /// and a hub with no `key` cannot match a pin.
    func test_promotedHubKeys_onlyPromotedHubsWithAKey() {
        let store = PlexDataStore.shared
        let saved = store.libraryHubs
        defer { store.libraryHubs = saved }

        let promoted = "/library/collections/9144/children"
        store.libraryHubs["test-hubs-library"] = [
            PlexHub(hubIdentifier: "a", key: promoted, promoted: true),
            PlexHub(hubIdentifier: "b", key: "/library/collections/118573/children", promoted: false),
            PlexHub(hubIdentifier: "c", key: "/library/collections/1/children"),
            PlexHub(hubIdentifier: "d", promoted: true),
        ]

        XCTAssertEqual(store.promotedHubKeys(forLibraryKey: "test-hubs-library"), [promoted])
        XCTAssertEqual(store.promotedHubKeys(forLibraryKey: "test-no-such-library"), [])
    }
}
