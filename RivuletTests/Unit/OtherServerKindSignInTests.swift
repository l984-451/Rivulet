// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// The per-kind sign-in entries iOS builds its server pages from.
@MainActor
final class OtherServerKindSignInTests: XCTestCase {
    func test_quickConnect_onlyOnJellyfin() {
        XCTAssertNotNil(OtherServerKind.jellyfin.quickConnect)
        XCTAssertNil(OtherServerKind.emby.quickConnect, "Emby has no Quick Connect")
    }

    func test_failureMessages_comeFromEachSession() {
        let error = MediaProviderError.unauthorized
        XCTAssertEqual(OtherServerKind.jellyfin.failureMessage(error), JellyfinSession.failureMessage(for: error))
        XCTAssertEqual(OtherServerKind.jellyfin.quickConnectFailureMessage(error),
                       JellyfinSession.quickConnectFailureMessage(for: error))
        XCTAssertEqual(OtherServerKind.emby.failureMessage(error), EmbySession.failureMessage(for: error))
    }

    func test_siloParticipatesOnceWithoutAdvertisingUnsupportedAccountServices() {
        XCTAssertEqual(OtherServerKind.all.filter { $0.kind == .silo }.count, 1)
        XCTAssertNotNil(OtherServerKind.entry(for: .silo))
        XCTAssertNil(OtherServerKind.silo.quickConnect, "Device approval uses Silo's staged profile flow, not Quick Connect.")
        XCTAssertNil(OtherServerKind.silo.storedMusicProvider())
        XCTAssertEqual(MediaProviderKind(providerID: "silo:server:profile"), .silo)
    }
}
