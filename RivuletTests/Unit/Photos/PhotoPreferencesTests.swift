// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class PhotoPreferencesTests: XCTestCase {
    private let library = MediaLibrary(id: "27", providerID: "test:prefs", title: "Photos", kind: .photos)
    private var keys: [String] {
        [PhotoPreferences.intervalKey, PhotoPreferences.transitionKey, PhotoPreferences.playsClipsKey,
         PhotoPreferences.queryKey(for: library)]
    }
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in keys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in keys { UserDefaults.standard.set(saved[key], forKey: key) }
        super.tearDown()
    }

    func test_defaults() {
        XCTAssertEqual(PhotoPreferences.slideInterval, 5)
        XCTAssertEqual(PhotoPreferences.transition, .dissolve)
        XCTAssertTrue(PhotoPreferences.playsClips)
        XCTAssertEqual(PhotoPreferences.query(for: library), .default)
    }

    func test_intervalSnapsToNearest() {
        UserDefaults.standard.set(7.0, forKey: PhotoPreferences.intervalKey)
        XCTAssertEqual(PhotoPreferences.slideInterval, 5)
        PhotoPreferences.slideInterval = 20
        XCTAssertEqual(PhotoPreferences.slideInterval, 20)
    }

    func test_settersRoundTrip() {
        PhotoPreferences.transition = .panAndZoom
        PhotoPreferences.playsClips = false
        XCTAssertEqual(PhotoPreferences.transition, .panAndZoom)
        XCTAssertFalse(PhotoPreferences.playsClips)
    }

    func test_queryKeepsSortAndShowOnly() {
        var query = PhotoQuery()
        query.sort = .name
        query.ascending = true
        query.show = .videos
        query.favoritesOnly = true
        query.shuffled = true
        query.takenBetween = Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 86_400)
        PhotoPreferences.setQuery(query, for: library)

        let read = PhotoPreferences.query(for: library)
        XCTAssertEqual(read.sort, .name)
        XCTAssertTrue(read.ascending)
        XCTAssertEqual(read.show, .videos)
        XCTAssertFalse(read.favoritesOnly)
        XCTAssertFalse(read.shuffled)
        XCTAssertNil(read.takenBetween)
        XCTAssertEqual(PhotoPreferences.queryKey(for: library), "photoLibraryQuery.test:prefs.27")
    }

    func test_queryNarrowedKeepsSavedSortAndNarrowing() {
        PhotoPreferences.setQuery(PhotoQuery(sort: .name, ascending: true), for: library)
        let range = Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 86_400)
        let read = PhotoPreferences.query(for: library, narrowedBy: PhotoQuery(favoritesOnly: true, takenBetween: range))
        XCTAssertEqual(read.sort, .name)
        XCTAssertTrue(read.ascending)
        XCTAssertTrue(read.favoritesOnly)
        XCTAssertEqual(read.takenBetween, range)
    }
}
