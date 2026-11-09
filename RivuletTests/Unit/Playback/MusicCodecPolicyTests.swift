// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class MusicCodecPolicyTests: XCTestCase {
    func test_codecsAVPlayerCannotDecodeGoToEngine() {
        for codec in ["truehd", "TrueHD", "dca", "dts", "DTS-HD MA", "dts_hd", "opus", "vorbis",
                      "wmav2", "wmapro", "wmalossless", "ape", "wavpack", "mp2", "dsd_lsbf"] {
            XCTAssertTrue(MusicCodecPolicy.needsEngine(codec: codec), codec)
        }
    }

    func test_codecsAVPlayerDecodesStayOnAVPlayer() {
        for codec in ["aac", "alac", "mp3", "flac", "ac3", "eac3", "pcm_s16le"] {
            XCTAssertFalse(MusicCodecPolicy.needsEngine(codec: codec), codec)
        }
    }

    func test_unknownOrMissingCodecStaysOnAVPlayer() {
        XCTAssertFalse(MusicCodecPolicy.needsEngine(codec: nil))
        XCTAssertFalse(MusicCodecPolicy.needsEngine(codec: ""))
        XCTAssertFalse(MusicCodecPolicy.needsEngine(codec: "somethingnew"))
    }
}
