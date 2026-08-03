// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
import CoreGraphics
@testable import Rivulet

@MainActor
final class CaptionOverlayPlacementTests: XCTestCase {

    private let canvas = CGSize(width: 1_000, height: 1_000)

    func testAuthoredPlacementClampsBothAxesToTenPercent() {
        let frame = captionFrame(
            placement: .init(alignment: 7, position: CGPoint(x: 0.05, y: 0.95)))

        XCTAssertEqual(frame.minX, 100, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, 900, accuracy: 0.5)
    }

    func testAuthoredVerticalPositionNamesTopOfBox() {
        let frame = captionFrame(
            placement: .init(alignment: 7, position: CGPoint(x: 0.10, y: 0.70)))

        XCTAssertEqual(frame.minX, 100, accuracy: 0.5)
        XCTAssertEqual(frame.minY, 700, accuracy: 0.5)
    }

    func testUnplacedCueUsesFivePercentBottomMargin() {
        let frame = captionFrame(placement: nil)

        XCTAssertEqual(frame.midX, canvas.width / 2, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, canvas.height * 0.95, accuracy: 0.5)
    }

    func testPlacedCueOnlyMovesWhenOSDWouldObscureIt() {
        let hiddenControls = captionFrame(
            placement: .init(alignment: 7, position: CGPoint(x: 0.25, y: 0.70)),
            controlsVisible: false)
        let visibleControls = captionFrame(
            placement: .init(alignment: 7, position: CGPoint(x: 0.25, y: 0.70)),
            controlsVisible: true)

        XCTAssertEqual(hiddenControls.minY, 700, accuracy: 0.5)
        XCTAssertEqual(
            visibleControls.maxY,
            canvas.height - SubtitleAdjustments.controlsFloor(pictureHeight: canvas.height),
            accuracy: 0.5)
    }

    func testCoarseTeletextPlacementUsesTenPercentBands() {
        let topLeft = captionFrame(placement: .init(alignment: 7, position: nil))
        let bottomRight = captionFrame(placement: .init(alignment: 3, position: nil))

        XCTAssertEqual(topLeft.minX, 100, accuracy: 0.5)
        XCTAssertEqual(topLeft.minY, 100, accuracy: 0.5)
        XCTAssertEqual(bottomRight.maxX, 900, accuracy: 0.5)
        XCTAssertEqual(bottomRight.maxY, 900, accuracy: 0.5)
    }

    func testPositionedBitmapUsesSafeAreaAndOSDClearance() {
        let hiddenControls = bitmapFrame(controlsVisible: false)
        let visibleControls = bitmapFrame(controlsVisible: true)

        XCTAssertEqual(hiddenControls.minX, 100, accuracy: 0.5)
        XCTAssertEqual(hiddenControls.maxY, 900, accuracy: 0.5)
        XCTAssertEqual(
            visibleControls.maxY,
            canvas.height - SubtitleAdjustments.controlsFloor(pictureHeight: canvas.height),
            accuracy: 0.5)
    }

    private func captionFrame(
        placement: AetherSubtitleCue.TextPlacement?,
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
                body: .text("Caption"),
                placement: placement)
        ])
        overlay.layoutIfNeeded()

        XCTAssertEqual(overlay.subviews.count, 1)
        return overlay.subviews[0].frame
    }

    private func bitmapFrame(controlsVisible: Bool) -> CGRect {
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let model = SubtitleModel()
        let overlay = CaptionOverlayView(
            model: model,
            controlsVisible: controlsVisible,
            videoSize: canvas)
        overlay.frame = CGRect(origin: .zero, size: canvas)
        model.update(cues: [
            AetherSubtitleCue(
                id: 2,
                startTime: 0,
                endTime: 10,
                body: .image(
                    cgImage: context.makeImage()!,
                    position: CGRect(x: 0.02, y: 0.95, width: 0.1, height: 0.05)))
        ])
        overlay.layoutIfNeeded()

        XCTAssertEqual(overlay.subviews.count, 1)
        return overlay.subviews[0].frame
    }
}
