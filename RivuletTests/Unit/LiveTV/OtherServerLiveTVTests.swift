// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Both apps configure the other servers' Live TV with one call.
@MainActor
final class OtherServerLiveTVTests: XCTestCase {
    private var savedClosers: [String: @MainActor (URL) -> Void] = [:]

    override func setUp() {
        super.setUp()
        savedClosers = PlexLiveTimelineKeepalive.otherSessionClosers
        PlexLiveTimelineKeepalive.otherSessionClosers = [:]
    }

    override func tearDown() {
        PlexLiveTimelineKeepalive.otherSessionClosers = savedClosers
        super.tearDown()
    }

    private let jelly = StubMediaProvider(id: "jellyfin:a", kind: .jellyfin)
    private let emby = StubMediaProvider(id: "emby:a", kind: .emby)
    private let extraPlex = StubMediaProvider(id: "plex:x", kind: .plex)

    private func run(_ providers: [any MediaProvider], accounts: [MediaProviderKind: String], restricted: Bool = false)
        -> [String: String] {
        var seen: [String: String] = [:]
        OtherServerKind.configureLiveTV(secondary: providers, accounts: accounts, restricted: restricted) { kind, provider in
            seen[kind.kind.rawValue] = provider?.id ?? "none"
        }
        return seen
    }

    func test_installsAClosersForEachKind() {
        _ = run([], accounts: [:])
        XCTAssertEqual(Set(PlexLiveTimelineKeepalive.otherSessionClosers.keys), ["jellyfin", "emby"])
    }

    func test_eachKindGetsItsSignedInServer() {
        let seen = run([extraPlex, jelly, emby], accounts: [.jellyfin: "jellyfin:a", .emby: "emby:a"])
        XCTAssertEqual(seen, ["jellyfin": "jellyfin:a", "emby": "emby:a"])
    }

    func test_aKindWithNoServerIsToldNone() {
        let seen = run([jelly], accounts: [.jellyfin: "jellyfin:a"])
        XCTAssertEqual(seen, ["jellyfin": "jellyfin:a", "emby": "none"])
    }

    func test_aRegistryEntryLeftFromASignOutIsNotShown() {
        let seen = run([jelly, emby], accounts: [.emby: "emby:a"])
        XCTAssertEqual(seen, ["jellyfin": "none", "emby": "emby:a"])
    }

    func test_aRestrictedProfileSeesNoOtherServerLiveTV() {
        let seen = run([jelly, emby], accounts: [.jellyfin: "jellyfin:a", .emby: "emby:a"], restricted: true)
        XCTAssertEqual(seen, ["jellyfin": "none", "emby": "none"])
    }

    func test_shown_keepsExtraPlexAndTheSignedInAccounts() {
        let shown = OtherServerKind.shown([extraPlex, jelly, emby], accountIDs: [.jellyfin: "jellyfin:a"])
        XCTAssertEqual(shown.map(\.id), ["plex:x", "jellyfin:a"])
    }
}
