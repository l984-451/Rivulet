// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InfoPopupCardLayoutTests.swift
//  RivuletTests
//
//  The info popup sizes its card from the measured content height and only adds
//  scroll breathing room when the content actually overflows. Pure math, so the
//  layout behavior that can only be seen on a device rests on a verified core.
//
//  Regression: the top inset was applied unconditionally, so a short synopsis
//  that fit the card exactly still scrolled by 8pt and clipped its last line.
//

import XCTest
@testable import Rivulet

final class InfoPopupCardLayoutTests: XCTestCase {

    private let pad: CGFloat = 52
    private let screen: CGFloat = 1080

    private func layout(_ contentHeight: CGFloat) -> InfoPopupCardLayout {
        InfoPopupCardLayout.make(contentHeight: contentHeight, pad: pad, screenHeight: screen)
    }

    func testShortContentHugsAndDoesNotScroll() {
        // The real measured case: 148pt of synopsis in a 1080pt-tall screen.
        let l = layout(148)
        XCTAssertEqual(l.cardHeight, 148 + 2 * pad)
        XCTAssertFalse(l.scrolls)
    }

    /// The bug: a permanent 8pt top inset left short content scrollable and cut
    /// off its last line. Content that fits must have NO inset on either edge.
    func testShortContentHasNoScrollInsets() {
        let l = layout(148)
        XCTAssertEqual(l.insetTop, 0)
        XCTAssertEqual(l.insetBottom, 0)
    }

    func testTallContentCapsAtScreenFractionAndScrolls() {
        let l = layout(2000)
        XCTAssertEqual(l.cardHeight, screen * 0.85)
        XCTAssertTrue(l.scrolls)
    }

    func testTallContentKeepsBreathingRoom() {
        let l = layout(2000)
        XCTAssertEqual(l.insetTop, 8)
        XCTAssertEqual(l.insetBottom, 72)
    }

    /// Exactly at the cap is not an overflow — no insets, no scroll.
    func testContentExactlyAtCapDoesNotScroll() {
        let l = layout(screen * 0.85 - 2 * pad)
        XCTAssertFalse(l.scrolls)
        XCTAssertEqual(l.insetTop, 0)
    }

    // MARK: - Forced height

    /// A caller-forced height always scrolls, so it keeps the breathing room —
    /// this path used to hardcode its own insets and clamp.
    func testFixedHeightAlwaysScrollsAndKeepsInsets() {
        let l = InfoPopupCardLayout.make(fixedHeight: 900, screenHeight: screen)
        XCTAssertEqual(l.cardHeight, 900)
        XCTAssertTrue(l.scrolls)
        XCTAssertEqual(l.insetTop, 8)
        XCTAssertEqual(l.insetBottom, 72)
    }

    func testFixedHeightClampsToScreen() {
        let l = InfoPopupCardLayout.make(fixedHeight: 5000, screenHeight: screen)
        XCTAssertEqual(l.cardHeight, screen * 0.92)
    }
}
