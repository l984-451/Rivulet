// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// A non-Plex server's library settings belong to its own signed-in user,
/// never the Plex profile, so they hold for a Jellyfin-only user and across a
/// Plex profile switch.
@MainActor
final class LibrarySettingsProviderScopeTests: XCTestCase {
    private let settings = LibrarySettingsManager.shared
    private let provider = "jellyfin:scope-test"
    private let plexProfileA = 990_001
    private let plexProfileB = 990_002
    private var savedHidden: Set<String> = []
    private var savedOrder: [String] = []
    private var savedPlexUser: Int?

    private var movies: String { "\(provider)/movies" }
    private func scope(_ account: String?) -> LibrarySettingsManager.ProviderScope {
        .init(providerID: provider, accountID: account)
    }

    override func setUp() async throws {
        try await super.setUp()
        savedHidden = settings.hiddenLibraryKeys
        savedOrder = settings.libraryOrder
        savedPlexUser = UserDefaults.standard.object(forKey: "selectedPlexUserId") as? Int
    }

    override func tearDown() async throws {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.contains(provider) || key.hasSuffix("_user_\(plexProfileA)") || key.hasSuffix("_user_\(plexProfileB)") {
            defaults.removeObject(forKey: key)
        }
        settings.setProviderScopes([])
        settings.switchToUser(savedPlexUser)
        settings.hiddenLibraryKeys = savedHidden
        settings.libraryOrder = savedOrder
        try await super.tearDown()
    }

    func test_providerSettings_surviveAPlexProfileSwitch() {
        settings.switchToUser(plexProfileA)
        settings.setProviderScopes([scope("u1")])
        settings.hideLibrary(movies)
        settings.hideLibrary("7")

        settings.switchToUser(plexProfileB)
        XCTAssertFalse(settings.isLibraryVisible(movies), "Jellyfin visibility is not the Plex profile's")
        XCTAssertTrue(settings.isLibraryVisible("7"), "Plex visibility still is")
    }

    func test_providerSettings_holdWithNoPlexProfile() {
        settings.switchToUser(nil)
        settings.setProviderScopes([scope("u1")])
        settings.hideLibrary(movies)

        settings.setProviderScopes([])
        XCTAssertTrue(settings.isLibraryVisible(movies), "signed out, the server's settings unload")
        settings.setProviderScopes([scope("u1")])
        XCTAssertFalse(settings.isLibraryVisible(movies), "signing back in brings them back")
    }

    func test_eachProviderUser_hasTheirOwnSettings() {
        settings.setProviderScopes([scope("u1")])
        settings.hideLibrary(movies)
        settings.libraryOrder = [movies, "\(provider)/shows"]

        settings.setProviderScopes([scope("u2")])
        XCTAssertTrue(settings.isLibraryVisible(movies))
        XCTAssertFalse(settings.libraryOrder.contains(movies))

        settings.setProviderScopes([scope("u1")])
        XCTAssertFalse(settings.isLibraryVisible(movies))
        XCTAssertEqual(settings.libraryOrder.filter { $0.hasPrefix(provider) }, [movies, "\(provider)/shows"])
    }

    func test_plexProfileList_neverStoresProviderKeys() {
        settings.switchToUser(plexProfileA)
        settings.setProviderScopes([scope("u1")])
        settings.hideLibrary(movies)
        settings.hideLibrary("7")

        let plexList = UserDefaults.standard.array(forKey: "hiddenLibraryKeys_user_\(plexProfileA)") as? [String]
        XCTAssertEqual(plexList, ["7"])
    }
}
