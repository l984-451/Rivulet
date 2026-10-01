// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveAVCaptureTests.swift
//  RivuletTests
//
//  The #319 measurement reads the engine's own log lines. A paused clock seek
//  is not the start, vLead only counts from 5 s after it, and the scan tag
//  takes three values whatever PMS sends.
//

import XCTest
@testable import Rivulet

final class LiveAVCaptureTests: XCTestCase {

    func test_startGapsAndSteadyLead() throws {
        let url = URL(string: "http://pms.local/livetv/sessions/abc/index.m3u8?rivuletLiveScanType=interlaced&X-Plex-Token=secret")!
        let capture = LiveAVCapture(url: url)
        capture.setCodec("mpeg2video")

        capture.ingest(line: "[AudioOutput] seekClock to=0.000 rate=0.0", at: 100)
        XCTAssertNil(capture.sample(), "a paused seek does not start the clock")
        capture.ingest(line: "[AudioOutput] seekClock to=50.000 rate=1.0", at: 101)
        capture.ingest(line: "[AudioOutput] seekClock to=60.000 rate=1.0", at: 102)  // a later seek, not the start
        capture.frame(pts: 50.8, at: 101.9)
        capture.frame(pts: 50.9, at: 102.0)
        capture.ingest(line: "[SWDiag] clk=52.00 aLead=0.50 vLead=-2.00 parkedPkts=0", at: 103)  // before +5 s
        capture.ingest(line: "[SWDiag] clk=57.00 aLead=0.50 vLead=0.12 parkedPkts=0", at: 107)
        capture.ingest(line: "[SWDiag] clk=58.00 aLead=0.50 vLead=-0.30 parkedPkts=0", at: 108)
        capture.ingest(line: "[SWDiag] clk=59.00 aLead=0.50 vLead=- parkedPkts=0", at: 109)
        capture.ingest(line: "[HLSServer] GET http://pms.local/seg1.ts", at: 110)

        let sample = try XCTUnwrap(capture.sample())
        XCTAssertEqual(sample.firstFramePTSGap, 0.8, accuracy: 0.0001)
        XCTAssertEqual(sample.firstFrameWallGap, 0.9, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(sample.videoLeadMin), -0.30, accuracy: 0.0001)
        XCTAssertEqual(sample.codec, "mpeg2video")
        XCTAssertEqual(sample.scan, "interlaced")
        XCTAssertEqual(sample.source, "plex_tuned")
        XCTAssertFalse(sample.engineLog.contains { $0.contains("pms.local") }, "only kept prefixes, no URLs")
    }

    func test_noSampleWithoutAPicture() {
        let capture = LiveAVCapture(url: URL(string: "http://iptv.local/live/u/p/1.ts")!)
        capture.ingest(line: "[AudioOutput] seekClock to=5.000 rate=1.0", at: 1)
        XCTAssertNil(capture.sample())
    }

    func test_scanKind() {
        func kind(_ query: String) -> String {
            LiveJoinTelemetry.scanKind(for: URL(string: "http://pms.local/livetv/sessions/a/index.m3u8\(query)")!)
        }
        XCTAssertEqual(kind(""), "none")
        XCTAssertEqual(kind("?rivuletLiveScanType=progressive"), "progressive")
        XCTAssertEqual(kind("?rivuletLiveScanType=Progressive"), "progressive")
        XCTAssertEqual(kind("?rivuletLiveScanType=interlaced"), "interlaced")
        XCTAssertEqual(kind("?rivuletLiveScanType=mbaff"), "interlaced")
    }
}
