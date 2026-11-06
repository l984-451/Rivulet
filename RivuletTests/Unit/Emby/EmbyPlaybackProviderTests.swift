// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyPlaybackProviderTests.swift
//  RivuletTests
//
//  PlaybackInfo, the direct and hls streams, progress reports and skip markers against
//  FakeEmbyServer replaying real captures. Cases with hand-built replies carry _unverified.
//

import XCTest
@testable import Rivulet

@MainActor
final class EmbyPlaybackProviderTests: XCTestCase {
    private let server = FakeEmbyServer()
    private let uid = EmbyLiveFixtures.userID
    private typealias Fixtures = EmbyPlaybackStreamFixtures
    private let playbackInfo = "/Items/857/PlaybackInfo"

    private func provider(base: URL = EmbyBrowseFixtures.baseURL) -> EmbyProvider {
        EmbyProvider(serverID: "srv", displayName: "Emby", userID: uid, policy: EmbySession.Policy(),
                     client: EmbyClient(baseURL: base, token: "tok", transport: server.transport))
    }

    private func ref(_ id: String) -> MediaItemRef { MediaItemRef(providerID: "emby:srv", itemID: id) }

    private func json(_ data: Data?) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any]) ?? [:]
    }

    private func bodies(_ method: String, _ path: String) -> [[String: Any]] {
        server.requests(method, path).map { json($0.httpBody) }
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let pairs = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(pairs.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    private func playSessionID(of fixture: String) throws -> String {
        let info: EmbyPlaybackInfoResponse = try EmbyTestJSON.decode(fixture)
        return try XCTUnwrap(info.playSessionId)
    }

    /// A forced-transcode capture whose video is H.264 (hand-built: the captures are all HEVC),
    /// with a hex token in place of the capture's placeholder, which a URL would percent-encode.
    private var h264Transcode: String {
        EmbyPlaybackFixtures.forcedTranscode4_10_2
            .replacingOccurrences(of: #""Codec":"hevc""#, with: #""Codec":"h264""#)
            .replacingOccurrences(of: "<ACCESS_TOKEN>", with: "0123abcd")
    }

    override func tearDown() async throws {
        XCTAssertEqual(server.headerProblems, [])
        try await super.tearDown()
    }

    // MARK: - Direct play

    func test_resolveStream_directPlay_buildsTheStaticUrlItself() async throws {
        server.respond(playbackInfo, method: "POST", body: EmbyPlaybackFixtures.directPlay4_10_2)
        let info = try await provider().resolveStream(for: ref("857"), sourceID: nil, maxBitrate: nil)
        let psid = try playSessionID(of: EmbyPlaybackFixtures.directPlay4_10_2)
        XCTAssertEqual(info.source.streamKind, .directPlay)
        XCTAssertEqual(info.playSessionID, psid)
        XCTAssertEqual(
            info.source.streamURL?.absoluteString,
            "http://emby.local:8096/Videos/857/stream?static=true&MediaSourceId=mediasource_857&PlaySessionId=\(psid)&api_key=tok")
        XCTAssertEqual(server.requests.count, 1)
    }

    func test_resolveStream_sendsTheWildcardProfileAndTheCap() async throws {
        server.respond(playbackInfo, method: "POST", body: EmbyPlaybackFixtures.directPlay4_10_2)
        _ = try await provider().resolveStream(for: ref("857"), sourceID: nil, maxBitrate: nil)
        let body = try XCTUnwrap(bodies("POST", playbackInfo).first)
        XCTAssertEqual(body["UserId"] as? String, uid)
        XCTAssertEqual(body["MaxStreamingBitrate"] as? Int, 400_000_000)
        XCTAssertEqual(body["EnableDirectPlay"] as? Bool, true)
        XCTAssertEqual(body["EnableDirectStream"] as? Bool, true)
        XCTAssertEqual(body["EnableTranscoding"] as? Bool, true)
        XCTAssertNil(body["MediaSourceId"])
        XCTAssertNil(body["AllowVideoStreamCopy"])
        let profile = try XCTUnwrap(body["DeviceProfile"] as? [String: Any])
        XCTAssertEqual(profile["MaxStreamingBitrate"] as? Int, 400_000_000)
        let direct = try XCTUnwrap(profile["DirectPlayProfiles"] as? [[String: String]])
        XCTAssertEqual(direct, [["Type": "Video"], ["Type": "Audio"]], "no Container: a wildcard")
        let subtitles = try XCTUnwrap(profile["SubtitleProfiles"] as? [[String: String]])
        XCTAssertEqual(subtitles.count, 13)
        XCTAssertTrue(subtitles.contains(["Format": "srt", "Method": "External"]))
        XCTAssertTrue(subtitles.contains(["Format": "pgssub", "Method": "Embed"]))
    }

    func test_resolveStream_askedForAVersion_sendsItsOpaqueId() async throws {
        server.respond("/Items/19/PlaybackInfo", method: "POST", body: EmbyPlaybackFixtures.directPlay4_8_11)
        let source = try XCTUnwrap(try (EmbyTestJSON.decode(EmbyPlaybackFixtures.directPlay4_8_11) as EmbyPlaybackInfoResponse).mediaSources?.first?.id)
        let info = try await provider().resolveStream(for: ref("19"), sourceID: source, maxBitrate: nil)
        XCTAssertEqual(bodies("POST", "/Items/19/PlaybackInfo").first?["MediaSourceId"] as? String, source)
        XCTAssertEqual(info.source.id, source)
        XCTAssertFalse(source.hasPrefix("mediasource_"), "4.8.11 ids are 32 hex")
    }

    func test_resolveStream_emptySources_isAFailure() async throws {
        server.respond(playbackInfo, method: "POST", body: EmbyPlaybackFixtures.noCompatibleStream)
        do {
            _ = try await provider().resolveStream(for: ref("857"), sourceID: "857", maxBitrate: nil)
            XCTFail("an empty MediaSources list must throw")
        } catch MediaProviderError.notPlayable {
        }
    }

    // MARK: - A cap lands in the transcode

    func test_resolveStream_underACap_playsTheServersTranscode() async throws {
        server.respond("/Items/859/PlaybackInfo", method: "POST", body: Fixtures.baywatchCappedTo8Mbps)
        let info = try await provider().resolveStream(for: ref("859"), sourceID: nil, maxBitrate: 8_000_000)
        let bodies = bodies("POST", "/Items/859/PlaybackInfo")
        XCTAssertEqual(bodies.first?["MaxStreamingBitrate"] as? Int, 8_000_000)
        XCTAssertEqual(bodies.first?["EnableDirectPlay"] as? Bool, true)
        XCTAssertEqual(info.source.streamKind, .hlsTranscode, "SupportsDirectPlay is false: DirectStreamUrl is not proof")
        XCTAssertEqual(bodies.last?["EnableDirectPlay"] as? Bool, false)
        XCTAssertEqual(bodies.last?["MaxStreamingBitrate"] as? Int, 8_000_000)
    }

    // MARK: - hls route

    func test_transcodeStream_playsBasePlusTranscodingUrlAsReturned() async throws {
        server.respond(playbackInfo, method: "POST", body: h264Transcode)
        let info = try await provider().transcodeStream(
            for: ref("857"), sourceID: nil, startTime: 600, maxBitrate: nil, audioStreamIndex: 3, subtitleStreamIndex: 4)
        let raw: EmbyPlaybackInfoResponse = try EmbyTestJSON.decode(h264Transcode)
        let path = try XCTUnwrap(raw.mediaSources?.first?.transcodingUrl)
        XCTAssertEqual(info.source.streamURL?.absoluteString, "http://emby.local:8096" + path)
        XCTAssertEqual(info.source.streamKind, .hlsTranscode)
        XCTAssertEqual(info.playSessionID, raw.playSessionId)
        XCTAssertTrue(path.contains("api_key="), "the master's variant URL copies this query")
    }

    func test_transcodeStream_requestShape() async throws {
        server.respond(playbackInfo, method: "POST", body: h264Transcode)
        _ = try await provider().transcodeStream(
            for: ref("857"), sourceID: nil, startTime: 600, maxBitrate: nil, audioStreamIndex: 3, subtitleStreamIndex: 4)
        let sent = bodies("POST", playbackInfo)
        XCTAssertEqual(sent.count, 1, "an H.264 source needs no second ask")
        let body = try XCTUnwrap(sent.first)
        XCTAssertEqual(body["EnableDirectPlay"] as? Bool, false)
        XCTAssertEqual(body["EnableDirectStream"] as? Bool, false)
        XCTAssertEqual(body["StartTimeTicks"] as? Int, 6_000_000_000)
        XCTAssertEqual(body["AudioStreamIndex"] as? Int, 3)
        XCTAssertEqual(body["SubtitleStreamIndex"] as? Int, 4)
        XCTAssertNil(body["AllowVideoStreamCopy"])
        let profile = try XCTUnwrap(body["DeviceProfile"] as? [String: Any])
        XCTAssertEqual((profile["SubtitleProfiles"] as? [Any])?.count, 0, "a chosen subtitle is burned in")
        let transcoding = try XCTUnwrap((profile["TranscodingProfiles"] as? [[String: Any]])?.first)
        XCTAssertEqual(transcoding["Container"] as? String, "ts")
        XCTAssertEqual(transcoding["VideoCodec"] as? String, "h264")
        XCTAssertEqual(transcoding["Protocol"] as? String, "hls")
        XCTAssertEqual(transcoding["MaxAudioChannels"] as? String, "6")
    }

    func test_transcodeStream_aSourceThatIsNotH264_asksAgainWithTheCopyOff() async throws {
        server.respond(playbackInfo, method: "POST", body: EmbyPlaybackFixtures.forcedTranscode4_10_2)
        let info = try await provider().transcodeStream(
            for: ref("857"), sourceID: nil, startTime: 0, maxBitrate: nil, audioStreamIndex: nil, subtitleStreamIndex: nil)
        let sent = bodies("POST", playbackInfo)
        XCTAssertEqual(sent.count, 2)
        XCTAssertNil(sent[0]["AllowVideoStreamCopy"])
        XCTAssertEqual(sent[1]["AllowVideoStreamCopy"] as? Bool, false)
        XCTAssertEqual(sent[1]["MediaSourceId"] as? String, "mediasource_857", "the same version")
        XCTAssertNil(sent[1]["StartTimeTicks"], "no offset at 0")
        XCTAssertEqual(info.source.streamKind, .hlsTranscode)
    }

    func test_transcodeStream_subtitleOffIsPassedThroughAndUnsetIsOmitted() async throws {
        server.respond(playbackInfo, method: "POST", body: h264Transcode)
        let emby = provider()
        _ = try await emby.transcodeStream(for: ref("857"), sourceID: nil, startTime: 0, maxBitrate: nil,
                                           audioStreamIndex: nil, subtitleStreamIndex: -1)
        _ = try await emby.transcodeStream(for: ref("857"), sourceID: nil, startTime: 0, maxBitrate: nil,
                                           audioStreamIndex: nil, subtitleStreamIndex: nil)
        let sent = bodies("POST", playbackInfo)
        XCTAssertEqual(sent[0]["SubtitleStreamIndex"] as? Int, -1)
        XCTAssertNil(sent[1]["SubtitleStreamIndex"])
    }

    func test_transcodeStream_burnInCaptureCarriesTheSelectedIndex() async throws {
        server.respond(playbackInfo, method: "POST", body: Fixtures.burnIn28yl)
        let info = try await provider().transcodeStream(
            for: ref("857"), sourceID: nil, startTime: 0, maxBitrate: nil, audioStreamIndex: nil, subtitleStreamIndex: 4)
        let url = try XCTUnwrap(info.source.streamURL?.absoluteString)
        XCTAssertTrue(url.contains("SubtitleStreamIndex=4&SubtitleMethod=Encode"))
    }

    func test_transcodeStream_keepsAProxySubpath() async throws {
        server.respond("/proxy/Items/857/PlaybackInfo", method: "POST", body: h264Transcode)
        let emby = provider(base: URL(string: "http://emby.local:8096/proxy/")!)
        let info = try await emby.transcodeStream(
            for: ref("857"), sourceID: nil, startTime: 0, maxBitrate: nil, audioStreamIndex: nil, subtitleStreamIndex: nil)
        let url = try XCTUnwrap(info.source.streamURL)
        XCTAssertTrue(url.absoluteString.hasPrefix("http://emby.local:8096/proxy/videos/857/master.m3u8?"), "\(url)")
    }

    func test_transcodeStream_noTranscodingUrl_isTranscodeRequired() async throws {
        server.respond(playbackInfo, method: "POST", body: EmbyPlaybackFixtures.directPlay4_10_2.replacingOccurrences(
            of: #""Codec":"hevc""#, with: #""Codec":"h264""#))
        do {
            _ = try await provider().transcodeStream(
                for: ref("857"), sourceID: nil, startTime: 0, maxBitrate: nil, audioStreamIndex: nil, subtitleStreamIndex: nil)
            XCTFail("a source with no TranscodingUrl cannot transcode")
        } catch MediaProviderError.transcodeRequired {
        }
    }

    func test_transcodeStream_fourEightEleven_usesItsOpaqueIdInTheUrl() async throws {
        server.respond("/Items/18/PlaybackInfo", method: "POST", body: Fixtures.transcode4_8_11)
        let info = try await provider().transcodeStream(
            for: ref("18"), sourceID: nil, startTime: 0, maxBitrate: nil, audioStreamIndex: nil, subtitleStreamIndex: nil)
        XCTAssertEqual(info.source.id, "f8619462ecf6893a48134924fc3c9e9d")
        XCTAssertTrue(info.source.streamURL?.absoluteString.contains("MediaSourceId=f8619462ecf6893a48134924fc3c9e9d") == true)
    }

    // MARK: - Reports

    func test_reports_carryTheMeasuredBodies() async throws {
        for path in ["/Sessions/Playing", "/Sessions/Playing/Progress", "/Sessions/Playing/Stopped"] {
            server.respond(path, method: "POST", status: 204)
        }
        let reporter = provider().progressReporter(for: ref("874"), sourceID: "mediasource_874", playSessionID: "psid")
        await reporter.start(position: 0)
        await reporter.progress(position: 600)
        await reporter.paused(at: 700)
        await reporter.stopped(at: 1200)

        let playing = try XCTUnwrap(bodies("POST", "/Sessions/Playing").first)
        XCTAssertEqual(Set(playing.keys), ["ItemId", "MediaSourceId", "PlaySessionId", "PositionTicks", "IsPaused", "CanSeek", "PlayMethod"])
        XCTAssertEqual(playing["PlaySessionId"] as? String, "psid")
        XCTAssertEqual(playing["MediaSourceId"] as? String, "mediasource_874")
        XCTAssertEqual(playing["PlayMethod"] as? String, "DirectPlay")
        XCTAssertEqual(playing["IsPaused"] as? Bool, false)
        let progress = bodies("POST", "/Sessions/Playing/Progress")
        XCTAssertEqual(progress.count, 2)
        XCTAssertEqual(progress[0]["PositionTicks"] as? Int, 6_000_000_000)
        XCTAssertEqual(progress[0]["IsPaused"] as? Bool, false)
        XCTAssertEqual(progress[1]["IsPaused"] as? Bool, true, "pause is Progress with IsPaused")
        let stopped = try XCTUnwrap(bodies("POST", "/Sessions/Playing/Stopped").first)
        XCTAssertEqual(stopped["PositionTicks"] as? Int, 12_000_000_000, "a Stopped without a position marks the item played")
        XCTAssertEqual(stopped["PlaySessionId"] as? String, "psid", "it must match the Playing it ends")
        XCTAssertTrue(server.requests("DELETE", "/Videos/ActiveEncodings").isEmpty, "direct play has no encode")
    }

    func test_reports_withoutAPlaySession_areDropped() async throws {
        let reporter = provider().progressReporter(for: ref("874"), sourceID: nil, playSessionID: nil)
        await reporter.start(position: 0)
        await reporter.stopped(at: 10)
        XCTAssertTrue(server.requests.isEmpty)
    }

    func test_stoppingAnHlsSession_endsItsEncode() async throws {
        server.respond(playbackInfo, method: "POST", body: h264Transcode)
        for path in ["/Sessions/Playing", "/Sessions/Playing/Stopped", "/Videos/ActiveEncodings"] {
            server.respond(path, method: path == "/Videos/ActiveEncodings" ? "DELETE" : "POST", status: 204)
        }
        let emby = provider()
        let info = try await emby.transcodeStream(
            for: ref("857"), sourceID: nil, startTime: 0, maxBitrate: nil, audioStreamIndex: nil, subtitleStreamIndex: nil)
        let psid = try XCTUnwrap(info.playSessionID)
        let reporter = emby.progressReporter(for: ref("857"), sourceID: info.source.id, playSessionID: psid)
        await reporter.start(position: 0)
        await reporter.stopped(at: 30)

        XCTAssertEqual(bodies("POST", "/Sessions/Playing").first?["PlayMethod"] as? String, "Transcode")
        let delete = try XCTUnwrap(server.requests("DELETE", "/Videos/ActiveEncodings").first)
        XCTAssertEqual(query(delete)["PlaySessionId"], psid)
        XCTAssertEqual(query(delete)["DeviceId"], "rivulet-research-2", "the device id the TranscodingUrl names")
        XCTAssertEqual(server.requests.last?.httpMethod, "DELETE", "after the Stopped report")
    }

    func test_aDirectPlayReporterForAnotherSession_isNotATranscode() async throws {
        server.respond(playbackInfo, method: "POST", body: h264Transcode)
        server.respond("/Sessions/Playing", method: "POST", status: 204)
        let emby = provider()
        _ = try await emby.transcodeStream(
            for: ref("857"), sourceID: nil, startTime: 0, maxBitrate: nil, audioStreamIndex: nil, subtitleStreamIndex: nil)
        await emby.progressReporter(for: ref("857"), sourceID: nil, playSessionID: "another").start(position: 0)
        XCTAssertEqual(bodies("POST", "/Sessions/Playing").first?["PlayMethod"] as? String, "DirectPlay")
    }

    // MARK: - Skip markers

    private var itemPath: String { "/Users/\(uid)/Items/19" }

    func test_playbackExtras_realChaptersGiveNone() async throws {
        server.respond(itemPath, body: EmbyPlaybackFixtures.movieDetail4_8_11)
        let extras = await provider().playbackExtras(for: ref("19"), sourceID: nil)
        XCTAssertEqual(extras.markers, [], "every chapter is MarkerType Chapter on a free server")
        XCTAssertEqual(server.requests.count, 1, "the item's own Chapters: one read, no PlaybackInfo")
    }

    func test_playbackExtras_readsMarkersFromTheItemChapters_unverified() async throws {
        server.respond(itemPath, body: """
        {"Name":"x","Id":"19","Type":"Movie","RunTimeTicks":33000000000,"Chapters":[
        {"StartPositionTicks":600000000,"Name":"Intro","MarkerType":"IntroStart"},
        {"StartPositionTicks":1500000000,"Name":"","MarkerType":"IntroEnd"},
        {"StartPositionTicks":30000000000,"Name":"Credits","MarkerType":"CreditsStart"}]}
        """)
        let extras = await provider().playbackExtras(for: ref("19"), sourceID: nil)
        XCTAssertEqual(extras.markers, [
            PlaybackMarker(kind: .intro, start: 60, end: 150),
            PlaybackMarker(kind: .credits, start: 3000, end: 3300)
        ])
    }

    func test_playbackExtras_aFailedReadIsEmpty() async {
        let extras = await provider().playbackExtras(for: ref("19"), sourceID: nil)
        XCTAssertEqual(extras.markers, [])
    }

    // MARK: - Detail and track selection

    func test_detailSources_listVersionsWithoutTheToken() async throws {
        server.respond(itemPath, body: EmbyPlaybackFixtures.movieDetail4_8_11)
        let detail = try await provider().fullDetail(for: ref("19"))
        let source = try XCTUnwrap(detail.mediaSources.first)
        XCTAssertEqual(detail.mediaSources.count, 1)
        XCTAssertEqual(source.id.count, 32, "the 4.8.11 opaque id")
        XCTAssertNil(source.streamURL)
        XCTAssertTrue(source.subtitleTracks.compactMap(\.externalURL).allSatisfy { $0.query == nil }, "no token in a detail source")
        XCTAssertFalse(source.videoTracks.isEmpty)
    }

    func test_selectingTracks_isTheEnginesJob() async throws {
        let emby = provider()
        try await emby.setSelectedAudioTrack("1", source: "s", of: ref("857"))
        try await emby.setSelectedSubtitleTrack(nil, source: "s", of: ref("857"))
        XCTAssertTrue(server.requests.isEmpty)
    }
}
