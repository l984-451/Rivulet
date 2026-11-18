// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HeroLibrariesTests.swift
//  RivuletTests
//
//  The libraries Home's hero leaves out (Settings > Home > Hero), stored per profile.
//  The keys live in UserDefaults, so each test saves and restores them.
//

import XCTest
@testable import Rivulet

final class HeroLibrariesTests: XCTestCase {

    private let profileA = 987_654_321
    private let profileB = 987_654_322
    private let keys = ["selectedPlexUserId", "heroExcludedLibraries",
                        "heroExcludedLibraries_user_987654321", "heroExcludedLibraries_user_987654322",
                        "homeHeroSources_user_987654321", "heroPlaylistPins_user_987654321"]
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

    private func item(_ id: String, provider: String = "plex:a", library: String?) -> MediaItem {
        MediaItem(ref: MediaItemRef(providerID: provider, itemID: id), kind: .movie, title: id, sortTitle: nil,
                  overview: nil, year: nil, runtime: nil, parentRef: nil, grandparentRef: nil, episodeNumber: nil,
                  seasonNumber: nil, childProgress: nil,
                  userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
                  artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
                  parentArtwork: nil, grandparentArtwork: nil, libraryID: library)
    }

    func test_everyLibraryIsIncludedByDefault() {
        XCTAssertTrue(HeroLibraries.isIncluded(providerID: "plex:a", libraryID: "3"))
        XCTAssertTrue(HeroLibraries.allows(item("x", library: "3")))
    }

    /// A library of placeholders is left out; the same library id on another server is not.
    func test_aLeftOutLibrarysTitlesAreDropped_onlyOnItsServer() {
        HeroLibraries.set(providerID: "plex:a", libraryID: "3", included: false)
        let allows = HeroLibraries.allows
        XCTAssertFalse(allows(item("suggestion", library: "3")))
        XCTAssertTrue(allows(item("movie", library: "1")))
        XCTAssertTrue(allows(item("other", provider: "jellyfin:s", library: "3")))
        XCTAssertTrue(allows(item("unknown", library: nil)), "a title that names no library stays")

        HeroLibraries.set(providerID: "plex:a", libraryID: "3", included: true)
        XCTAssertTrue(HeroLibraries.allows(item("suggestion", library: "3")))
        XCTAssertNil(UserDefaults.standard.object(forKey: "heroExcludedLibraries_user_987654321"), "nothing stored once all are back")
    }

    /// Plex metadata names its section by key or by id.
    func test_plexMetadata_isMatchedOnItsSection() {
        HeroLibraries.set(providerID: "plex:a", libraryID: "3", included: false)
        let allows = HeroLibraries.allows(plexProviderID: "plex:a")
        var byKey = PlexMetadata()
        byKey.librarySectionKey = "/library/sections/3"
        var byID = PlexMetadata()
        byID.librarySectionID = 3
        var kept = PlexMetadata()
        kept.librarySectionID = 1
        XCTAssertFalse(allows(byKey))
        XCTAssertFalse(allows(byID))
        XCTAssertTrue(allows(kept))
        XCTAssertTrue(allows(PlexMetadata()), "no section: kept")
        XCTAssertTrue(HeroLibraries.allows(plexProviderID: nil)(byID), "no Plex server: nothing to match")
    }

    func test_choice_isPerProfile_andPostsItsNotification() {
        let posted = expectation(forNotification: HeroLibraries.changedNotification, object: nil)
        HeroLibraries.set(providerID: "plex:a", libraryID: "3", included: false)
        wait(for: [posted], timeout: 1)
        UserDefaults.standard.set(profileB, forKey: "selectedPlexUserId")
        XCTAssertTrue(HeroLibraries.isIncluded(providerID: "plex:a", libraryID: "3"))
        UserDefaults.standard.set(profileA, forKey: "selectedPlexUserId")
        XCTAssertFalse(HeroLibraries.isIncluded(providerID: "plex:a", libraryID: "3"))
    }

    /// Hero Reset is about what the hero shows; a library of placeholders stays out.
    func test_heroReset_keepsTheLeftOutLibraries() {
        HeroLibraries.set(providerID: "plex:a", libraryID: "3", included: false)
        HeroSources.reset()
        XCTAssertFalse(HeroLibraries.isIncluded(providerID: "plex:a", libraryID: "3"))
    }

    func test_inLibrary_keepsALibraryTheItemAlreadyNames() {
        XCTAssertEqual(item("a", library: nil).inLibrary("7").libraryID, "7")
        XCTAssertEqual(item("a", library: "1").inLibrary("7").libraryID, "1")
        XCTAssertNil(item("a", library: nil).inLibrary(nil).libraryID)
    }
}
