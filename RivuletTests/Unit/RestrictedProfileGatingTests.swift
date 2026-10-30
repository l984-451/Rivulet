// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// A restricted (managed) Plex profile does not get the owner's settings,
/// and stays restricted across a launch before the home-user list loads.
@MainActor
final class RestrictedProfileGatingTests: XCTestCase {

    private let manager = PlexUserProfileManager.shared
    private var savedUser: PlexHomeUser?

    override func setUp() async throws {
        savedUser = manager.selectedUser
    }

    override func tearDown() async throws {
        manager.selectedUser = savedUser
        if savedUser == nil { UserDefaults.standard.removeObject(forKey: "selectedPlexUserRestricted") }
    }

    private func rowIDs(_ page: SettingsPage) -> Set<String> {
        Set(SettingsContent.rows(for: page).map(\.id))
    }

    func test_restrictedProfile_losesOwnerOnlyRows_andKeepsTheRest() {
        manager.selectedUser = PlexHomeUser(id: 2, uuid: "kid", title: "Kid", restricted: true)
        XCTAssertTrue(manager.isRestrictedProfile)
        let root = rowIDs(.root), liveTV = rowIDs(.liveTV), playback = rowIDs(.playback), appearance = rowIDs(.appearance)
        XCTAssertFalse(root.contains("cat_servers"))
        XCTAssertFalse(liveTV.contains("liveTVSources"))
        XCTAssertFalse(playback.contains("cat_contentFilter"))
        XCTAssertFalse(appearance.contains("profilePickerOnLaunch"))
        XCTAssertFalse(appearance.contains("profilePickerOnReturn"))
        XCTAssertTrue(root.contains("cat_playback"))

        manager.selectedUser = PlexHomeUser(id: 1, uuid: "owner", title: "Owner", admin: true)
        XCTAssertFalse(manager.isRestrictedProfile)
        XCTAssertTrue(rowIDs(.root).contains("cat_servers"))
        XCTAssertTrue(rowIDs(.playback).contains("cat_contentFilter"))
    }

    func test_restriction_outlivesAnUnloadedHomeUserList() {
        manager.selectedUser = PlexHomeUser(id: 2, uuid: "kid", title: "Kid", restricted: true)
        manager.selectedUser = nil   // what a launch, or a failed home-user fetch, looks like
        XCTAssertTrue(manager.isRestrictedProfile)
    }
}
