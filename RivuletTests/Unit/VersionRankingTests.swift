// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class VersionRankingTests: XCTestCase {

    private func source(_ id: String, res: String? = nil, height: Int? = nil,
                        range: VideoTrack.VideoRange = .sdr, bitrate: Int? = nil) -> MediaSource {
        let video = height.map {
            VideoTrack(id: "v\(id)", codec: "hevc", profile: nil, level: nil, width: nil, height: $0,
                       frameRate: nil, bitrate: nil, videoRange: range, isDefault: true, scanType: nil)
        }
        return MediaSource(id: id, container: "mkv", duration: 100, bitrate: bitrate, fileSize: nil,
                           fileName: nil, videoResolution: res, videoTracks: video.map { [$0] } ?? [],
                           audioTracks: [], subtitleTracks: [], streamKind: .directPlay, streamURL: nil)
    }

    private func plexMedia(_ json: String) throws -> [PlexMedia] {
        try JSONDecoder().decode([PlexMedia].self, from: Data(json.utf8))
    }

    // Two Sweeney Todd files, listed SD first so ranking has to reorder them.
    private let sdFirst = """
    [{"id":22249,"videoResolution":"sd","height":336,"bitrate":695,
      "Part":[{"id":2,"key":"/library/parts/2/b.avi","Stream":[{"id":21,"streamType":1,"codec":"mpeg4","height":336}]}]},
     {"id":260721,"videoResolution":"1080","height":1080,"bitrate":6564,
      "Part":[{"id":1,"key":"/library/parts/1/a.mkv","Stream":[{"id":11,"streamType":1,"codec":"hevc","height":1080}]}]}]
    """

    func test_tier_labelBeatsHeight_andCroppedWidescreenIs1080() {
        XCTAssertEqual(VersionRanking.tier(label: "4k", height: 1600), 2160)
        XCTAssertEqual(VersionRanking.tier(label: "sd", height: nil), 480)
        XCTAssertEqual(VersionRanking.tier(label: nil, height: 800), 1080)
        XCTAssertEqual(VersionRanking.tier(label: nil, height: nil), 0)
    }

    func test_ordered_tierBeatsRange_rangeBeatsBitrate() {
        let ranked = VersionRanking.ordered([
            source("hd-sdr-fat", height: 1080, bitrate: 40_000_000),
            source("hd-dv", height: 1080, range: .dolbyVision(profile: 8), bitrate: 8_000_000),
            source("uhd-sdr", height: 2160, bitrate: 1_000_000),
        ])
        XCTAssertEqual(ranked.map(\.id), ["uhd-sdr", "hd-dv", "hd-sdr-fat"])
    }

    func test_ordered_missingBitrateCountsAsZero() {
        let ranked = VersionRanking.ordered([source("a", height: 1080), source("b", height: 1080, bitrate: 1)])
        XCTAssertEqual(ranked.map(\.id), ["b", "a"])
    }

    func test_ordered_tiesKeepServerOrder() {
        let ranked = VersionRanking.ordered([source("first"), source("second"), source("third")])
        XCTAssertEqual(ranked.map(\.id), ["first", "second", "third"])
    }

    func test_ordered_collapsesDuplicateIDs() {
        // PlexMediaMapper emits one MediaSource per Part, all with the Media id.
        let ranked = VersionRanking.ordered([source("m", height: 1080), source("m", height: 1080)])
        XCTAssertEqual(ranked.count, 1)
    }

    func test_choose_sourceAndTier_fallBackToBest() {
        let sources = [source("hd", height: 1080), source("uhd", height: 2160)]
        XCTAssertEqual(VersionRanking.choose(.best, from: sources)?.id, "uhd")
        XCTAssertEqual(VersionRanking.choose(.source("hd"), from: sources)?.id, "hd")
        XCTAssertEqual(VersionRanking.choose(.source("gone"), from: sources)?.id, "uhd")
        XCTAssertEqual(VersionRanking.choose(.matchingTier(1080), from: sources)?.id, "hd")
        XCTAssertEqual(VersionRanking.choose(.matchingTier(720), from: sources)?.id, "uhd")
        XCTAssertNil(VersionRanking.choose(.best, from: []))
    }

    func test_select_movesBestToFront_andReportsServerIndex() throws {
        let selection = VersionRanking.select(.best, in: try plexMedia(sdFirst))
        XCTAssertEqual(selection.media.map(\.id), [260721, 22249])
        XCTAssertEqual(selection.serverIndex, 1)
    }

    func test_select_source_findsTheSameVersionInAFreshServerOrder() throws {
        // A refresh hands back server order; the picked id must come out on top again.
        let selection = VersionRanking.select(.source("22249"), in: try plexMedia(sdFirst))
        XCTAssertEqual(selection.media.first?.id, 22249)
        XCTAssertEqual(selection.serverIndex, 0)
    }

    func test_select_emptyMedia_isANoOp() {
        let selection = VersionRanking.select(.best, in: [])
        XCTAssertTrue(selection.media.isEmpty)
        XCTAssertEqual(selection.serverIndex, 0)
    }

    func test_primarySource_isTheBestVersion() {
        let item = JellyfinFixtures.mediaItem("m1")
        let detail = MediaItemDetail(
            item: item, tagline: nil, genres: [], studios: [], cast: [], directors: [], writers: [],
            chapters: [], mediaSources: [source("hd", height: 1080), source("uhd", height: 2160)],
            trailerURL: nil, contentRating: nil, rating: nil, nextEpisode: nil, collections: [])
        XCTAssertEqual(detail.primarySource?.id, "uhd")
    }
}
