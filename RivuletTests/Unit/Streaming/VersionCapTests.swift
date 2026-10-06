// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class VersionCapTests: XCTestCase {
    private func media(_ id: Int, _ res: String, kbps: Int?) -> PlexMedia {
        PlexMedia(id: id, duration: nil, bitrate: kbps, width: nil, height: nil, aspectRatio: nil,
                  audioChannels: nil, audioCodec: nil, videoCodec: nil, videoResolution: res,
                  container: nil, videoFrameRate: nil, Part: nil)
    }

    private lazy var versions = [media(1, "4k", kbps: 60000), media(2, "1080", kbps: 10000), media(3, "sd", kbps: 1500)]

    func test_noCap_isUnchanged() {
        XCTAssertEqual(VersionRanking.select(.best, in: versions).serverIndex, 0)
    }

    func test_cap_prefersFittingVersionAtOrAboveStepTier() {
        XCTAssertEqual(VersionRanking.select(.best, in: versions, capKbps: 15000).serverIndex, 1)
    }

    func test_cap_neverDropsToSDWhenStepGivesHD() {
        // 6 Mbps cap -> 4 Mbps 720p step: the SD file fits but is below 720, so transcode the 1080p one.
        XCTAssertEqual(VersionRanking.select(.best, in: versions, capKbps: 6000).serverIndex, 1)
    }

    func test_cap_lowStep_allowsSD() {
        XCTAssertEqual(VersionRanking.select(.best, in: versions, capKbps: 1500).serverIndex, 2)
    }

    func test_explicitSource_ignoresCap() {
        XCTAssertEqual(VersionRanking.select(.source("1"), in: versions, capKbps: 1500).serverIndex, 0)
    }

    func test_matchingTier_capStaysInsideTier() {
        // Up Next kept 4K; under a 15 Mbps cap the 4K pool has no fit, so the 4K file is transcoded.
        XCTAssertEqual(VersionRanking.select(.matchingTier(2160), in: versions, capKbps: 15000).serverIndex, 0)
    }
}
