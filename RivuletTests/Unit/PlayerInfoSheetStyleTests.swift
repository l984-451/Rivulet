// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerInfoSheetStyleTests.swift
//  RivuletTests
//
//  Pure formatter tests for the shared info-sheet style used by the Details
//  pane (media facts and live stats).
//

import XCTest
@testable import Rivulet

final class PlayerInfoSheetStyleTests: XCTestCase {

    // New formatters for the Advanced tab.
    func testMbpsOneDecimal() {
        XCTAssertEqual(PlayerInfoSheetStyle.mbps(12.34), "12.3 Mbps")
    }

    func testFpsRoundsToWhole() {
        XCTAssertEqual(PlayerInfoSheetStyle.fps(59.9), "60 fps")
    }

    func testMillisecondsNegativeKeepsSign() {
        XCTAssertEqual(PlayerInfoSheetStyle.milliseconds(-8.2), "-8 ms")
    }

    func testMillisecondsPositiveShowsPlusSign() {
        XCTAssertEqual(PlayerInfoSheetStyle.milliseconds(3.6), "+4 ms")
    }

    // Formatters: guard the output.
    func testBitrateFormatsMbps() {
        XCTAssertEqual(PlayerInfoSheetStyle.bitrate(1_500_000), "1.5 Mbps")
    }

    func testBitrateFormatsKbps() {
        XCTAssertEqual(PlayerInfoSheetStyle.bitrate(128_000), "128 kbps")
    }

    // `bitrate(_:)` takes BITS per second, but Plex reports kbps in both
    // `Media.bitrate` and `Stream.bitrate`, so `PlayerDetailsPaneView` multiplies by
    // 1000 at the call site (the same conversion `PlexMediaMapper` applies).
    // Without it a 25 Mbps remux printed "25 kbps" and a 640 kbps track
    // printed "640 bps" — issues #242 / #243.
    func testPlexVideoKbpsRendersAsMbps() {
        let plexKbps = 25_000
        XCTAssertEqual(PlayerInfoSheetStyle.bitrate(plexKbps * 1000), "25.0 Mbps")
    }

    func testPlexAudioKbpsRendersAsKbps() {
        let plexKbps = 640
        XCTAssertEqual(PlayerInfoSheetStyle.bitrate(plexKbps * 1000), "640 kbps")
    }

    func testBufferSecondsClampsNegativeToZero() {
        XCTAssertEqual(PlayerInfoSheetStyle.bufferSeconds(-2), "0s")
    }

    func testBufferSecondsRoundsToWhole() {
        XCTAssertEqual(PlayerInfoSheetStyle.bufferSeconds(3.4), "3s")
    }
}
