// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class BelowFoldPrunedRailTests: XCTestCase {
    private let rail: [BelowFoldItem] = [.episode("a"), .episode("b"), .seasonDivider("s2"), .episode("c")]

    func test_removesEpisode() {
        XCTAssertEqual(BelowFoldCollectionView.prunedRail(rail, removing: ["a"]),
                       [.episode("b"), .seasonDivider("s2"), .episode("c")])
    }

    func test_dropsDividerWhenItsSeasonEmpties() {
        XCTAssertEqual(BelowFoldCollectionView.prunedRail(rail, removing: ["c"]), [.episode("a"), .episode("b")])
    }

    func test_dropsLeadingDividerWhenFirstSeasonEmpties() {
        XCTAssertEqual(BelowFoldCollectionView.prunedRail(rail, removing: ["a", "b"]), [.episode("c")])
    }

    func test_neighbourPrefersNextThenPrevious() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(SeasonDetailViewController.neighbourID(of: "b", in: ids, surviving: ["a", "c"]), "c")
        XCTAssertEqual(SeasonDetailViewController.neighbourID(of: "c", in: ids, surviving: ["a", "b"]), "b")
        XCTAssertNil(SeasonDetailViewController.neighbourID(of: "a", in: ["a"], surviving: []))
    }
}
