// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

//
//  LaunchSplashArrivalsTests.swift
//  RivuletTests
//
//  The arrival map that times the launch splash's drawing (`LaunchRiverArrivals.bin`, written by
//  tools/launch-splash). Without it the R appears whole at once and nothing says so.
//

import XCTest
@testable import Rivulet

final class LaunchSplashArrivalsTests: XCTestCase {

    @MainActor
    func test_mapShipsInTheApp() throws {
        let map = try XCTUnwrap(LaunchSplashAnimation.bundledArrivals, "LaunchRiverArrivals.bin is not in the app bundle")
        let bytes = [UInt8](map)
        let width = Int(bytes[0]) | Int(bytes[1]) << 8, height = Int(bytes[2]) | Int(bytes[3]) << 8
        XCTAssertEqual(map.count, 4 + width * height, "the map's size does not match its header")
        XCTAssertTrue(bytes.dropFirst(4).contains { $0 < 255 }, "the map reaches no part of the R")
    }

    @MainActor
    func test_mapCutsIntoEverySlice() throws {
        let map = try XCTUnwrap(LaunchSplashAnimation.bundledArrivals)
        let cut = try XCTUnwrap(LaunchSplashAnimation.slices(of: map, count: 64))
        // Every slice holds some of the R, in the order the line reaches them.
        XCTAssertEqual(cut.slices.map(\.arrival), (0..<64).map { CGFloat($0) / 64 })
    }

    @MainActor
    func test_aDamagedMapIsRefused() {
        XCTAssertNil(LaunchSplashAnimation.slices(of: Data(), count: 64))
        XCTAssertNil(LaunchSplashAnimation.slices(of: Data([2, 0, 2, 0, 0]), count: 64), "header says 2x2, one pixel")
    }
}
