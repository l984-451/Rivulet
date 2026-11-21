// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
import UIKit
@testable import Rivulet

final class ContinueWatchingCardCompositorTests: XCTestCase {

    private typealias Compositor = ContinueWatchingCardCompositor

    // MARK: Geometry

    func testGeometryAtApplesWidth() {
        let g = Compositor.Geometry(cardWidth: 320)
        XCTAssertEqual(g.card, CGSize(width: 320, height: 228))
        XCTAssertEqual(g.still, CGRect(x: 0, y: 0, width: 320, height: 180))
        XCTAssertEqual(g.band, CGRect(x: 0, y: 180, width: 320, height: 48))
        XCTAssertEqual(g.titleBox, CGRect(x: 14, y: 42, width: 148, height: 96))
        XCTAssertEqual(g.titleBox.midY, g.still.midY)
        XCTAssertLessThan(g.blurStart, g.still.maxY)
        XCTAssertEqual(g.titleFloor, 164)
    }

    func testGradientStopsSitOnTheSeamAndTheCardsMiddle() {
        let g = Compositor.Geometry(cardWidth: 320)
        XCTAssertEqual(g.gradientAlphas, [0, 0, 0.03, 0.07, 0.19])
        let ys = g.gradientLocations.map { $0 * g.card.height }
        for (y, expected) in zip(ys, [0, 114, 145, 180, 228] as [CGFloat]) {
            XCTAssertEqual(y, expected, accuracy: 0.001)
        }
    }

    func testRegionsTileTheCardAtAnyWidth() {
        for width in [260, 320, 357, 406, 560] as [CGFloat] {
            let g = Compositor.Geometry(cardWidth: width)
            XCTAssertEqual(g.card.height, (width / 1.7778 + 48).rounded())
            XCTAssertEqual(g.still.maxY, g.band.minY)
            XCTAssertEqual(g.band.maxY, g.card.height)
            XCTAssertEqual(g.band.height, 48)
            XCTAssertTrue(g.still.contains(g.titleBox))
            XCTAssertEqual(g.gradientLocations, g.gradientLocations.sorted())
        }
    }

    func testAspectFillCoversAndCentres() {
        let rect = CGRect(x: 0, y: 0, width: 320, height: 180)
        XCTAssertEqual(Compositor.aspectFill(CGSize(width: 1920, height: 1080), in: rect), rect)
        let tall = Compositor.aspectFill(CGSize(width: 400, height: 300), in: rect)
        XCTAssertEqual(tall, CGRect(x: 0, y: -30, width: 320, height: 240))
        let wide = Compositor.aspectFill(CGSize(width: 400, height: 100), in: rect)
        XCTAssertEqual(wide, CGRect(x: -200, y: 0, width: 720, height: 180))
    }

    func testTitleFitsOnTheLeadingEdgeCentred() {
        let box = Compositor.Geometry(cardWidth: 320).titleBox
        XCTAssertEqual(Compositor.aspectFitLeading(CGSize(width: 400, height: 100), in: box),
                       CGRect(x: 14, y: 71.5, width: 148, height: 37))
        XCTAssertEqual(Compositor.aspectFitLeading(CGSize(width: 100, height: 200), in: box),
                       CGRect(x: 14, y: 42, width: 48, height: 96))
    }

    // MARK: Render

    /// A 16:9 still drawn by `draw` in a 320 x 180 top-left space.
    private func still(_ draw: (CGContext) -> Void) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180), format: format)
            .image { draw($0.cgContext) }.cgImage!
    }

    /// RGB of the pixel at a point of the 1x card.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    func testRenderIsOpaqueAtThePixelSize() throws {
        let g = Compositor.Geometry(cardWidth: 320)
        let white = still { $0.setFillColor(UIColor.white.cgColor); $0.fill(CGRect(x: 0, y: 0, width: 320, height: 180)) }
        let card = try XCTUnwrap(Compositor.render(still: white, geometry: g, scale: 2))
        XCTAssertEqual(card.width, 640)
        XCTAssertEqual(card.height, 456)
        XCTAssertEqual(card.alphaInfo, .noneSkipLast)
    }

    func testGradientDarkensAWhiteStillAtItsStops() throws {
        let g = Compositor.Geometry(cardWidth: 320)
        let white = still { $0.setFillColor(UIColor.white.cgColor); $0.fill(CGRect(x: 0, y: 0, width: 320, height: 180)) }
        let card = try XCTUnwrap(Compositor.render(still: white, geometry: g, scale: 1))
        XCTAssertEqual(pixel(card, x: 160, y: 40).r, 255, "clear above the first stop")
        XCTAssertEqual(Double(pixel(card, x: 160, y: 145).r), 255 * 0.97, accuracy: 3)
        // The band's blur spreads the stops: 0.93 and 0.81 drawn, 0.91 and 0.83 after it.
        XCTAssertEqual(Double(pixel(card, x: 160, y: 180).r), 255 * 0.91, accuracy: 4)
        XCTAssertEqual(Double(pixel(card, x: 160, y: 227).r), 255 * 0.83, accuracy: 4)
    }

    func testBandContinuesTheStillsLastRow() throws {
        let g = Compositor.Geometry(cardWidth: 320)
        // Red still whose lowest 18 pt are green: a stretch stays green to the card's
        // bottom edge; a mirror would bring the red back there.
        let striped = still {
            $0.setFillColor(UIColor.red.cgColor); $0.fill(CGRect(x: 0, y: 0, width: 320, height: 162))
            $0.setFillColor(UIColor.green.cgColor); $0.fill(CGRect(x: 0, y: 162, width: 320, height: 18))
        }
        let card = try XCTUnwrap(Compositor.render(still: striped, geometry: g, scale: 1))
        let top = pixel(card, x: 160, y: 60)
        XCTAssertGreaterThan(top.r, 250); XCTAssertLessThan(top.g, 5)
        let underSeam = pixel(card, x: 160, y: 184)
        XCTAssertGreaterThan(underSeam.g, underSeam.r)
        let bottom = pixel(card, x: 160, y: 226)
        XCTAssertGreaterThan(bottom.g, bottom.r * 4)
    }

    func testTitleBitmapKeepsTheLogoOnTheLeadingEdge() throws {
        let g = Compositor.Geometry(cardWidth: 320)
        let logo = still { $0.setFillColor(UIColor.white.cgColor); $0.fill(CGRect(x: 0, y: 0, width: 320, height: 180)) }
        let title = try XCTUnwrap(Compositor.renderTitle(logo: logo, geometry: g, scale: 1))
        let pad = Int(Compositor.titleShadowPad)
        XCTAssertEqual(title.width, 148 + 2 * pad)
        XCTAssertEqual(title.height, 96 + 2 * pad)
        // 16:9 into 148 x 96 is 148 x 83, centred: rows 6 to 89 past the pad.
        XCTAssertGreaterThan(pixel(title, x: pad + 1, y: pad + 48).r, 250)
        XCTAssertGreaterThan(pixel(title, x: pad + 146, y: pad + 48).r, 250)
        XCTAssertLessThan(pixel(title, x: pad + 74, y: pad + 2).r, 40)
    }

    // MARK: Title placement

    func testTitleOffsetsRunFromTheTopPaddingToTheFloorNearestFirst() {
        let g = Compositor.Geometry(cardWidth: 320)
        // The whole 96 pt box: 28 pt of room above, 26 below.
        XCTAssertEqual(g.titleOffsets(forHeight: 96), [0, -8, 8, -16, 16, -24, 24, -28, 26])
        // A 26 pt logo travels further: its own top to the padding, its bottom to the floor.
        let short = g.titleOffsets(forHeight: 26)
        XCTAssertEqual(short.first, 0)
        XCTAssertEqual(short.min(), -63); XCTAssertEqual(short.max(), 61)
        // Nothing fits: the title stays put.
        XCTAssertEqual(g.titleOffsets(forHeight: 400), [0])
    }

    /// Middle, upper, lower, as unit rects that do not overlap.
    private let slots = [CGRect(x: 0, y: 0.4, width: 0.5, height: 0.2),
                         CGRect(x: 0, y: 0.1, width: 0.5, height: 0.2),
                         CGRect(x: 0, y: 0.7, width: 0.5, height: 0.2)]

    private func grid(_ value: (_ x: Int, _ y: Int) -> Float) -> Compositor.Grid {
        Compositor.Grid(columns: 20, rows: 20, values: (0..<400).map { value($0 % 20, $0 / 20) })
    }

    func testGridStatsReadOnlyTheRect() throws {
        let half = grid { x, _ in x < 10 ? 0 : 1 }
        let left = try XCTUnwrap(half.stats(in: CGRect(x: 0, y: 0, width: 0.5, height: 1)))
        XCTAssertEqual(left.mean, 0); XCTAssertEqual(left.deviation, 0)
        let all = try XCTUnwrap(half.stats(in: CGRect(x: 0, y: 0, width: 1, height: 1)))
        XCTAssertEqual(all.mean, 0.5, accuracy: 0.001); XCTAssertEqual(all.deviation, 0.5, accuracy: 0.001)
        XCTAssertNil(half.stats(in: CGRect(x: 2, y: 2, width: 1, height: 1)))
        // Detail: one 1.0 step right across 20 columns; flat has none.
        XCTAssertEqual(all.detail, 0.05, accuracy: 0.001)
        XCTAssertEqual(half.stats(in: CGRect(x: 0, y: 0, width: 0.25, height: 1))?.detail, 0)
    }

    func testFineDetailLosesToTheSameTonesInFlatAreas() {
        // Every slot has the same mean and spread: a checkerboard under the
        // middle and upper slots, two flat halves under the lower.
        let luma = grid { x, y in y >= 14 ? (x < 5 ? 0.3 : 0.5) : ((x + y) % 2 == 0 ? 0.3 : 0.5) }
        XCTAssertEqual(try XCTUnwrap(luma.stats(in: slots[0])).deviation, try XCTUnwrap(luma.stats(in: slots[2])).deviation,
                       accuracy: 0.001)
        XCTAssertEqual(Compositor.chooseSlot(candidates: slots, faces: [], luma: luma, saliency: nil), 2)
    }

    func testMiddleWinsATie() {
        XCTAssertEqual(Compositor.chooseSlot(candidates: slots, faces: [], luma: grid { _, _ in 0.4 }, saliency: nil), 0)
        // Slightly better elsewhere is still a tie.
        let nearly = grid { _, y in y < 6 ? 0.3 : 0.4 }
        XCTAssertEqual(Compositor.chooseSlot(candidates: slots, faces: [], luma: nearly, saliency: nil), 0)
    }

    func testAFaceUnderTheMiddleSlotMovesTheTitle() {
        let face = CGRect(x: 0.2, y: 0.42, width: 0.1, height: 0.15)
        XCTAssertNotEqual(Compositor.chooseSlot(candidates: slots, faces: [face], luma: grid { _, _ in 0.4 },
                                                saliency: nil), 0)
    }

    func testFacesCoveredAlikeUnderEverySlotTakeTheCheapest() {
        let faces = slots.map { $0.insetBy(dx: 0.1, dy: 0.05) }
        XCTAssertEqual(Compositor.chooseSlot(candidates: slots, faces: faces, luma: grid { _, _ in 0.4 }, saliency: nil), 0)
        // The lower slot is far darker.
        let luma = grid { _, y in y >= 14 ? 0 : 0.8 }
        XCTAssertEqual(Compositor.chooseSlot(candidates: slots, faces: faces, luma: luma, saliency: nil), 2)
    }

    func testFacesUnderEverySlotTakeTheLeastCovered() {
        // Whole faces under the middle and upper slots, a sliver of one under the lower.
        let faces = [slots[0].insetBy(dx: 0.1, dy: 0.05), slots[1].insetBy(dx: 0.1, dy: 0.05),
                     CGRect(x: 0.2, y: 0.6, width: 0.1, height: 0.12)]
        XCTAssertEqual(Compositor.chooseSlot(candidates: slots, faces: faces, luma: grid { _, _ in 0.4 }, saliency: nil), 2)
    }

    func testBrightBusyLosesToCalmDark() {
        // Checkerboard under the middle and upper slots, flat dark under the lower.
        let luma = grid { x, y in y >= 14 ? 0.1 : ((x + y) % 2 == 0 ? 1 : 0.5) }
        XCTAssertEqual(Compositor.chooseSlot(candidates: slots, faces: [], luma: luma, saliency: nil), 2)
        XCTAssertTrue(Compositor.needsStrongShadow(under: slots[0], luma: luma))
        XCTAssertFalse(Compositor.needsStrongShadow(under: slots[2], luma: luma))
    }

    func testSaliencyUnderTheMiddleSlotMovesTheTitle() {
        let saliency = grid { _, y in (8..<12).contains(y) ? 1 : 0 }
        XCTAssertNotEqual(Compositor.chooseSlot(candidates: slots, faces: [], luma: grid { _, _ in 0.4 },
                                                saliency: saliency), 0)
    }

    func testASubjectUnderTheMiddleSlotMovesTheTitle() {
        let subject = grid { _, y in (8..<12).contains(y) ? 1 : 0 }
        XCTAssertNotEqual(Compositor.chooseSlot(candidates: slots, faces: [], luma: grid { _, _ in 0.4 },
                                                saliency: nil, subject: subject), 0)
        // A faint one is not worth the trip.
        let faint = grid { _, y in (8..<12).contains(y) ? 0.1 : 0 }
        XCTAssertEqual(Compositor.chooseSlot(candidates: slots, faces: [], luma: grid { _, _ in 0.4 },
                                             saliency: nil, subject: faint), 0)
    }

    func testCrowdingAFaceTipsAPoorSpotIntoMoving() {
        // A face beside the middle slot, touching nothing: the hard rule passes every slot.
        let face = CGRect(x: 0.5, y: 0.42, width: 0.16, height: 0.16)
        // Bright under the middle: under the bar alone, over it with the crowding.
        let luma = grid { _, y in (7..<13).contains(y) ? 0.82 : 0.2 }
        XCTAssertEqual(Compositor.chooseSlot(candidates: slots, faces: [], luma: luma, saliency: nil), 0)
        XCTAssertNotEqual(Compositor.chooseSlot(candidates: slots, faces: [face], luma: luma, saliency: nil), 0)
    }

    func testAReadableDefaultHoldsAgainstASlightlyBetterSpot() {
        // Busy under the middle slot but still under the bar; flat under the others.
        let luma = grid { x, y in (8..<12).contains(y) ? ((x + y) % 2 == 0 ? 0.3 : 0.35) : 0.3 }
        XCTAssertEqual(Compositor.chooseSlot(candidates: slots, faces: [], luma: luma, saliency: nil), 0)
    }

    func testDarkEnoughIsNotWorthMovingFor() {
        // Black under the lower slot, but the middle already reads.
        let luma = grid { _, y in y >= 14 ? 0 : 0.38 }
        XCTAssertEqual(Compositor.chooseSlot(candidates: slots, faces: [], luma: luma, saliency: nil), 0)
    }

    /// Where a title rests with no analysis: leading, on the floor.
    private func rest(_ logo: CGSize?, _ text: CGSize? = nil) -> Compositor.Placement {
        let g = Compositor.Geometry(cardWidth: 320)
        return Compositor.restingPlacement(for: g.titleFootprint(logoSize: logo, textSize: text), geometry: g)
    }

    func testPlacementWithNoSignalRestsOnTheFloor() {
        let g = Compositor.Geometry(cardWidth: 320)
        XCTAssertEqual(rest(nil).offset, 26)
        XCTAssertEqual(Compositor.placement(signals: .none, logoSize: nil, geometry: g), rest(nil))
        // Brightness alone, with face detection unavailable, never moves the title.
        let blind = Compositor.Signals(size: CGSize(width: 320, height: 180), faces: nil,
                                       luma: grid { _, y in y < 12 ? 1 : 0 }, saliency: nil)
        XCTAssertEqual(Compositor.placement(signals: blind, logoSize: nil, geometry: g).offset, rest(nil).offset)
    }

    func testPlacementScoresTheLogosOwnFootprint() {
        let g = Compositor.Geometry(cardWidth: 320)
        // A face in the resting box's top rows: the whole box covers it there,
        // a wide short logo resting on the floor does not.
        let box = g.titleRect(g.titleFootprint(logoSize: nil), side: .leading, offset: rest(nil).offset)
        let face = CGRect(x: 0.1, y: (box.minY + 2) / 180, width: 0.1, height: 10.0 / 180)
        let signals = Compositor.Signals(size: CGSize(width: 320, height: 180), faces: [face],
                                         luma: grid { _, _ in 0.3 }, saliency: nil)
        XCTAssertNotEqual(Compositor.placement(signals: signals, logoSize: nil, geometry: g), rest(nil))
        let logo = CGSize(width: 800, height: 100)
        XCTAssertEqual(Compositor.placement(signals: signals, logoSize: logo, geometry: g), rest(logo))
    }

    func testPlacementScoresTheFallbackTitlesLine() {
        let g = Compositor.Geometry(cardWidth: 320)
        // A face right of the title box, on the resting text line.
        let text = CGSize(width: 400, height: 36)
        let line = g.titleRect(g.titleFootprint(logoSize: nil, textSize: text), side: .leading, offset: rest(nil, text).offset)
        let face = CGRect(x: 230.0 / 320, y: line.minY / 180, width: 60.0 / 320, height: line.height / 180)
        let signals = Compositor.Signals(size: CGSize(width: 320, height: 180), faces: [face],
                                         luma: grid { _, _ in 0.3 }, saliency: nil)
        XCTAssertEqual(Compositor.placement(signals: signals, logoSize: nil, geometry: g), rest(nil))
        XCTAssertNotEqual(Compositor.placement(signals: signals, logoSize: nil, textSize: text, geometry: g), rest(nil, text))
    }

    func testPlacementRaisesTheTitleOffASubjectOnTheFloor() {
        let g = Compositor.Geometry(cardWidth: 320)
        // A subject over the still's bottom half only.
        let signals = Compositor.Signals(size: CGSize(width: 320, height: 180), faces: [], luma: grid { _, _ in 0.3 },
                                         saliency: nil, subject: grid { _, y in y >= 10 ? 1 : 0 })
        let logo = CGSize(width: 148, height: 30)
        XCTAssertEqual(rest(logo).offset, 59)
        XCTAssertLessThan(Compositor.placement(signals: signals, logoSize: logo, geometry: g).offset, 0)
    }

    /// Signals of a flat dark 320 x 180 still with `faces` given in points.
    private func signals(_ faces: [CGRect], subject: Compositor.Grid? = nil) -> Compositor.Signals {
        Compositor.Signals(size: CGSize(width: 320, height: 180),
                           faces: faces.map { CGRect(x: $0.minX / 320, y: $0.minY / 180, width: $0.width / 320, height: $0.height / 180) },
                           luma: grid { _, _ in 0.3 }, saliency: nil, subject: subject)
    }

    func testALogoThatHidesAFaceOnBothEdgesIsTriedSmaller() {
        let g = Compositor.Geometry(cardWidth: 320)
        // A 148 x 74 logo reaches y 14...164 and covers the face on its edge in every
        // slot; at 0.7 it is 52 pt tall and fits under it, on the floor.
        let face = signals([CGRect(x: 60, y: 60, width: 50, height: 51), CGRect(x: 210, y: 60, width: 50, height: 51)])
        let logo = CGSize(width: 400, height: 200)
        let small = Compositor.placement(signals: face, logoSize: logo, geometry: g)
        XCTAssertEqual(small.scale, Compositor.smallTitleScale)
        XCTAssertEqual(small.side, .leading)
        XCTAssertEqual(small.offset, 48)
        // The fallback label is never shrunk, and a face no size clears keeps the full logo.
        XCTAssertEqual(Compositor.placement(signals: face, logoSize: nil, geometry: g).scale, 1)
        let wall = signals([CGRect(x: 0, y: 0, width: 320, height: 180)])
        XCTAssertEqual(Compositor.placement(signals: wall, logoSize: logo, geometry: g).scale, 1)
        // A logo that already clears the face stays full size.
        XCTAssertEqual(Compositor.placement(signals: face, logoSize: CGSize(width: 800, height: 100), geometry: g).scale, 1)
    }

    // MARK: Title side

    func testLeadingEdgeWinsATieAndANearTie() {
        let g = Compositor.Geometry(cardWidth: 320), logo = CGSize(width: 400, height: 200)
        XCTAssertEqual(Compositor.placement(signals: signals([]), logoSize: logo, geometry: g), rest(logo))
        // A faint subject down the left half costs less than crossing over.
        let faint = signals([], subject: grid { x, _ in x < 10 ? 0.2 : 0 })
        XCTAssertEqual(Compositor.placement(signals: faint, logoSize: logo, geometry: g), rest(logo))
    }

    func testASubjectFillingTheLeadingEdgeSendsTheTitleAcross() {
        let g = Compositor.Geometry(cardWidth: 320)
        let filled = signals([], subject: grid { x, _ in x < 10 ? 1 : 0 })
        let placement = Compositor.placement(signals: filled, logoSize: CGSize(width: 400, height: 200), geometry: g)
        XCTAssertEqual(placement, Compositor.Placement(side: .trailing, offset: rest(CGSize(width: 400, height: 200)).offset))
    }

    func testAClearEdgeBeatsShrinkingAndTheLeastCoveredFullSizeSlotBeatsBoth() {
        let g = Compositor.Geometry(cardWidth: 320), logo = CGSize(width: 400, height: 200)
        // The face the small logo would duck on the leading edge: the trailing edge is clear at full size.
        let leadingFace = CGRect(x: 60, y: 60, width: 50, height: 51)
        XCTAssertEqual(Compositor.placement(signals: signals([leadingFace]), logoSize: logo, geometry: g),
                       Compositor.Placement(side: .trailing, offset: rest(logo).offset))
        // Full-height faces on both edges, the trailing one narrow: no size clears either.
        let walls = [CGRect(x: 20, y: 0, width: 130, height: 180), CGRect(x: 280, y: 0, width: 26, height: 180)]
        let placement = Compositor.placement(signals: signals(walls), logoSize: logo, geometry: g)
        XCTAssertEqual(placement.scale, 1)
        XCTAssertEqual(placement.side, .trailing)
    }

    func testTrailingFootprintMirrorsTheLeadingOneInsideTheCardAboveTheFloor() {
        let g = Compositor.Geometry(cardWidth: 320)
        let resting = g.titleFootprint(logoSize: CGSize(width: 400, height: 200))
        XCTAssertEqual(resting, CGRect(x: 14, y: 53, width: 148, height: 74))
        for scale in [1, Compositor.smallTitleScale] {
            for offset in g.titleOffsets(forHeight: resting.height * scale) {
                let leading = g.titleRect(resting, side: .leading, offset: offset, scale: scale)
                let trailing = g.titleRect(resting, side: .trailing, offset: offset, scale: scale)
                XCTAssertEqual(trailing.minX, 320 - leading.maxX, accuracy: 0.001)
                XCTAssertEqual(trailing.maxX, 306, accuracy: 0.001)
                XCTAssertEqual(trailing.minY, leading.minY); XCTAssertEqual(trailing.size, leading.size)
                XCTAssertGreaterThanOrEqual(trailing.minY, Compositor.padding - 0.001)
                XCTAssertLessThanOrEqual(trailing.maxY, g.titleFloor + 0.001)
            }
        }
        // A long fallback title stops at the leading padding.
        let long = g.titleFootprint(logoSize: nil, textSize: CGSize(width: 400, height: 36))
        XCTAssertEqual(g.titleRect(long, side: .trailing).minX, 14)
    }

    func testTrailingFallbackTitleIsScoredAtItsRealWidth() {
        let g = Compositor.Geometry(cardWidth: 320)
        // A subject fills the left half; a face sits in the mirrored box, left of a 100 pt line of text.
        let s = signals([CGRect(x: 170, y: 80, width: 20, height: 20)], subject: grid { x, _ in x < 10 ? 1 : 0 })
        let text = CGSize(width: 100, height: 36)
        XCTAssertEqual(Compositor.placement(signals: s, logoSize: nil, textSize: text, geometry: g),
                       Compositor.Placement(side: .trailing, offset: rest(nil, text).offset))
        // The whole box would cover it.
        XCTAssertEqual(Compositor.placement(signals: s, logoSize: nil, geometry: g).side, .leading)
    }
}
