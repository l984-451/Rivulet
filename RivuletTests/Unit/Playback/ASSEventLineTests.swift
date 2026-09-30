import CoreGraphics
import XCTest
@testable import Rivulet

final class ASSEventLineTests: XCTestCase {

    func test_parsesTextField_keepingCommasInTheText() throws {
        let line = try XCTUnwrap(ASSEventLine("0,0,Default,,0,0,0,,{\\an8}Hello, {\\i1}there{\\i0}\\Nfriend"))
        XCTAssertEqual(line.rawText, "{\\an8}Hello, {\\i1}there{\\i0}\\Nfriend")
        XCTAssertEqual(line.plainText, "Hello, there\nfriend")
    }

    func test_rejectsTextThatIsNotAnEventLine() {
        XCTAssertNil(ASSEventLine("Just a plain caption"))
        XCTAssertNil(ASSEventLine("a,b,c,d,e,f,g,h,text"))
    }

    func test_linesIn_splitsOnePacketsRects() {
        let body = "1,0,Default,,0,0,0,,First\n2,0,Sign,,0,0,0,,{\\pos(10,20)}Second"
        XCTAssertEqual(ASSEventLine.lines(in: body).map(\.plainText), ["First", "Second"])
    }

    func test_drawing_isDetected() throws {
        XCTAssertTrue(try XCTUnwrap(ASSEventLine("0,0,Sign,,0,0,0,,{\\p1}m 0 0 l 100 0 100 100{\\p0}")).isDrawing)
        XCTAssertFalse(try XCTUnwrap(ASSEventLine("0,0,Sign,,0,0,0,,{\\pos(10,20)}Station")).isDrawing)
        XCTAssertFalse(try XCTUnwrap(ASSEventLine("0,0,Sign,,0,0,0,,{\\p0}Plain")).isDrawing)
    }

    func test_placement_normalizesPosAgainstPlayRes() throws {
        let line = try XCTUnwrap(ASSEventLine("0,0,Sign,,0,0,0,,{\\an8\\pos(960,270)}Station"))
        let placement = try XCTUnwrap(line.placement(playRes: CGSize(width: 1920, height: 1080)))
        XCTAssertEqual(placement.alignment, 8)
        XCTAssertEqual(placement.position?.x ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(placement.position?.y ?? -1, 0.25, accuracy: 0.0001)
    }

    func test_placement_isNilForPlainDialogue() throws {
        XCTAssertNil(try XCTUnwrap(ASSEventLine("0,0,Default,,0,0,0,,{\\i1}Hi")).placement(playRes: CGSize(width: 384, height: 288)))
    }

    func test_playRes_readsHeaderOrDefaults() {
        let header = "[Script Info]\r\nPlayResX: 1280\r\nPlayResY: 720\r\n\r\n[V4+ Styles]\r\n"
        XCTAssertEqual(ASSEventLine.playRes(fromHeader: header), CGSize(width: 1280, height: 720))
        XCTAssertEqual(ASSEventLine.playRes(fromHeader: "[Script Info]\n"), CGSize(width: 384, height: 288))
        XCTAssertEqual(ASSEventLine.playRes(fromHeader: nil), CGSize(width: 384, height: 288))
    }
}
