// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class ProviderPlaybackVersionTests: XCTestCase {

    private func source(_ id: String, height: Int) -> MediaSource {
        MediaSource(
            id: id, container: "mkv", duration: 100, bitrate: nil, fileSize: nil, fileName: nil,
            videoResolution: nil,
            videoTracks: [VideoTrack(id: "v\(id)", codec: "hevc", profile: nil, level: nil, width: nil,
                                     height: height, frameRate: nil, bitrate: nil, videoRange: .sdr,
                                     isDefault: true, scanType: nil)],
            audioTracks: [], subtitleTracks: [], streamKind: .directPlay, streamURL: nil)
    }

    private func stub() -> StubMediaProvider {
        let provider = StubMediaProvider(id: "jellyfin:srv", kind: .jellyfin)
        provider.detailResult = MediaItemDetail(
            item: JellyfinFixtures.mediaItem("m1"), tagline: nil, genres: [], studios: [], cast: [],
            directors: [], writers: [], chapters: [],
            mediaSources: [source("uhd", height: 2160), source("hd", height: 1080)],
            trailerURL: nil, contentRating: nil, rating: nil, nextEpisode: nil, collections: [])
        provider.streamResult = StreamInfo(source: source("hd", height: 1080), playSessionID: nil,
                                           trackInfoAvailable: true)
        return provider
    }

    private func prepare(_ version: VersionChoice) async throws -> [String] {
        let provider = stub()
        _ = try await ProviderPlayback.prepare(item: JellyfinFixtures.mediaItem("m1"), provider: provider,
                                               version: version)
        return provider.playbackCalls
    }

    func test_best_leavesTheChoiceToTheProvider() async throws {
        let calls = try await prepare(.best)
        XCTAssertTrue(calls.contains("stream(m1,nil)"), "\(calls)")
    }

    func test_source_asksForThatVersion() async throws {
        let calls = try await prepare(.source("uhd"))
        XCTAssertTrue(calls.contains("stream(m1,uhd)"), "\(calls)")
    }

    func test_matchingTier_readsTheListThenAsksForTheMatch() async throws {
        let calls = try await prepare(.matchingTier(1080))
        XCTAssertEqual(calls.first, "detail(m1)")
        XCTAssertTrue(calls.contains("stream(m1,hd)"), "\(calls)")
    }
}
