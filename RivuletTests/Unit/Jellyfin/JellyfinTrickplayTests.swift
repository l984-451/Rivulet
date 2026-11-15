// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Rivulet

final class JellyfinTrickplayTests: XCTestCase {
    // 10 s apart, 3 x 2 tiles of 4 x 3 px: six thumbnails per sheet, 14 in all.
    private let info = JFTrickplayInfo(width: 4, height: 3, tileWidth: 3, tileHeight: 2,
                                       thumbnailCount: 14, interval: 10_000)

    func test_locate_walksTilesRowByRowThenSheets() {
        XCTAssertEqual(info.locate(0).sheet, 0)
        XCTAssertEqual(info.locate(0).crop, CGRect(x: 0, y: 0, width: 4, height: 3))
        XCTAssertEqual(info.locate(25).crop, CGRect(x: 8, y: 0, width: 4, height: 3))
        XCTAssertEqual(info.locate(35).crop, CGRect(x: 0, y: 3, width: 4, height: 3))
        let second = info.locate(60)
        XCTAssertEqual(second.sheet, 1)
        XCTAssertEqual(second.crop, CGRect(x: 0, y: 0, width: 4, height: 3))
    }

    func test_locate_clampsToFirstAndLastThumbnail() {
        XCTAssertEqual(info.locate(-5).sheet, 0)
        let last = info.locate(10_000)
        XCTAssertEqual(last.sheet, 2)
        XCTAssertEqual(last.crop, CGRect(x: 4, y: 0, width: 4, height: 3))
    }

    func test_choose_takesNearestWidthAndSkipsBrokenEntries() throws {
        let json = """
        {"Trickplay":{"src":{"320":{"Width":320,"Height":180,"TileWidth":10,"TileHeight":10,"ThumbnailCount":50,"Interval":10000,"Bandwidth":1},
        "640":{"Width":640,"Height":360,"TileWidth":10,"TileHeight":10,"ThumbnailCount":50,"Interval":10000,"Bandwidth":1},
        "160":{"Width":160,"Height":90,"TileWidth":10,"TileHeight":10,"ThumbnailCount":0,"Interval":10000,"Bandwidth":1}}}}
        """
        let item = try JellyfinJSON.decoder().decode(JFTrickplayItem.self, from: Data(json.utf8))
        let widths = try XCTUnwrap(item.widths(forSource: "src"))
        XCTAssertEqual(JFTrickplayInfo.choose(from: widths, near: 300)?.width, 320)
        XCTAssertEqual(JFTrickplayInfo.choose(from: widths, near: 100)?.width, 320)
        XCTAssertEqual(JFTrickplayInfo.choose(from: widths, near: 900)?.width, 640)
        XCTAssertNotNil(item.widths(forSource: "other"), "a lone source map serves any version")
    }

    func test_emptyTrickplayDecodesToNothing() throws {
        let item = try JellyfinJSON.decoder().decode(JFTrickplayItem.self, from: Data(#"{"Trickplay":{}}"#.utf8))
        XCTAssertNil(item.widths(forSource: "x"))
    }

    func test_previews_cropSheetAndKeepAtMostThreeSheets() async throws {
        let calls = Counter()
        let previews = JellyfinTrickplayPreviews(info: info) { index in
            await calls.add(index)
            return Self.jpeg(width: 12, height: 6)
        }
        let first = await previews.image(at: 25)
        XCTAssertEqual(first?.width, 4)
        XCTAssertEqual(first?.height, 3)
        _ = await previews.image(at: 26)
        let once = await calls.indexes
        XCTAssertEqual(once, [0], "the sheet loads once")
        for time in [60.0, 120] { _ = await previews.image(at: time) }
        _ = await previews.image(at: 0)
        _ = await previews.image(at: 60)
        let all = await calls.indexes
        XCTAssertEqual(all, [0, 1, 2], "three sheets fit")
    }

    func test_previews_badSheetIsNil() async {
        let previews = JellyfinTrickplayPreviews(info: info) { _ in Data("nope".utf8) }
        let image = await previews.image(at: 5)
        XCTAssertNil(image)
    }

    private actor Counter {
        var indexes: [Int] = []
        func add(_ index: Int) { indexes.append(index) }
    }

    private static func jpeg(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
