// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HomePlaylistPinsTests.swift
//  RivuletTests
//
//  Playlists pinned to Home, stored per profile in UserDefaults. Provider ids
//  are fake so a signed-in simulator doesn't fetch and draw the test pins.
//

import XCTest
@testable import Rivulet

@MainActor
final class HomePlaylistPinsTests: XCTestCase {

    private typealias Pin = HomePlaylistPins.Pin

    private let userIdKey = "selectedPlexUserId"
    private let profileA = 987_654_321
    private let profileB = 987_654_322
    private var savedUserId: Any?

    private var classics: Pin { Pin(providerID: "jellyfin:test", playlistID: "p1", title: "Classic Movies") }
    private var atmos: Pin { Pin(providerID: "jellyfin:test", playlistID: "p2", title: "Atmos Demos") }
    private var plexClassics: Pin { Pin(providerID: "plex:test", playlistID: "p1", title: "Classic Movies") }

    private func ref(_ pin: Pin) -> MediaItemRef { MediaItemRef(providerID: pin.providerID, itemID: pin.playlistID) }

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
            UserDefaults.standard.removeObject(forKey: "homePlaylistPins_user_\(profile)")
            UserDefaults.standard.removeObject(forKey: "heroPlaylistPins_user_\(profile)")
        }
    }

    func test_pins_roundTripInPinOrder_andPinningTwiceKeepsOne() {
        XCTAssertEqual(HomePlaylistPins.pins, [])
        HomePlaylistPins.pin(classics)
        HomePlaylistPins.pin(atmos)
        HomePlaylistPins.pin(classics)
        XCTAssertEqual(HomePlaylistPins.pins, [classics, atmos])
    }

    /// The same playlist id on two servers is two playlists.
    func test_isPinned_andUnpin_matchServerAndPlaylist() {
        HomePlaylistPins.pin(classics)
        HomePlaylistPins.pin(plexClassics)
        XCTAssertTrue(HomePlaylistPins.isPinned(ref(classics)))

        HomePlaylistPins.unpin(ref(classics))
        XCTAssertFalse(HomePlaylistPins.isPinned(ref(classics)))
        XCTAssertEqual(HomePlaylistPins.pins, [plexClassics])
    }

    func test_pins_arePerProfile() {
        HomePlaylistPins.pin(classics)
        UserDefaults.standard.set(profileB, forKey: userIdKey)
        XCTAssertEqual(HomePlaylistPins.pins, [])
        UserDefaults.standard.set(profileA, forKey: userIdKey)
        XCTAssertEqual(HomePlaylistPins.pins, [classics])
    }

    /// A playlist in the hero is not a Home row, and the other way round.
    func test_heroPins_areStoredApartFromRowPins() {
        HomePlaylistPins.pin(classics, in: .hero)
        XCTAssertEqual(HomePlaylistPins.pins, [])
        XCTAssertEqual(HomePlaylistPins.pins(in: .hero), [classics])
        XCTAssertTrue(HomePlaylistPins.isPinned(ref(classics), in: .hero))
        XCTAssertFalse(HomePlaylistPins.isPinned(ref(classics)))
    }

    func test_unpin_ofAnUnpinnedPlaylist_postsNothing() {
        let posted = expectation(forNotification: HomePlaylistPins.changedNotification, object: nil)
        posted.isInverted = true
        HomePlaylistPins.unpin(ref(classics))
        wait(for: [posted], timeout: 0.1)
    }
}
