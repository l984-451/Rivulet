// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Where the tile menu sits and which corner it grows from.
final class TileMenuPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let panel = CGSize(width: 440, height: 600)

    func test_topRowTile_topAlignedBelowAndGrowsDown() {
        let tile = CGRect(x: 80, y: 200, width: 260, height: 390)
        let p = TileMenuPlacement.place(panel: panel, beside: tile, in: screen)
        XCTAssertEqual(p.frame.minY, tile.minY)
        XCTAssertEqual(p.anchor.y, 0, "grows from its top corner, beside the tile's top")
        XCTAssertEqual(p.frame.minX, tile.maxX + 16)
        XCTAssertEqual(p.anchor.x, 0)
    }

    func test_bottomRowTile_bottomAlignedAndGrowsUp() {
        let tile = CGRect(x: 80, y: 600, width: 260, height: 390)
        let p = TileMenuPlacement.place(panel: panel, beside: tile, in: screen)
        XCTAssertEqual(p.frame.maxY, tile.maxY, "no room below: bottom edges line up")
        XCTAssertEqual(p.anchor.y, 1, "grows upward from its bottom corner")
        XCTAssertLessThanOrEqual(p.frame.maxY, screen.maxY - 50)
    }

    func test_tileOffTheBottomEdge_staysInsideTheSafeArea() {
        let tile = CGRect(x: 80, y: 900, width: 260, height: 390)
        let p = TileMenuPlacement.place(panel: panel, beside: tile, in: screen)
        XCTAssertEqual(p.frame.maxY, screen.maxY - 50)
        XCTAssertEqual(p.anchor.y, 1)
    }

    func test_rightEdgeTile_opensToTheLeft() {
        let tile = CGRect(x: 1580, y: 200, width: 260, height: 390)
        let p = TileMenuPlacement.place(panel: panel, beside: tile, in: screen)
        XCTAssertEqual(p.frame.maxX, tile.minX - 16)
        XCTAssertEqual(p.anchor.x, 1)
    }

    func test_noTile_centred() {
        let p = TileMenuPlacement.place(panel: panel, beside: nil, in: screen)
        XCTAssertEqual(p.frame.midX, screen.midX)
        XCTAssertEqual(p.frame.midY, screen.midY)
    }

    func test_panelTallerThanSafeArea_isCutToIt() {
        let tile = CGRect(x: 80, y: 600, width: 260, height: 390)
        let p = TileMenuPlacement.place(panel: CGSize(width: 440, height: 1200), beside: tile, in: screen)
        XCTAssertEqual(p.frame.minY, 50)
        XCTAssertEqual(p.frame.maxY, screen.maxY - 50)
    }
}
