// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveRecentlyWatchedTests.swift
//  RivuletTests
//
//  A channel joins Recently Watched only after it has played a while; one
//  zapped past (its task cancelled first) never does.
//

import XCTest
@testable import Rivulet

@MainActor
final class LiveRecentlyWatchedTests: XCTestCase {
    func test_joinsAfterTheThreshold_andAZapNeverCounts() async throws {
        XCTAssertEqual(LiveTVDataStore.recentlyWatchedAfter, .seconds(50))
        let store = LiveTVDataStore.shared
        let id = "test:zap:\(UUID().uuidString)"
        let zapped = UnifiedChannel(id: id, sourceType: .xtream, sourceId: "test", name: "Zapped")
        let passing = store.beganWatching(zapped, recentAfter: .milliseconds(200), learnAfter: .seconds(10))
        XCTAssertFalse(store.recentChannelIds.contains(id))
        passing.cancel()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(store.recentChannelIds.contains(id))

        let watched = store.beganWatching(zapped, recentAfter: .milliseconds(100), learnAfter: .seconds(10))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(store.recentChannelIds.first, id)
        watched.cancel()
    }
}
