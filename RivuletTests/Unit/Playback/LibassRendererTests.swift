import XCTest
@testable import Rivulet

final class LibassRendererTests: XCTestCase {

    private static let header = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 1920
    PlayResY: 1080

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Helvetica Neue,60,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,40,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

    """

    private func makeRenderer(header: String = LibassRendererTests.header,
                              linePosition: Double = 0) throws -> LibassRenderer {
        let renderer = try XCTUnwrap(LibassRenderer(header: header, fonts: []))
        renderer.configure(frameWidth: 1920, frameHeight: 1080,
                           storageWidth: 1920, storageHeight: 1080, linePosition: linePosition)
        return renderer
    }

    private func frame(_ output: LibassRenderer.Output, file: StaticString = #filePath, line: UInt = #line) -> LibassRenderer.Frame? {
        guard case .changed(let frame) = output else {
            XCTFail("expected a changed frame", file: file, line: line)
            return nil
        }
        return frame
    }

    func test_linkedLibassIsTheV0175Release() {
        XCTAssertEqual(LibassRenderer.libraryVersion, 0x01705000)
    }

    func test_eventRendersInsideItsTimeAndNotOutside() throws {
        let renderer = try makeRenderer()
        renderer.add([.init(line: "1,0,Default,,0,0,0,,Hello there", startMs: 1000, durationMs: 1000)])
        XCTAssertNotNil(frame(renderer.renderNow(atMs: 1500)))
        XCTAssertNil(frame(renderer.renderNow(atMs: 2500)) ?? nil)
    }

    func test_sameTimeTwice_isUnchanged() throws {
        let renderer = try makeRenderer()
        renderer.add([.init(line: "1,0,Default,,0,0,0,,Hello", startMs: 0, durationMs: 5000)])
        _ = renderer.renderNow(atMs: 1000)
        guard case .unchanged = renderer.renderNow(atMs: 1000) else {
            return XCTFail("a static frame must report unchanged")
        }
    }

    /// A paused frame, or a stretch with no change, must not run libass on
    /// every display tick: layout of every active event happens before
    /// libass can say "unchanged".
    func test_repeatedTime_skipsLibassUntilSomethingChanges() throws {
        let renderer = try makeRenderer()
        renderer.add([.init(line: "1,0,Default,,0,0,0,,Hello", startMs: 0, durationMs: 5000)])
        _ = renderer.renderNow(atMs: 1000)
        _ = renderer.renderNow(atMs: 1000)
        XCTAssertEqual(renderer.libassRenderCount(), 1)
        renderer.add([.init(line: "2,0,Default,,0,0,0,,{\\an8}Top", startMs: 0, durationMs: 5000)])
        XCTAssertNotNil(frame(renderer.renderNow(atMs: 1000)), "a new event at the same time must re-render")
        XCTAssertEqual(renderer.libassRenderCount(), 2)
    }

    func test_readOrderZero_keepsEveryEvent() throws {
        let renderer = try makeRenderer()
        renderer.add([
            .init(line: "0,0,Default,,0,0,0,,First", startMs: 1000, durationMs: 1000),
            .init(line: "0,0,Default,,0,0,0,,Second", startMs: 3000, durationMs: 1000)
        ])
        XCTAssertEqual(renderer.eventCount(), 2)
        XCTAssertNotNil(frame(renderer.renderNow(atMs: 3500)))
    }

    func test_headerWithoutEventsSection_stillRenders() throws {
        let stylesOnly = Self.header.components(separatedBy: "[Events]")[0]
        let renderer = try makeRenderer(header: stylesOnly)
        renderer.add([.init(line: "1,0,Default,,0,0,0,,Hello", startMs: 0, durationMs: 5000)])
        XCTAssertNotNil(frame(renderer.renderNow(atMs: 1000)))
    }

    func test_linePosition_liftsDialogueButNotPositionedSigns() throws {
        let dialogue = "1,0,Default,,0,0,0,,Dialogue line"
        let sign = "2,0,Default,,0,0,0,,{\\an5\\pos(960,300)}Station"
        func rect(_ line: String, _ position: Double) throws -> CGRect {
            let renderer = try makeRenderer(linePosition: position)
            renderer.add([.init(line: line, startMs: 0, durationMs: 5000)])
            return try XCTUnwrap(frame(renderer.renderNow(atMs: 1000))).rect
        }
        let low = try rect(dialogue, 0), high = try rect(dialogue, 20)
        let lift = low.minY - high.minY
        XCTAssertTrue((150...260).contains(lift), "dialogue lifted \(lift)px, expected about 20% of 1040")
        XCTAssertEqual(try rect(sign, 0), try rect(sign, 20))
    }

    func test_japaneseText_findsAFallbackFont() throws {
        let renderer = try makeRenderer()
        renderer.add([.init(line: "1,0,Default,,0,0,0,,日本語のテスト", startMs: 0, durationMs: 5000)])
        let rendered = try XCTUnwrap(frame(renderer.renderNow(atMs: 1000)))
        XCTAssertGreaterThan(rendered.rect.width, 100)
    }
}
