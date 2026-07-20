// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EntryMorphWindowViewTests.swift
//  RivuletTests
//
//  Regression cover for the row -> carousel entry morph squashing the poster.
//  Pins the aspect-fill geometry and the interpolation invariant the fix
//  leans on (see EntryMorphWindowView).
//

import XCTest
@testable import Rivulet

@MainActor
final class EntryMorphWindowViewTests: XCTestCase {

    /// MediaRowMetrics poster tile.
    private let tile = CGSize(width: 296, height: 444)
    /// PreviewCarouselGeometry.centeredCardFrame at 1920x1080.
    private let card = CGSize(width: 1744, height: 1028)

    private var posterAspect: CGFloat { tile.width / tile.height }

    private func fit(_ size: CGSize, _ aspect: CGFloat) -> CGRect {
        EntryMorphWindowView.contentFrame(inWindowOfSize: size, aspect: aspect)
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }

    // MARK: - Endpoints

    func test_atSourceTile_contentFillsWindowExactly() {
        let r = fit(tile, posterAspect)
        XCTAssertEqual(r.width, 296, accuracy: 0.5)
        XCTAssertEqual(r.height, 444, accuracy: 0.5)
        XCTAssertEqual(r.minX, 0, accuracy: 0.5)
        XCTAssertEqual(r.minY, 0)
    }

    func test_atCard_contentOverflowsBottomInsteadOfSquashing() {
        let r = fit(card, posterAspect)
        XCTAssertEqual(r.width, 1744, accuracy: 0.5)
        // NOT the card's 1028, which is what squashed it.
        XCTAssertEqual(r.height, 2616, accuracy: 0.5)
        XCTAssertEqual(r.height - card.height, 1588, accuracy: 0.5,
                       "the cropped remainder should run off the bottom edge")
    }

    func test_scaleIsUniformOnBothAxes() {
        let r = fit(card, posterAspect)
        XCTAssertEqual(r.width / tile.width, r.height / tile.height, accuracy: 0.001)
        XCTAssertEqual(r.width / tile.width, 5.89, accuracy: 0.01)
    }

    func test_contentIsTopAnchoredAtBothEnds() {
        XCTAssertEqual(fit(tile, posterAspect).minY, 0)
        XCTAssertEqual(fit(card, posterAspect).minY, 0)
    }

    // MARK: - The invariant the fix depends on

    /// UIKit lerps width and height independently. Safe only because both
    /// endpoints satisfy h = w / aspect. If this fails, the morph needs a
    /// CADisplayLink like the corner-radius lerp has.
    func test_aspectHoldsAtEveryInterpolatedFrame() {
        let start = fit(tile, posterAspect)
        let end = fit(card, posterAspect)

        for step in 0...100 {
            let t = CGFloat(step) / 100
            let w = lerp(start.width, end.width, t)
            let h = lerp(start.height, end.height, t)
            XCTAssertEqual(w / h, posterAspect, accuracy: 0.0001,
                           "aspect drifted at t=\(t)")
        }
    }

    /// The original bug: animating the snapshot's own frame (content ==
    /// window) skews it badly.
    func test_oldBehaviour_didDistort() {
        let mid = CGSize(width: lerp(tile.width, card.width, 0.5),
                         height: lerp(tile.height, card.height, 0.5))
        XCTAssertEqual(mid.width, 1020, accuracy: 0.5)
        XCTAssertEqual(mid.height, 736, accuracy: 0.5)
        XCTAssertEqual(mid.width / mid.height / posterAspect, 2.08, accuracy: 0.01)

        let peak = (card.width / card.height) / posterAspect
        XCTAssertEqual(peak, 2.54, accuracy: 0.01, "end-of-morph distortion")
    }

    func test_fixedMidpointStaysProportional() {
        let start = fit(tile, posterAspect)
        let end = fit(card, posterAspect)
        XCTAssertEqual(lerp(start.width, end.width, 0.5), 1020, accuracy: 0.5)
        XCTAssertEqual(lerp(start.height, end.height, 0.5), 1530, accuracy: 0.5)
    }

    // MARK: - Other tile shapes

    /// Aspect comes from the source frame, so landscape Continue Watching
    /// tiles need no special case.
    func test_landscapeSourceTile_coversAndStaysUniform() {
        let cw = CGSize(width: 357, height: 277)
        let r = fit(card, cw.width / cw.height)

        XCTAssertGreaterThanOrEqual(r.width, card.width - 0.5)
        XCTAssertGreaterThanOrEqual(r.height, card.height - 0.5)
        XCTAssertEqual(r.width / cw.width, r.height / cw.height, accuracy: 0.001)
        XCTAssertEqual(r.minY, 0)
    }

    /// Exit runs the other way, so height drives the fill and the overflow is
    /// horizontal.
    func test_exitDirection_cardCompositeIntoPosterTile() {
        let r = fit(tile, card.width / card.height)

        XCTAssertGreaterThanOrEqual(r.width, tile.width - 0.5)
        XCTAssertGreaterThanOrEqual(r.height, tile.height - 0.5)
        XCTAssertEqual(r.width / card.width, r.height / card.height, accuracy: 0.001)
        XCTAssertLessThan(r.minX, 0, "horizontal overflow should be centred")
        XCTAssertEqual(r.minY, 0, "top-anchored in both directions")
    }

    // MARK: - Degenerate input

    func test_degenerateInputsStayFinite() {
        let cases: [(CGSize, CGFloat)] = [
            (.zero, 0.667),
            (CGSize(width: 100, height: 0), 0.667),
            (CGSize(width: 296, height: 444), 0),
            (CGSize(width: 296, height: 444), -2)
        ]
        for (size, aspect) in cases {
            let r = fit(size, aspect)
            XCTAssertTrue(r.width.isFinite && r.height.isFinite,
                          "size \(size) aspect \(aspect) produced \(r)")
        }
    }

    // MARK: - The view

    func test_setWindow_movesWindowAndRefitsContent() {
        let content = UIView()
        let window = EntryMorphWindowView(content: content, sourceSize: tile)

        XCTAssertTrue(window.clipsToBounds, "the window must crop the overflow")
        XCTAssertEqual(content.frame.size, tile, "starts filling its source frame")

        let target = CGRect(x: 88, y: 52, width: card.width, height: card.height)
        window.setWindow(target)

        XCTAssertEqual(window.frame, target)
        XCTAssertEqual(content.frame.width, 1744, accuracy: 0.5)
        XCTAssertEqual(content.frame.height, 2616, accuracy: 0.5)
        XCTAssertEqual(content.frame.minY, 0, "content stays pinned to the top")
    }

    func test_windowReparentsContent() {
        let content = UIView()
        let holder = UIView()
        holder.addSubview(content)

        let window = EntryMorphWindowView(content: content, sourceSize: tile)

        XCTAssertEqual(content.superview, window)
        XCTAssertTrue(holder.subviews.isEmpty)
    }
}
