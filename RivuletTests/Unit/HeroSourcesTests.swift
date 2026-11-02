// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HeroSourcesTests.swift
//  RivuletTests
//
//  What Home's hero shows, chosen in Settings > Home > Hero. The keys are
//  device-wide, so each test saves and restores them.
//

import XCTest
@testable import Rivulet

@MainActor
final class HeroSourcesTests: XCTestCase {

    private let keys = ["homeHeroSources", "showHomeHero", "homeHeroContent"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in keys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
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
    }

    /// The single choice from before sources could be mixed carries over.
    func test_earlierChoice_carriesOver() {
        UserDefaults.standard.set("continueWatching", forKey: "homeHeroContent")
        XCTAssertEqual(HeroSources.sources, [.continueWatching])
        UserDefaults.standard.set(false, forKey: "showHomeHero")
        XCTAssertEqual(HeroSources.sources, [], "a hero turned off stays off")
    }

    func test_sourcesMix_andTheLastOneOffTurnsTheHeroOff() {
        HeroSources.set(.favoriteMovies, on: true)
        XCTAssertEqual(HeroSources.sources, [.trending, .favoriteMovies])
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "showHomeHero"))

        HeroSources.set(.trending, on: false)
        HeroSources.set(.favoriteMovies, on: false)
        XCTAssertEqual(HeroSources.sources, [])
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "showHomeHero"))
    }

    /// iOS shows one list (`homeHeroContent`): the first of its choices that is on here;
    /// with none of them on, it keeps the last one.
    func test_set_keepsTheIOSChoiceInStep() {
        HeroSources.set(.favoriteMovies, on: true)
        HeroSources.set(.trending, on: false)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "homeHeroContent"), "trending")
        HeroSources.set(.watchlist, on: true)
        HeroSources.set(.recentlyAdded, on: true)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "homeHeroContent"), "recentlyAdded")
    }
}
