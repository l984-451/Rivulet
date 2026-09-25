// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// The content filter is the only caller of these parsers. It parses
/// `text/mcf+vtt` documents with `VTTParser`, taking cue timings from here and
/// reading each cue's text as a filter directive, and reads a title's whole
/// subtitle file (SRT, ASS or VTT) to find language to mute. Captions on screen
/// come from AetherEngine, or from AVPlayer's legible output on Live TV's
/// remote-HLS path, never from here.
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
