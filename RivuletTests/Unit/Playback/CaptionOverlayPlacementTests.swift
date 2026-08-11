// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
import CoreGraphics
@testable import Rivulet

/// Horizontal anchoring for cues that positioned themselves.
///
/// The picture fills the canvas here, so picture fractions read straight off
/// the numbers: `sideSafeFraction` 5% is x=50/950, `bandSideFraction` 10% is
/// x=100/900, and `placementFloor` is 6% of 1000 = 60, so the shared floor
/// puts a bottom-resting box's maxY at 940.
@MainActor
final class CaptionOverlayPlacementTests: XCTestCase {

    private let canvas = CGSize(width: 1_000, height: 1_000)

    // MARK: Anchored edge

    /// The regression this suite exists for. A left-aligned cue names its own
    /// LEFT edge, so `position:10%` starts the box at 10%. Centring the box on
    /// the anchor instead pinned it at 18.5% and wrapped it into a column.
    func testLeftAlignedFinePositionAnchorsLeftEdge() {
        let frame = captionFrame(
            placement: .init(alignment: 1, position: CGPoint(x: 0.10, y: 0.70)))

        XCTAssertEqual(frame.minX, 100, accuracy: 0.5)
        XCTAssertEqual(frame.minY, 700, accuracy: 0.5)
    }

    func testRightAlignedFinePositionAnchorsRightEdge() {
        let frame = captionFrame(
            placement: .init(alignment: 3, position: CGPoint(x: 0.90, y: 0.70)))

        XCTAssertEqual(frame.maxX, 900, accuracy: 0.5)
    }

    func testCentreAlignedFinePositionCentresTheBox() {
        let frame = captionFrame(
            placement: .init(alignment: 2, position: CGPoint(x: 0.50, y: 0.70)))

        XCTAssertEqual(frame.midX, 500, accuracy: 0.5)
    }

    // MARK: Wrapping

    /// A side-anchored cue wraps into the room between its anchor and the far
    /// safe edge (100...950 here), not into the narrow half beside it. The old
    /// maths capped this box at 270pt regardless of how much room was free.
    func testSideAnchoredCueWrapsIntoTheRoomBesideIt() {
        let frame = captionFrame(
            placement: .init(alignment: 1, position: CGPoint(x: 0.10, y: 0.40)),
            text: "A sign long enough that it has to wrap somewhere before the "
                + "right hand edge of the picture")

        XCTAssertEqual(frame.minX, 100, accuracy: 0.5)
        XCTAssertLessThanOrEqual(frame.maxX, 950.5)
        XCTAssertGreaterThan(frame.width, 400)
    }

    // MARK: Floor and coarse bands

    /// A placed cue still obeys the shared floor, which is what keeps Live TV
    /// (almost entirely placed cues) level with VOD's default band.
    func testPlacedCueStillObeysTheSharedFloor() {
        let frame = captionFrame(
            placement: .init(alignment: 1, position: CGPoint(x: 0.10, y: 0.99)))

        XCTAssertEqual(frame.maxY, 940, accuracy: 0.5)
    }

    /// Teletext arrives with a coarse `\an` and no percentage, so the column
    /// borrows the 10% anchor the WebVTT proxy writes for the same page.
    func testCoarseLeftBandUsesTheColumnAnchorAndFloor() {
        let frame = captionFrame(placement: .init(alignment: 1, position: nil))

        XCTAssertEqual(frame.minX, 100, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, 940, accuracy: 0.5)
    }

    func testUnplacedCueSitsInTheDefaultBand() {
        let frame = captionFrame(placement: nil)

        XCTAssertEqual(frame.midX, canvas.width / 2, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, 940, accuracy: 0.5)
    }

    // MARK: Helper

    private func captionFrame(
        placement: AetherSubtitleCue.TextPlacement?,
        text: String = "Caption",
        controlsVisible: Bool = false
    ) -> CGRect {
        let model = SubtitleModel()
        let overlay = CaptionOverlayView(
            model: model,
            controlsVisible: controlsVisible,
            videoSize: canvas)
        overlay.frame = CGRect(origin: .zero, size: canvas)
        model.update(cues: [
            AetherSubtitleCue(
                id: 1,
                startTime: 0,
                endTime: 10,
                body: .text(text),
                placement: placement)
        ])
        overlay.layoutIfNeeded()

        XCTAssertEqual(overlay.subviews.count, 1)
        return overlay.subviews.first?.frame ?? .zero
    }
}
