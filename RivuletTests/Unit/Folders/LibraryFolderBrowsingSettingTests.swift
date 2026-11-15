// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// The View choice sticks per library and per Plex profile, Titles by default.
@MainActor
final class LibraryFolderBrowsingSettingTests: XCTestCase {
    private let settings = LibrarySettingsManager.shared
    private let profileA = 990_101
    private let profileB = 990_102
    private var savedPlexUser: Int?

    override func setUp() async throws {
        try await super.setUp()
        savedPlexUser = UserDefaults.standard.object(forKey: "selectedPlexUserId") as? Int
    }

    override func tearDown() async throws {
        for profile in [profileA, profileB] {
            UserDefaults.standard.removeObject(forKey: "libraryViewMode_user_\(profile)")
        }
        settings.switchToUser(savedPlexUser)
        try await super.tearDown()
    }

    func test_viewMode_roundTripsPerLibraryAndProfile() {
        settings.switchToUser(profileA)
        XCTAssertEqual(settings.viewMode("1"), .titles, "titles by default")
        XCTAssertEqual(settings.viewMode("1", default: .folders), .folders, "caller's default when unset")
        for mode in [LibraryViewMode.collections, .folders, .titles] {
            settings.setViewMode(mode, for: "1")
            XCTAssertEqual(settings.viewMode("1"), mode)
        }
        settings.setViewMode(.folders, for: "1")
        XCTAssertEqual(settings.viewMode("2"), .titles, "per library")

        settings.switchToUser(profileB)
        XCTAssertEqual(settings.viewMode("1"), .titles, "per profile")
        settings.setViewMode(.collections, for: "1")

        settings.switchToUser(profileA)
        XCTAssertEqual(settings.viewMode("1"), .folders, "persists")
    }
}
