// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  GuideBackdropTests.swift
//  RivuletTests
//
//  The Guide's backdrop. Moving between two programmes with art must read as
//  one crossfade: never a dip to the bare background in between.
//

import XCTest
@testable import Rivulet

@MainActor
final class GuideBackdropTests: XCTestCase {
    private typealias Target = GuideLayoutView.BackdropTarget

    private let art = URL(string: "https://example.com/art.jpg")!
    private let wide = URL(string: "https://example.com/wide.jpg")!

    private func program(id: String = "p", icon: URL? = nil, landscape: URL? = nil) -> UnifiedProgram {
        UnifiedProgram(id: id, channelId: "c", title: "t", startTime: .now, endTime: .now + 1800,
                       iconURL: icon, landscapeURL: landscape)
    }

    private func target(_ program: UnifiedProgram?, resolved: (programID: String, url: URL?)? = nil,
                        kind: EPGImageKind? = nil) -> Target {
        GuideLayoutView.backdropTarget(for: program, resolved: resolved, kind: kind)
    }

    func test_declaredLandscape_isShownAfterTheSettleDelay() {
        XCTAssertEqual(target(program(icon: art, landscape: wide)), .image(wide, settled: false))
    }

    /// The black flash: unlabelled art not yet measured used to read as "no
    /// backdrop", fading to the bare background, then back once measured.
    func test_unmeasuredArt_isPendingNotEmpty() {
        XCTAssertEqual(target(program(icon: art)), .pending)
    }

    /// Measuring already waited out the settle delay; waiting again is the lag.
    func test_measuredForThisProgramme_isReadyWithoutASecondWait() {
        XCTAssertEqual(target(program(icon: art), resolved: ("p", art)), .image(art, settled: true))
        XCTAssertEqual(target(program(icon: art), resolved: ("p", nil)), .image(nil, settled: true))
    }

    func test_measuredForAnotherProgramme_isIgnored() {
        XCTAssertEqual(target(program(icon: art), resolved: ("other", art)), .pending)
    }

    func test_knownKinds_andNoArt() {
        XCTAssertEqual(target(program(icon: art), kind: .landscape), .image(art, settled: false))
        XCTAssertEqual(target(program(icon: art), kind: .portrait), .image(nil, settled: false))
        XCTAssertEqual(target(program()), .image(nil, settled: false))
        XCTAssertEqual(target(nil), .image(nil, settled: false))
    }

    /// Art to art: the outgoing image stays opaque under the incoming one, so
    /// the page behind never shows through mid-fade. Art to none: it fades out.
    func test_outgoingOpacity() {
        XCTAssertEqual(GuideLayoutView.outgoingBackdropOpacity(progress: 0.5, hasIncoming: true), 1)
        XCTAssertEqual(GuideLayoutView.outgoingBackdropOpacity(progress: 0.5, hasIncoming: false), 0.5)
    }
}
