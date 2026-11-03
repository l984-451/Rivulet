// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
import CoreGraphics
@testable import Rivulet

/// Horizontal anchoring for cues that positioned themselves.
///
/// The picture fills the canvas here, so picture fractions read straight off
/// the numbers: `sideSafeFraction` 5% is x=50/950, `bandSideFraction` 10% is
/// x=100/900, `bandEdgeFraction` 10% is y=100/900, and `placementFloor` is 5%
/// of 1000 = 50, so the shared floor puts an unplaced bottom-resting box's
/// maxY at 950.
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

        XCTAssertEqual(frame.maxY, 950, accuracy: 0.5)
    }

    /// Teletext arrives with a coarse `\an` and no percentage, so the column
    /// borrows the 10% anchor the WebVTT proxy writes for the same page, and
    /// the bottom band rests at the symmetric 10% margin above the shared floor.
    func testCoarseLeftBandUsesTheColumnAnchorAndBandMargin() {
        let frame = captionFrame(placement: .init(alignment: 1, position: nil))

        XCTAssertEqual(frame.minX, 100, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, 900, accuracy: 0.5)
    }

    /// When the floor rises above the 10% band margin (such as when controls
    /// are visible), the floor still lifts the bottom teletext cue.
    func testCoarseLeftBandStillLiftsWhenFloorExceedsBandMargin() {
        let frame = captionFrame(
            placement: .init(alignment: 1, position: nil),
            controlsVisible: true)

        XCTAssertEqual(frame.minX, 100, accuracy: 0.5)
        XCTAssertEqual(
            frame.maxY,
            canvas.height - SubtitleAdjustments.controlsFloor,
            accuracy: 0.5)
    }

    func testUnplacedCueSitsInTheDefaultBand() {
        let frame = captionFrame(placement: nil)

        XCTAssertEqual(frame.midX, canvas.width / 2, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, 950, accuracy: 0.5)
    }

    // MARK: Height setting (#461)

    /// 0 is AVPlayer's position; each unit moves the band 10 points.
    func testHeightMovesTheDefaultBandBothWays() {
        XCTAssertEqual(captionFrame(placement: nil, heightUnits: 10).maxY, 850, accuracy: 0.5)
        XCTAssertEqual(captionFrame(placement: nil, heightUnits: -2).maxY, 970, accuracy: 0.5)
    }

    func testHeightStaysOnScreen() {
        XCTAssertEqual(captionFrame(placement: nil, heightUnits: -30).maxY, 1_000, accuracy: 0.5)
        XCTAssertEqual(captionFrame(placement: nil, heightUnits: 80).maxY, 200, accuracy: 0.5)
    }

    /// Negative height reaches the letterbox bar under a wide picture.
    func testHeightReachesTheLetterboxBar() {
        let wide = CGSize(width: 2_000, height: 800)
        XCTAssertEqual(captionFrame(placement: nil, videoSize: wide).maxY, 680, accuracy: 0.5)
        XCTAssertEqual(captionFrame(placement: nil, heightUnits: -30, videoSize: wide).maxY, 980, accuracy: 0.5)
    }

    /// The rail still wins over a low setting, and a high one doesn't jump when it appears.
    func testHeightClearsTheRailWithoutDoubleLifting() {
        let railTop = canvas.height - SubtitleAdjustments.controlsFloor
        XCTAssertEqual(captionFrame(placement: nil, controlsVisible: true, heightUnits: -10).maxY, railTop, accuracy: 0.5)
        XCTAssertEqual(captionFrame(placement: nil, controlsVisible: true, heightUnits: 50).maxY, 450, accuracy: 0.5)
    }

    /// The stepper lives in the open pane: every step shows, either way.
    func testHeightStepsShowWhileThePaneIsOpen() {
        func maxY(units: Int) -> CGFloat {
            let model = SubtitleModel()
            let overlay = CaptionOverlayView(model: model, style: .default, videoSize: canvas, heightUnits: units)
            overlay.paneOpen = true
            overlay.frame = CGRect(origin: .zero, size: canvas)
            model.update(cues: [AetherSubtitleCue(id: 1, startTime: 0, endTime: 10, body: .text("Caption"))])
            overlay.layoutIfNeeded()
            return overlay.subviews.first { !($0 is ASSOverlayView) }?.frame.maxY ?? 0
        }
        let rest = maxY(units: 0)
        XCTAssertEqual(rest, canvas.height - SubtitleAdjustments.controlsFloor - SubtitleAdjustments.paneLift, accuracy: 0.5)
        XCTAssertEqual(maxY(units: 1), rest - 10, accuracy: 0.5)
        XCTAssertEqual(maxY(units: -1), rest + 10, accuracy: 0.5)
    }

    /// A cue that placed itself stays where it asked to be.
    func testHeightDoesNotMovePlacedCues() {
        let frame = captionFrame(placement: .init(alignment: 1, position: CGPoint(x: 0.10, y: 0.70)), heightUnits: 20)
        XCTAssertEqual(frame.minY, 700, accuracy: 0.5)
    }

    func testHeightSettingIsOneClampedValue() {
        let saved = SubtitleAdjustments.heightUnits
        defer { SubtitleAdjustments.heightUnits = saved }
        SubtitleAdjustments.heightUnits = 999
        XCTAssertEqual(SubtitleAdjustments.heightUnits, 80)
        SubtitleAdjustments.heightUnits = -999
        XCTAssertEqual(SubtitleAdjustments.heightUnits, -30)
    }

    /// AVKit rests every style's box on the same floor.
    func testEditedStyleRestsOnTheSameFloor() {
        var style = CaptionStyle.default
        style.isSystemDefault = false
        style.box = .edited
        style.edge = .uniform
        let frame = captionFrame(placement: nil, style: style)

        XCTAssertEqual(frame.maxY, 950, accuracy: 0.5)
    }

    /// A background behind each line, no wider than its own text.
    func testLineBackgroundsFollowEachLine() {
        var style = CaptionStyle.default
        style.backgroundOpacity = 1
        style.windowOpacity = 0
        let model = SubtitleModel()
        let overlay = CaptionOverlayView(model: model, style: style, videoSize: canvas)
        overlay.frame = CGRect(origin: .zero, size: canvas)
        model.update(cues: [AetherSubtitleCue(id: 1, startTime: 0, endTime: 10, body: .text("A long first line\nB"))])
        model.sourceTime = 1
        overlay.layoutIfNeeded()
        let box = overlay.subviews.first { !($0 is ASSOverlayView) }
        box?.layoutIfNeeded()

        let lines = box?.subviews.filter { !($0 is UILabel) }.sorted { $0.frame.width > $1.frame.width } ?? []
        XCTAssertEqual(lines.count, 2)
        XCTAssertLessThan(lines[1].frame.width, lines[0].frame.width / 2)
    }

    // A track the content filter reads unseen: cues keep arriving, nothing is drawn.
    func testHiddenOverlayDrawsNoCaptions() {
        let model = SubtitleModel()
        let overlay = CaptionOverlayView(model: model, controlsVisible: false, videoSize: canvas)
        overlay.frame = CGRect(origin: .zero, size: canvas)
        overlay.isHidden = true
        model.update(cues: [AetherSubtitleCue(id: 1, startTime: 0, endTime: 10, body: .text("Caption"), placement: nil)])
        XCTAssertEqual(model.activeCues.count, 1)
        XCTAssertTrue(overlay.subviews.allSatisfy { $0 is ASSOverlayView })
        overlay.isHidden = false
        XCTAssertEqual(overlay.subviews.filter { !($0 is ASSOverlayView) }.count, 1)
    }

    // MARK: Helper

    private func captionFrame(
        placement: AetherSubtitleCue.TextPlacement?,
        text: String = "Caption",
        controlsVisible: Bool = false,
        style: CaptionStyle = .default,
        heightUnits: Int = 0,
        videoSize: CGSize? = nil
    ) -> CGRect {
        let model = SubtitleModel()
        let overlay = CaptionOverlayView(
            model: model,
            style: style,
            controlsVisible: controlsVisible,
            videoSize: videoSize ?? canvas,
            heightUnits: heightUnits)
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

        let captions = overlay.subviews.filter { !($0 is ASSOverlayView) }
        XCTAssertEqual(captions.count, 1)
        return captions.first?.frame ?? .zero
    }
}
