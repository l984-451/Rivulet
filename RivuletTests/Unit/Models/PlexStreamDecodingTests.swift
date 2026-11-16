// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexStreamDecodingTests.swift
//  RivuletTests
//
//  Regression tests for PlexStream Codable decoding.
//

import XCTest
@testable import Rivulet

final class PlexStreamDecodingTests: XCTestCase {

    /// Plex omits `id` for streams embedded in the video container (e.g.,
    /// EIA-608 closed captions with `embeddedInVideo: "1"`). PlexStream must
    /// still decode and produce a stable synthesized `id`, otherwise full
    /// metadata fetches fail and detail views render empty.
    func testDecodesEmbeddedClosedCaptionStreamWithoutId() throws {
        let json = """
        {
            "streamType": 3,
            "canAutoSync": false,
            "codec": "eia_608",
            "index": 0,
            "bitrate": 13392,
            "embeddedInVideo": "1",
            "displayTitle": "Unknown",
            "extendedDisplayTitle": "Unknown (Closed Captions)"
        }
        """.data(using: .utf8)!

        let stream = try JSONDecoder().decode(PlexStream.self, from: json)

        XCTAssertNil(stream._id, "Plex did not provide an id for the embedded CC stream")
        XCTAssertEqual(stream.streamType, 3)
        XCTAssertEqual(stream.index, 0)
        XCTAssertEqual(stream.codec, "eia_608")
        XCTAssertTrue(stream.isSubtitle)
        // Synthesized id must be stable and non-zero so Identifiable / ForEach work.
        XCTAssertLessThan(stream.id, 0)
    }

    /// PMS 1.43 sends a track's ReplayGain as a string; a number or junk must not fail the stream.
    func testDecodesAudioGainLeniently() throws {
        func gain(_ value: String) throws -> Double? {
            let json = #"{"id":962367,"streamType":2,"codec":"mp3","gain":\#(value)}"#
            return try JSONDecoder().decode(PlexStream.self, from: Data(json.utf8)).gain?.value
        }
        XCTAssertEqual(try gain(#""-10.86""#), -10.86)
        XCTAssertEqual(try gain("2.5"), 2.5)
        XCTAssertNil(try gain(#""n/a""#))
    }

    /// A synthesized id for an embedded subtitle must not collide with an
    /// embedded stream of a different type, so ForEach / Identifiable stays
    /// well-defined when multiple embedded streams appear in one part.
    func testSynthesizedIdsAreUniqueAcrossStreamTypes() throws {
        let subtitle = """
        {"streamType": 3, "codec": "eia_608", "index": 0}
        """.data(using: .utf8)!
        let audio = """
        {"streamType": 2, "codec": "aac", "index": 0}
        """.data(using: .utf8)!

        let subtitleStream = try JSONDecoder().decode(PlexStream.self, from: subtitle)
        let audioStream = try JSONDecoder().decode(PlexStream.self, from: audio)

        XCTAssertNotEqual(subtitleStream.id, audioStream.id)
    }

    /// When Plex provides an `id`, the stream must surface it verbatim (no
    /// accidental fallthrough to the synthesized path).
    func testDecodesRealIdWhenProvided() throws {
        let json = """
        {
            "id": 694015,
            "streamType": 2,
            "codec": "eac3",
            "index": 1,
            "channels": 2,
            "displayTitle": "English (EAC3 Stereo)"
        }
        """.data(using: .utf8)!

        let stream = try JSONDecoder().decode(PlexStream.self, from: json)

        XCTAssertEqual(stream._id, 694015)
        XCTAssertEqual(stream.id, 694015)
    }

    /// The full Part payload from the bug report must decode end-to-end. This
    /// is the exact shape (trimmed to Part.Stream) that previously failed for
    /// "Forever Young (1992)" and prevented the detail view from loading.
    func testDecodesFullPartWithEmbeddedClosedCaptionStream() throws {
        let json = """
        {
            "id": 204827,
            "key": "/library/parts/204827/1775436056/file.mkv",
            "container": "mkv",
            "Stream": [
                {"id": 694013, "streamType": 1, "codec": "h264", "index": 0},
                {"id": 694015, "streamType": 2, "codec": "eac3", "index": 1},
                {"streamType": 3, "codec": "eia_608", "index": 0, "embeddedInVideo": "1"},
                {"id": 694016, "streamType": 3, "codec": "srt", "index": 2}
            ]
        }
        """.data(using: .utf8)!

        let part = try JSONDecoder().decode(PlexPart.self, from: json)

        XCTAssertEqual(part.Stream?.count, 4)
        XCTAssertEqual(part.Stream?[0].id, 694013)
        XCTAssertEqual(part.Stream?[1].id, 694015)
        XCTAssertNil(part.Stream?[2]._id)           // embedded CC
        XCTAssertLessThan(part.Stream?[2].id ?? 0, 0) // but has synthesized id
        XCTAssertEqual(part.Stream?[3].id, 694016)
    }
}
