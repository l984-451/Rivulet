// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EPGWideArtTests.swift
//  RivuletTests
//
//  What's On art. Dispatcharr declares no icon sizes, so a programme's
//  matchup image only shows once it has been measured wide.
//

import XCTest
@testable import Rivulet

@MainActor
final class EPGWideArtTests: XCTestCase {
    private let classifier = EPGImageClassifier.shared

    private func program(icon: URL? = nil, landscape: URL? = nil) -> UnifiedProgram {
        UnifiedProgram(id: "p", channelId: "c", title: "College Football", startTime: .now,
                       endTime: .now + 1800, iconURL: icon, landscapeURL: landscape)
    }

    private func unique(_ name: String) -> URL {
        URL(string: "https://example.com/\(UUID().uuidString)/\(name).jpg")!
    }

    func test_declaredLandscape_winsWithoutMeasuring() {
        let wide = unique("wide")
        XCTAssertEqual(classifier.wideArt(for: program(icon: unique("icon"), landscape: wide)), wide)
    }

    func test_unmeasuredIcon_isNotArtYet() {
        XCTAssertNil(classifier.wideArt(for: program(icon: unique("icon"))))
        XCTAssertNil(classifier.wideArt(for: nil))
    }

    func test_iconMeasuredWide_becomesArt() async {
        let icon = unique("matchup")
        let kind = await classifier.classify(icon) { CGSize(width: 960, height: 540) }
        XCTAssertEqual(kind, .landscape)
        XCTAssertEqual(classifier.wideArt(for: program(icon: icon)), icon)
    }

    func test_iconMeasuredPortrait_staysOff() async {
        let icon = unique("poster")
        _ = await classifier.classify(icon) { CGSize(width: 600, height: 900) }
        XCTAssertNil(classifier.wideArt(for: program(icon: icon)))
    }
}
