// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// The content filter parses `text/mcf+vtt` documents with `VTTParser`, taking
/// cue timings from here and reading each cue's text as a filter directive, and
/// reads a title's whole subtitle file (SRT, ASS or VTT) to find language to
/// mute. WebVTT sidecars are also drawn from here: see `VTTStylingTests`.
final class SubtitleParserTests: XCTestCase {

    func testParsesCueTimingsAndText() throws {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:04.500
        First line

        00:01:02.250 --> 00:01:05.000
        Second line
        """

        let track = try VTTParser().parse(vtt)

        XCTAssertEqual(track.cues.count, 2)
        XCTAssertEqual(track.cues[0].startTime, 1.0, accuracy: 0.001)
        XCTAssertEqual(track.cues[0].endTime, 4.5, accuracy: 0.001)
        XCTAssertEqual(track.cues[0].text, "First line")
        // Minutes must carry into seconds, which is where an off-by-60 would hide.
        XCTAssertEqual(track.cues[1].startTime, 62.25, accuracy: 0.001)
        XCTAssertEqual(track.cues[1].endTime, 65.0, accuracy: 0.001)
        XCTAssertEqual(track.cues[1].text, "Second line")
    }

    func testParsesHourTimestampsAndMultiLineCues() throws {
        let vtt = """
        WEBVTT

        01:02:03.500 --> 01:02:06.000
        category=violence
        channel=main
        """

        let track = try VTTParser().parse(vtt)

        XCTAssertEqual(track.cues.count, 1)
        XCTAssertEqual(track.cues[0].startTime, 3723.5, accuracy: 0.001)
        // The filter splits the payload across lines, so they have to survive.
        XCTAssertEqual(track.cues[0].text, "category=violence\nchannel=main")
    }

    func testSkipsCueIdentifiers() throws {
        let vtt = """
        WEBVTT

        cue-1
        00:00:02.000 --> 00:00:03.000
        Only this is text
        """

        let track = try VTTParser().parse(vtt)

        XCTAssertEqual(track.cues.count, 1)
        XCTAssertEqual(track.cues[0].text, "Only this is text")
    }

    func testEmptyDocumentYieldsNoCues() throws {
        let track = try VTTParser().parse("WEBVTT\n")
        XCTAssertTrue(track.cues.isEmpty)
    }

    // MARK: SRT

    func testSRTParsesNumberedCuesAndStripsTags() throws {
        let srt = "1\r\n00:00:01,000 --> 00:00:04,500\r\n<i>First</i> line\r\n\r\n"
            + "2\r\n01:02:03,250 --> 01:02:05,000 X1:0 Y1:0\r\nSecond &amp; last\r\nline two\r\n"

        let track = try SRTParser().parse(srt)

        XCTAssertEqual(track.cues.count, 2)
        XCTAssertEqual(track.cues[0].startTime, 1.0, accuracy: 0.001)
        XCTAssertEqual(track.cues[0].endTime, 4.5, accuracy: 0.001)
        XCTAssertEqual(track.cues[0].text, "First line")
        XCTAssertEqual(track.cues[1].startTime, 3723.25, accuracy: 0.001)
        XCTAssertEqual(track.cues[1].text, "Second & last\nline two")
    }

    func testSRTSkipsMalformedBlocks() throws {
        let srt = """
        1
        not a timing line
        Lost text

        2
        00:00:05,000 --> 00:00:06,000
        Kept
        """
        let track = try SRTParser().parse(srt)
        XCTAssertEqual(track.cues.map(\.text), ["Kept"])
    }

    func testSRTSurvivesSloppySeparators() throws {
        // A separator line of spaces, then no separator at all: each cue must
        // keep its own text rather than absorb the next one.
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nFirst\n   \n2\n00:00:03,000 --> 00:00:04,000\nSecond\n"
            + "3\n00:00:05,000 --> 00:00:06,000\nThird"
        let track = try SRTParser().parse(srt)
        XCTAssertEqual(track.cues.map(\.text), ["First", "Second", "Third"])
        XCTAssertEqual(track.cues.map(\.startTime), [1, 3, 5])
    }

    // MARK: ASS/SSA

    func testASSReadsDialogueAndDropsOverrides() throws {
        let ass = """
        [Script Info]
        Title: Example

        [V4+ Styles]
        Format: Name, Fontname, Fontsize
        Style: Default,Arial,20

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Comment: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,not dialogue
        Dialogue: 0,0:00:10.50,0:00:12.00,Default,,0,0,0,,{\\an8}Hello, {\\i1}there{\\i0}\\Nfriend
        Dialogue: 0,1:00:00.00,1:00:01.00,Default,,0,0,0,,Later
        """

        let track = try ASSParser().parse(ass)

        XCTAssertEqual(track.cues.count, 2)
        XCTAssertEqual(track.cues[0].startTime, 10.5, accuracy: 0.001)
        XCTAssertEqual(track.cues[0].endTime, 12.0, accuracy: 0.001)
        XCTAssertEqual(track.cues[0].text, "Hello, there\nfriend")
        XCTAssertEqual(track.cues[1].startTime, 3600, accuracy: 0.001)
    }

    func testASSHonorsDeclaredFieldOrder() throws {
        let ssa = """
        [Events]
        Format: Start, End, Text
        Dialogue: 0:00:01.00,0:00:02.00,Short, with a comma
        """
        let track = try ASSParser().parse(ssa)
        XCTAssertEqual(track.cues.map(\.text), ["Short, with a comma"])
    }
}

/// What libavcodec drops from a WebVTT sidecar (colour classes, STYLE rules,
/// line numbers) has to come through `VTTParser`, mapped onto caption cues.
@MainActor
final class VTTStylingTests: XCTestCase {

    private let yellow = WebVTTDocument.RGBA(r: 1, g: 1, b: 0, a: 1)
    private let blue = WebVTTDocument.RGBA(r: 0, g: 0, b: 1, a: 1)
    private let red = WebVTTDocument.RGBA(r: 1, g: 0, b: 0, a: 1)

    private func parse(_ text: String) throws -> WebVTTDocument {
        try XCTUnwrap(WebVTTDocument.parse(text))
    }

    // MARK: Structure

    func test_rejectsTextWithoutSignature() {
        XCTAssertNil(WebVTTDocument.parse("1\n00:00:01,000 --> 00:00:02,000\nSRT"))
    }

    func test_readsTimesIdsAndSkipsNotes() throws {
        let doc = try parse("""
        \u{FEFF}WEBVTT - title

        NOTE a comment
        that spans lines

        intro
        01:00.500 --> 01:02.000
        Hello

        01:00:03.250 --> 01:00:04.000
        Second
        line
        """)
        XCTAssertEqual(doc.cues.count, 2)
        XCTAssertEqual(doc.cues[0].start, 60.5)
        XCTAssertEqual(doc.cues[0].end, 62)
        XCTAssertEqual(doc.cues[0].runs.map(\.text), ["Hello"])
        XCTAssertEqual(doc.cues[1].start, 3603.25)
        XCTAssertEqual(doc.cues[1].runs.map(\.text), ["Second\nline"])
    }

    func test_decodesEntities() throws {
        let doc = try parse("WEBVTT\n\n00:01.000 --> 00:02.000\nTom &amp; Jerry &lt;3 &#x2665;")
        XCTAssertEqual(doc.cues[0].runs.first?.text, "Tom & Jerry <3 \u{2665}")
    }

    // MARK: Colour classes

    func test_defaultColourClasses() throws {
        let doc = try parse("""
        WEBVTT

        00:01.000 --> 00:03.000
        <c.yellow>Yellow</c> plain <c.bg_blue>on blue</c>
        """)
        let runs = doc.cues[0].runs
        XCTAssertEqual(runs.map(\.text), ["Yellow", " plain ", "on blue"])
        XCTAssertEqual(runs[0].color, yellow)
        XCTAssertNil(runs[1].color)
        XCTAssertNil(runs[1].backgroundColor)
        XCTAssertEqual(runs[2].backgroundColor, blue)
    }

    /// Real 7plus sidecar shape: CEA-608 colours as compound classes.
    func test_broadcasterGreenClass_withBlackBackground() throws {
        let doc = try parse("WEBVTT\n\n00:29.000 --> 00:30.360 \n<c.green.bg_black>They look like extras</c>")
        let run = try XCTUnwrap(doc.cues[0].runs.first)
        XCTAssertEqual(run.color, .init(r: 0, g: 1, b: 0, a: 1))
        XCTAssertEqual(run.backgroundColor, .init(r: 0, g: 0, b: 0, a: 1))
    }

    func test_cssGreenKeepsItsCSSValue() throws {
        let doc = try parse("WEBVTT\n\nSTYLE\n::cue(.x) { color: green }\n\n00:01.000 --> 00:02.000\n<c.x>css</c>")
        XCTAssertEqual(doc.cues[0].runs.first?.color, .init(r: 0, g: 128.0 / 255, b: 0, a: 1))
    }

    func test_classedTagsKeepTheirMeaning() throws {
        let doc = try parse("WEBVTT\n\n00:01.000 --> 00:02.000\n<i.yellow>both</i>")
        let run = try XCTUnwrap(doc.cues[0].runs.first)
        XCTAssertTrue(run.isItalic)
        XCTAssertEqual(run.color, yellow)
    }

    func test_innerSpanOverridesOuter() throws {
        let doc = try parse("WEBVTT\n\n00:01.000 --> 00:02.000\n<c.yellow>a <c.red>b</c> c</c>")
        XCTAssertEqual(doc.cues[0].runs.map(\.color), [yellow, red, yellow])
    }

    func test_rubyTextIsDropped_voiceTextKept() throws {
        let doc = try parse("""
        WEBVTT

        00:01.000 --> 00:02.000
        <v Bob>Hi</v> <ruby>漢<rt>kan</rt></ruby> <00:01.500>now
        """)
        XCTAssertEqual(doc.cues[0].runs.map(\.text).joined(), "Hi 漢 now")
    }

    // MARK: STYLE

    func test_styleBlockRules() throws {
        let doc = try parse("""
        WEBVTT

        STYLE
        /* house style */
        ::cue { color: #00ff00 }
        ::cue(.loud) { color: red; font-weight: bold }
        ::cue(v[voice="Narrator"]) { font-style: italic; background-color: rgba(0, 0, 255, 0.5) }

        00:01.000 --> 00:02.000
        base <c.loud>loud</c> <v Narrator>told</v>
        """)
        let runs = doc.cues[0].runs
        XCTAssertEqual(runs.map(\.text), ["base ", "loud", " ", "told"])
        XCTAssertEqual(runs[0].color, .init(r: 0, g: 1, b: 0, a: 1))
        XCTAssertEqual(runs[1].color, red)
        XCTAssertTrue(runs[1].isBold)
        XCTAssertTrue(runs[3].isItalic)
        XCTAssertEqual(runs[3].backgroundColor, .init(r: 0, g: 0, b: 1, a: 0.5))
    }

    func test_authorRuleOverridesDefaultClass() throws {
        let doc = try parse("""
        WEBVTT

        STYLE
        ::cue(.yellow) { color: #ff8800 }

        00:01.000 --> 00:02.000
        <c.yellow>custom</c>
        """)
        XCTAssertEqual(doc.cues[0].runs.first?.color, .init(r: 1, g: 136.0 / 255, b: 0, a: 1))
    }

    func test_styleAfterFirstCueIsIgnored() throws {
        let doc = try parse("""
        WEBVTT

        00:01.000 --> 00:02.000
        first

        STYLE
        ::cue { color: red }

        00:03.000 --> 00:04.000
        second
        """)
        XCTAssertNil(doc.cues[1].runs.first?.color)
    }

    // MARK: Settings and placement

    func test_settingsParse() {
        let s = WebVTTDocument.settings(["line:2", "position:20%,line-left", "align:start", "size:50%"])
        XCTAssertEqual(s.lineNumber, 2)
        XCTAssertNil(s.lineFraction)
        XCTAssertEqual(s.position ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(s.align, .start)
    }

    func test_lineNumberReachesThePlacement() {
        let top = VTTParser.placement(for: WebVTTDocument.settings(["line:2"]))
        XCTAssertEqual(top?.lineNumber, 2)
        XCTAssertEqual(top?.alignment, 8)
        XCTAssertNil(top?.position)

        let bottom = VTTParser.placement(for: WebVTTDocument.settings(["line:-1", "align:end"]))
        XCTAssertEqual(bottom?.lineNumber, -1)
        XCTAssertEqual(bottom?.alignment, 3)
    }

    func test_linePercentMatchesTheEngine() throws {
        let placement = try XCTUnwrap(VTTParser.placement(
            for: WebVTTDocument.settings(["line:10%", "position:20%", "align:start"])))
        XCTAssertEqual(placement.alignment, 7)
        XCTAssertEqual(placement.position?.x ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(placement.position?.y ?? -1, 0.1, accuracy: 0.0001)
        XCTAssertNil(placement.lineNumber)
    }

    func test_noSettings_andVertical_stayInTheDefaultBand() {
        XCTAssertNil(VTTParser.placement(for: WebVTTDocument.settings([])))
        XCTAssertNil(VTTParser.placement(for: WebVTTDocument.settings(["vertical:rl", "line:2"])))
    }

    // MARK: Cue mapping

    func test_plainCueBecomesText_styledCueKeepsRuns() throws {
        let doc = try parse("""
        WEBVTT

        00:01.000 --> 00:02.000
        plain

        00:03.000 --> 00:04.000
        <c.bg_blue>boxed</c>
        """)
        let cues = VTTParser.captionCues(from: doc)
        guard case .text("plain") = cues[0].body else { return XCTFail("expected plain text") }
        guard case .styledText(let runs) = cues[1].body else { return XCTFail("expected styled text") }
        XCTAssertEqual(runs.first?.backgroundColor, UIColor(red: 0, green: 0, blue: 1, alpha: 1))
    }

    func test_onlyWebVTTSidecarsAreReadByTheHost() {
        let url = URL(string: "https://server/library/streams/12")!
        XCTAssertTrue(VTTParser.isWebVTT(formatHint: "vtt", url: url))
        XCTAssertTrue(VTTParser.isWebVTT(formatHint: "WebVTT", url: url))
        XCTAssertFalse(VTTParser.isWebVTT(formatHint: "srt", url: url))
        XCTAssertTrue(VTTParser.isWebVTT(formatHint: nil, url: URL(string: "https://x/sub.vtt")!))
    }
}
