// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Masters measured on PMS 1.43.4 (#677).
@MainActor
final class DisplayCriteriaHLSVariantTests: XCTestCase {
    private typealias Mode = DisplayCriteriaManager.HLSVariantMode

    private func master(_ attributes: String) -> String {
        "#EXTM3U\n#EXT-X-STREAM-INF:PROGRAM-ID=1,\(attributes)\nsession/s/base/index.m3u8\n"
            + "#EXT-X-I-FRAME-STREAM-INF:RESOLUTION=320x180,BANDWIDTH=1000000,URI=\"session/s/keyframes/index.m3u8\""
    }

    func test_hevcEncodeWithoutCodecsIsHDR10() {
        let mode = Mode(masterPlaylist: master("BANDWIDTH=7614000,RESOLUTION=1920x1080,FRAME-RATE=24.000000,VIDEO-RANGE=PQ"))
        XCTAssertEqual(mode, Mode(frameRate: 24, width: 1920, height: 1080, isDolbyVision: false, isHDR10: true, isHLG: false))
    }

    func test_hevcEncodeWithItsWrongCodecsIsStillHDR10() {
        let mode = Mode(masterPlaylist: master(#"BANDWIDTH=7614000,RESOLUTION=1920x1080,FRAME-RATE=24.000000,VIDEO-RANGE=PQ,CODECS="hev1.1.1.L93,mp4a.40.2""#))
        XCTAssertEqual(mode?.isHDR10, true)
        XCTAssertEqual(mode?.isDolbyVision, false)
    }

    func test_copiedDolbyVisionIsDolbyVision() {
        let mode = Mode(masterPlaylist: master(#"BANDWIDTH=11508000,RESOLUTION=3840x2160,FRAME-RATE=24.000000,VIDEO-RANGE=PQ,CODECS="dvh1.08.06,ec-3""#))
        XCTAssertEqual(mode, Mode(frameRate: 24, width: 3840, height: 2160, isDolbyVision: true, isHDR10: false, isHLG: false))
    }

    func test_supplementalDolbyVisionIsDolbyVision() {
        let mode = Mode(masterPlaylist: master(#"BANDWIDTH=1,RESOLUTION=3840x2160,FRAME-RATE=23.976,VIDEO-RANGE=PQ,CODECS="hvc1.2.4.L153.b0,ec-3",SUPPLEMENTAL-CODECS="dvh1.08.06/db1p""#))
        XCTAssertEqual(mode?.isDolbyVision, true)
        XCTAssertEqual(mode?.frameRate, 23.976)
    }

    func test_h264EncodeIsSDR() {
        let mode = Mode(masterPlaylist: master(#"BANDWIDTH=7540000,RESOLUTION=1920x804,FRAME-RATE=23.976000,CODECS="avc1.640028,mp4a.40.2""#))
        XCTAssertEqual(mode, Mode(frameRate: 23.976, width: 1920, height: 804, isDolbyVision: false, isHDR10: false, isHLG: false))
    }

    func test_noFrameRateAsksForNothing() {
        XCTAssertNil(Mode(masterPlaylist: master("BANDWIDTH=1,RESOLUTION=1920x1080,VIDEO-RANGE=PQ")))
    }
}
