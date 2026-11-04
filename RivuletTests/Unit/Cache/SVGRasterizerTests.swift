// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Every hostile file here crashed or hung SwiftDraw before `SVGSafetyCheck` caught it.
final class SVGRasterizerTests: XCTestCase {

    private func svg(_ body: String, root: String = ##"viewBox="0 0 10 10""##) -> Data {
        Data(##"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" \##(root)>\##(body)</svg>"##.utf8)
    }

    private func image(_ data: Data, maxPixelSize: CGFloat = 256) -> CGImage? {
        SVGRasterizer.cgImage(from: data, maxPixelSize: maxPixelSize)
    }

    private func rgb(of image: CGImage, x: Int, y: Int) -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return Array(pixel.prefix(3))
    }

    func test_decode_rendersOffThePool() async {
        let data = svg(##"<rect width="10" height="10" fill="#fff"/>"##)
        let decoded = await SVGRasterizer.decode(data, maxPixelSize: 64)
        XCTAssertEqual(decoded?.width, 64)
        let rejected = await SVGRasterizer.decode(Data("not svg".utf8), maxPixelSize: 64)
        XCTAssertNil(rejected)
    }

    // MARK: - Detection

    func test_isSVG_acceptsCommonOpenings() {
        XCTAssertTrue(SVGRasterizer.isSVG(svg("")))
        XCTAssertTrue(SVGRasterizer.isSVG(Data(##"<?xml version="1.0"?><!-- Inkscape --><svg/>"##.utf8)))
        XCTAssertTrue(SVGRasterizer.isSVG(Data("\u{FEFF}\n  <SVG/>".utf8)))
    }

    func test_isSVG_rejectsOtherBytes() {
        XCTAssertFalse(SVGRasterizer.isSVG(Data("<!doctype html><html><svg/></html>".utf8)))
        XCTAssertFalse(SVGRasterizer.isSVG(Data("not an image <svg".utf8)))
        XCTAssertFalse(SVGRasterizer.isSVG(Data([0x89, 0x50, 0x4E, 0x47])))
    }

    // MARK: - Rendering

    func test_scalesLongestEdgeToMaxPixelSize_upAndDown() throws {
        let wide = svg("", root: ##"width="20" height="10""##)
        var rendered = try XCTUnwrap(image(wide))
        XCTAssertEqual([rendered.width, rendered.height], [256, 128])
        rendered = try XCTUnwrap(image(svg("", root: ##"viewBox="0 0 1000 2000""##), maxPixelSize: 100))
        XCTAssertEqual([rendered.width, rendered.height], [50, 100])
    }

    func test_drawsUprightWithColor() throws {
        let rendered = try XCTUnwrap(image(svg(##"<rect width="10" height="5" fill="#ff0000"/><rect y="5" width="10" height="5" fill="#0000ff"/>"##)))
        XCTAssertEqual(rgb(of: rendered, x: 128, y: 40), [255, 0, 0])
        XCTAssertEqual(rgb(of: rendered, x: 128, y: 216), [0, 0, 255])
    }

    func test_repeatedIdsAndGradientsFromCSSStillRender() {
        XCTAssertNotNil(image(svg(##"<g id="Group"><g id="Group"><rect id="Group" width="1" height="1"/></g></g>"##)))
        XCTAssertNotNil(image(svg(##"<style>.a{fill:url(#g)}</style><linearGradient id="g"/><rect class="a" width="1" height="1"/>"##)))
    }

    /// The real path runs on a concurrency worker's small stack, in a Debug build's large frames here.
    func test_deepestAllowedFiles_fitAWorkerStack() async {
        let nested = String(repeating: "<g>", count: 60) + String(repeating: "</g>", count: 60)
        var chain = ##"<defs><rect id="u0" width="1" height="1"/>"##
        for level in 1...20 { chain += ##"<g id="u\##(level)"><use xlink:href="#u\##(level - 1)"/></g>"## }
        chain += ##"</defs><use xlink:href="#u20"/>"##
        let files = [svg(nested), svg(chain)]

        let rendered = await Task.detached { files.map { SVGRasterizer.cgImage(from: $0, maxPixelSize: 64) != nil } }.value
        XCTAssertEqual(rendered, [true, true])
    }

    // MARK: - Hostile files

    func test_rejectsReferenceCycles() {
        XCTAssertNil(image(svg(##"<g id="a"><use xlink:href="#a"/></g>"##)))
        XCTAssertNil(image(svg(##"<g id="a"><use href="#b"/></g><g id="b"><use href="#a"/></g><use href="#a"/>"##)))
        XCTAssertNil(image(svg(##"<mask id="m"><rect width="1" height="1" mask="url(#m)"/></mask><rect width="1" height="1" mask="url(#m)"/>"##)))
        XCTAssertNil(image(svg(##"<pattern id="p" width="1" height="1"><rect width="1" height="1" style="fill:url('#p')"/></pattern><rect width="1" height="1" fill="url(#p)"/>"##)))
    }

    func test_rejectsPatternFilledFromStylesheet() {
        XCTAssertNil(image(svg(##"<style>.a{fill:url(#p)}</style><pattern id="p" width="1" height="1"><rect class="a" width="1" height="1"/></pattern><rect class="a" width="1" height="1"/>"##)))
    }

    func test_rejectsDeepNestingAndLongChains() {
        XCTAssertNil(image(svg(String(repeating: "<g>", count: 5000) + String(repeating: "</g>", count: 5000))))
        var chain = ##"<rect id="u0" width="1" height="1"/>"##
        for level in 1...2000 { chain += ##"<g id="u\##(level)"><use href="#u\##(level - 1)"/></g>"## }
        XCTAssertNil(image(svg(chain + ##"<use href="#u2000"/>"##)))
    }

    func test_rejectsExponentialExpansionAndHugeFlatFiles() {
        var bomb = ##"<rect id="l0" width="1" height="1"/>"##
        for level in 1...10 {
            bomb += ##"<g id="l\##(level)">"## + String(repeating: ##"<use href="#l\##(level - 1)"/>"##, count: 10) + "</g>"
        }
        XCTAssertNil(image(svg(bomb)))
        XCTAssertNil(image(svg(String(repeating: ##"<rect width="1" height="1"/>"##, count: 20_001))))
    }

    func test_rejectsRootSizesThatTrapConvertingToInt() {
        for root in [##"width="1e300" height="1""##, ##"width="NaN" height="1""##, ##"viewBox="0 0 inf inf""##, ##"viewBox="0 0 1e30 1""##] {
            XCTAssertNil(image(svg("", root: root)), root)
        }
    }

    func test_rejectsPathDataAfterClosepath() {
        for path in ["M0 0Z1", "M0 0 Z x", "M0 0z,"] {
            XCTAssertNil(image(svg(##"<path d="\##(path)"/>"##)), path)
        }
        XCTAssertNotNil(image(svg(##"<path d="M0 0L1 1Z M2 2L3 3z"/>"##)))
    }

    func test_rejectsEmbeddedFontsAndMalformedXML() {
        XCTAssertNil(image(svg(##"<style>@font-face{font-family:x;src:url(data:font/woff;base64,AAAA)}</style>"##)))
        XCTAssertNil(image(Data("<svg><g></svg>".utf8)))
    }
}
