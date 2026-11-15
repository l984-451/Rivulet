// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HeroSourcesTests.swift
//  RivuletTests
//
//  What Home's hero shows, chosen in Settings > Home > Hero, stored per profile.
//  The keys live in UserDefaults, so each test saves and restores them.
//

import XCTest
@testable import Rivulet

final class HeroSourcesTests: XCTestCase {

    private let profileA = 987_654_321
    private let profileB = 987_654_322
    private let keys = ["selectedPlexUserId", "showHomeHero", "homeHeroContent", "homeHeroSources",
                        "homeHeroSources_user_987654321", "homeHeroSources_user_987654322",
                        "heroPlaylistPins_user_987654321", "heroPlaylistPins_user_987654322"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in keys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.set(profileA, forKey: "selectedPlexUserId")
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    func test_default_isTrendingOnly() {
        XCTAssertEqual(HeroSources.sources, [.trending])
        XCTAssertTrue(HeroSources.isEnabled)
        XCTAssertTrue(HeroSources.isTrendingOnly)
    }

    /// The device-wide choice from before sources could be mixed is a new profile's default.
    func test_earlierChoice_isTheDefault_forEveryProfile() {
        UserDefaults.standard.set("continueWatching", forKey: "homeHeroContent")
        XCTAssertEqual(HeroSources.sources, [.continueWatching])
        UserDefaults.standard.set(profileB, forKey: "selectedPlexUserId")
        XCTAssertEqual(HeroSources.sources, [.continueWatching])

        UserDefaults.standard.set(false, forKey: "showHomeHero")
        XCTAssertEqual(HeroSources.sources, [], "a hero turned off stays off")
        XCTAssertFalse(HeroSources.isEnabled)
    }

    func test_sourcesMix_andTheLastOneOffTurnsTheHeroOff() {
        HeroSources.set(.favoriteMovies, on: true)
        XCTAssertEqual(HeroSources.sources, [.trending, .favoriteMovies])
        XCTAssertFalse(HeroSources.isTrendingOnly)

        HeroSources.set(.trending, on: false)
        HeroSources.set(.favoriteMovies, on: false)
        XCTAssertEqual(HeroSources.sources, [])
        XCTAssertFalse(HeroSources.isEnabled)
    }

    func test_aHeroPlaylistAloneKeepsTheHeroOn() {
        HeroSources.set(.trending, on: false)
        HomePlaylistPins.pin(.init(providerID: "jellyfin:test", playlistID: "p1", title: "Classics"), in: .hero)
        XCTAssertTrue(HeroSources.isEnabled)
        XCTAssertFalse(HeroSources.isTrendingOnly)
    }

    /// A choice made in one profile leaves the others on the default.
    func test_choice_isPerProfile() {
        HeroSources.set(.watchlist, on: true)
        UserDefaults.standard.set(profileB, forKey: "selectedPlexUserId")
        XCTAssertEqual(HeroSources.sources, [.trending])
        UserDefaults.standard.set(profileA, forKey: "selectedPlexUserId")
        XCTAssertEqual(HeroSources.sources, [.trending, .watchlist])
    }

    /// Reset is Trending only and no hero playlists, even when the earlier choice was something else.
    func test_reset_isTrendingOnly_withNoPlaylists() {
        UserDefaults.standard.set("watchlist", forKey: "homeHeroContent")
        HeroSources.set(.favoriteShows, on: true)
        HomePlaylistPins.pin(.init(providerID: "jellyfin:test", playlistID: "p1", title: "Classics"), in: .hero)

        let posted = expectation(forNotification: HeroSources.changedNotification, object: nil)
        HeroSources.reset()
        wait(for: [posted], timeout: 1)

        XCTAssertEqual(HeroSources.sources, [.trending])
        XCTAssertEqual(HomePlaylistPins.pins(in: .hero), [])
        XCTAssertTrue(HeroSources.isTrendingOnly)
    }

    /// A hero playlist change reaches whatever watches the hero.
    func test_heroPlaylistChange_postsTheHeroNotification() {
        let posted = expectation(forNotification: HeroSources.changedNotification, object: nil)
        HomePlaylistPins.pin(.init(providerID: "jellyfin:test", playlistID: "p1", title: "Classics"), in: .hero)
        wait(for: [posted], timeout: 1)
    }
}
