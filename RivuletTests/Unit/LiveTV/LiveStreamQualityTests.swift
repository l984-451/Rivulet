// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveStreamQualityTests.swift
//  RivuletTests
//
//  A channel's picture and sound as last played, as the channel lists show it.
//

import XCTest
@testable import Rivulet

@MainActor
final class LiveStreamQualityTests: XCTestCase {
    func test_labels() {
        XCTAssertEqual(LiveStreamQuality(height: 2160, audioChannels: 6).labels, ["4K", "5.1"])
        XCTAssertEqual(LiveStreamQuality(height: 1080, audioChannels: 2).labels, ["1080p", "Stereo"])
        XCTAssertEqual(LiveStreamQuality(height: 1088, audioChannels: 1).labels, ["1080p", "Mono"])
        XCTAssertEqual(LiveStreamQuality(height: 720, audioChannels: 8).labels, ["720p", "7.1"])
        XCTAssertEqual(LiveStreamQuality(height: 576, audioChannels: nil).labels, ["SD"])
        XCTAssertEqual(LiveStreamQuality(height: nil, audioChannels: 2).labels, ["Stereo"])
        XCTAssertTrue(LiveStreamQuality(height: 0, audioChannels: 0).labels.isEmpty)
    }

    func test_record_keepsWhatAPartialReportDoesNotSay_andIsSaved() {
        let defaults = UserDefaults(suiteName: "LiveStreamQualityTests-\(UUID().uuidString)")!
        let store = LiveStreamQualityStore(defaults: defaults)
        store.record(channelId: "x:1", height: 1080, audioChannels: 2)
        // The software path reports no size: the picture stays as it was.
        store.record(channelId: "x:1", height: nil, audioChannels: 6)
        XCTAssertEqual(store.quality(for: "x:1")?.labels, ["1080p", "5.1"])
        store.record(channelId: "x:2", height: nil, audioChannels: nil)
        XCTAssertNil(store.quality(for: "x:2"))
        XCTAssertEqual(LiveStreamQualityStore(defaults: defaults).quality(for: "x:1")?.labels, ["1080p", "5.1"])
    }
}
