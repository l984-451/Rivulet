// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class ProviderPlaybackVersionTests: XCTestCase {

    private func source(_ id: String, height: Int, kbps: Int? = nil,
                        kind: MediaSource.StreamKind = .directPlay) -> MediaSource {
        MediaSource(
            id: id, container: "mkv", duration: 100, bitrate: kbps.map { $0 * 1000 }, fileSize: nil, fileName: nil,
            videoResolution: nil,
            videoTracks: [VideoTrack(id: "v\(id)", codec: "hevc", profile: nil, level: nil, width: nil,
                                     height: height, frameRate: nil, bitrate: nil, videoRange: .sdr,
                                     isDefault: true, scanType: nil)],
            audioTracks: [], subtitleTracks: [], streamKind: kind, streamURL: nil)
    }

    private func stub(sources: [MediaSource]? = nil) -> StubMediaProvider {
        let provider = StubMediaProvider(id: "jellyfin:srv", kind: .jellyfin)
        provider.detailResult = MediaItemDetail(
            item: JellyfinFixtures.mediaItem("m1"), tagline: nil, genres: [], studios: [], cast: [],
            directors: [], writers: [], chapters: [],
            mediaSources: sources ?? [source("uhd", height: 2160), source("hd", height: 1080)],
            trailerURL: nil, contentRating: nil, rating: nil, nextEpisode: nil, collections: [])
        provider.streamResult = StreamInfo(source: source("hd", height: 1080), playSessionID: nil,
                                           trackInfoAvailable: true)
        return provider
    }

    /// A session quality keeps the stored settings and the network out of the test.
    private func prepare(_ version: VersionChoice) async throws -> [String] {
        let provider = stub()
        _ = try await ProviderPlayback.prepare(item: JellyfinFixtures.mediaItem("m1"), provider: provider,
                                               version: version, quality: .original)
        return provider.playbackCalls
    }

    /// A 40 Mbps 4K and a 7 Mbps 1080p, with the 4K playing uncapped.
    private func cappedStub() -> StubMediaProvider {
        let provider = stub(sources: [source("uhd", height: 2160, kbps: 40_000), source("hd", height: 1080, kbps: 7_000)])
        provider.streamResult = StreamInfo(source: source("uhd", height: 2160, kbps: 40_000),
                                           playSessionID: nil, trackInfoAvailable: true)
        return provider
    }

    private let step8 = QualityStep.step(kbps: 8000)!

    func test_cap_overAnExplicitVersion_reResolvesCapped() async throws {
        let provider = cappedStub()
        provider.cappedStreamResult = StreamInfo(source: source("uhd", height: 2160, kind: .hlsTranscode),
                                                 playSessionID: nil, trackInfoAvailable: true)
        let prepared = try await ProviderPlayback.prepare(item: JellyfinFixtures.mediaItem("m1"), provider: provider,
                                                          version: .source("uhd"), quality: .step(step8))
        XCTAssertEqual(provider.resolveBitrates, [nil, 8_000_000])
        XCTAssertEqual(prepared.quality.plan, .transcode(step8))
        XCTAssertEqual(prepared.stream.source.streamKind, .hlsTranscode)
    }

    func test_cap_picksTheVersionThatFits_andPlaysItOriginal() async throws {
        let provider = cappedStub()
        let prepared = try await ProviderPlayback.prepare(item: JellyfinFixtures.mediaItem("m1"), provider: provider,
                                                          quality: .step(QualityStep.step(kbps: 12000)!))
        XCTAssertEqual(provider.playbackCalls.filter { $0.hasPrefix("stream") }, ["stream(m1,nil)", "stream(m1,hd)"])
        XCTAssertEqual(provider.resolveBitrates, [nil, nil])
        XCTAssertEqual(prepared.quality.plan, .original)
    }

    func test_cap_serverThatWontTranscode_playsTheFile() async throws {
        let provider = cappedStub()
        provider.cappedStreamError = MediaProviderError.transcodeRequired
        let prepared = try await ProviderPlayback.prepare(item: JellyfinFixtures.mediaItem("m1"), provider: provider,
                                                          version: .source("uhd"), quality: .step(step8))
        XCTAssertEqual(provider.resolveBitrates, [nil, 8_000_000])
        XCTAssertEqual(prepared.quality.plan, .original)
        XCTAssertEqual(prepared.stream.source.streamKind, .directPlay)
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
