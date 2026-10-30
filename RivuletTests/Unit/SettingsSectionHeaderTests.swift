// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SettingsSectionHeaderTests.swift
//  RivuletTests
//
//  Appearance's section captions are rows and must never be focusable, or they
//  take a row's focus slot. Also pins the Live TV rows' one home and their ids.
//

import XCTest
@testable import Rivulet

@MainActor
final class SettingsSectionHeaderTests: XCTestCase {

    private var appearance: [SettingsRowItem] { SettingsContent.rows(for: .appearance) }

    func test_headers_areNeverFocusable() {
        let headers = appearance.filter(\.isHeader)
        XCTAssertFalse(headers.isEmpty, "Appearance should be grouped by captions")
        for header in headers {
            XCTAssertFalse(header.isFocusable, "caption \(header.title) must not take focus")
            XCTAssertFalse(header.showsChevron)
            // `.info` hands back its value string; empty is what renders as nothing.
            XCTAssertTrue(header.valueText?.isEmpty ?? true, "caption \(header.title) has trailing text")
        }
    }

    /// Two rows are now both titled "Hero" (under HOME and under LIBRARY). They
    /// must stay distinct underneath: same key on both would silently make one
    /// of them control the other's surface.
    func test_bothHeroRows_keepDistinctIdentities() {
        let heroes = appearance.filter { $0.title == "Hero" }
        XCTAssertEqual(heroes.count, 2)
        XCTAssertEqual(Set(heroes.map(\.id)), ["homeHero", "libraryHero"])
        for hero in heroes {
            XCTAssertNotNil(SettingsDescriptorStore.descriptor(for: hero.id),
                            "\(hero.id) needs a description panel entry to be tellable apart")
        }
    }

    /// Sidebar placement lives on Settings > Sidebar now.
    func test_sidebarPlacementRows_leftAppearance() {
        let gone = ["showDiscoverTab", "discoverAboveLibraries", "showWatchlistTab", "showPlaylistsTab", "liveTVAboveLibraries"]
        let ids = appearance.map(\.id) + SettingsContent.rows(for: .liveTV).map(\.id)
        XCTAssertTrue(gone.allSatisfy { !ids.contains($0) })
    }

    /// The User Profiles page is retired (the sidebar switches profiles now).
    /// Its one surviving setting has to land somewhere reachable, or the launch
    /// picker becomes a write-only preference nobody can turn off.
    func test_profilePickerOnLaunch_survivedOnAppearance() {
        let row = appearance.first { $0.id == "profilePickerOnLaunch" }
        XCTAssertNotNil(row, "the launch-picker toggle lost its home")
        XCTAssertEqual(row?.isFocusable, true)
        XCTAssertNotNil(SettingsDescriptorStore.descriptor(for: "profilePickerOnLaunch"))
        XCTAssertFalse(SettingsContent.rows(for: .root).contains { $0.id == "userProfiles" },
                       "root should no longer offer the profiles page")
    }

    func test_triviaSpoilerRow_isGone() {
        XCTAssertFalse(appearance.contains { $0.id == "hideTriviaSpoilers" })
        XCTAssertNil(SettingsDescriptorStore.descriptor(for: "hideTriviaSpoilers"))
    }

    /// Where Live TV sits and how it opens show on both pages: people look
    /// for them under Live TV as well as Appearance.
    func test_liveTVAppearanceRows_onBothPages() {
        let shared = ["defaultLayout"]
        let appearanceIDs = appearance.map(\.id)
        let liveTVIDs = SettingsContent.rows(for: .liveTV).map(\.id)
        for id in shared {
            XCTAssertTrue(appearanceIDs.contains(id), "\(id) should be on Appearance")
            XCTAssertTrue(liveTVIDs.contains(id), "\(id) should be on the Live TV page")
            XCTAssertNotNil(SettingsDescriptorStore.descriptor(for: id),
                            "\(id) lost its description panel entry")
        }
        // Playback-side Live TV rows stay put.
        XCTAssertTrue(liveTVIDs.contains("confirmExitMultiview"))
    }
}
