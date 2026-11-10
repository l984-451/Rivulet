// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import XCTest
@testable import Rivulet

final class WhatsNewRangeTests: XCTestCase {
    private let all = ["1.3.0 (126)", "1.3.0 (125)", "1.2.0 (124)", "1.2.0 (122)"]

    func test_skippedBuildsAreIncluded() {
        XCTAssertEqual(WhatsNewRange.versions(all, current: "1.3.0 (126)", lastSeen: "1.2.0 (124)"),
                       ["1.3.0 (126)", "1.3.0 (125)"])
    }

    func test_buildWithoutNotesStillShowsSkippedOnes() {
        XCTAssertEqual(WhatsNewRange.versions(all, current: "1.3.0 (127)", lastSeen: "1.2.0 (124)"),
                       ["1.3.0 (126)", "1.3.0 (125)"])
    }

    func test_nothingSeen_showsCurrentOnly() {
        XCTAssertEqual(WhatsNewRange.versions(all, current: "1.3.0 (126)", lastSeen: ""), ["1.3.0 (126)"])
    }

    func test_neverShowsNewerThanRunning() {
        XCTAssertEqual(WhatsNewRange.versions(all, current: "1.2.0 (124)", lastSeen: "1.2.0 (122)"), ["1.2.0 (124)"])
    }
}
