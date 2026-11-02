// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class JellyfinThemeVideoTests: XCTestCase {
    private let server = FakeJellyfinServer()
    private let ref = MediaItemRef(providerID: "jellyfin:srv", itemID: "movie")

    private func provider(baseURL: URL = JellyfinFixtures.baseURL) -> JellyfinProvider {
        JellyfinProvider(serverID: "srv", displayName: "Test", userID: "user",
                         client: JellyfinClient(baseURL: baseURL, token: "tok",
                                                transport: server.transport))
    }

    private func theme(_ playback: String) {
        server.respond("/Items/movie/ThemeVideos", body: #"{"Items":[{"Id":"backdrop"}]}"#)
        server.respond("/Items/backdrop/PlaybackInfo", body: playback)
    }

    func test_emptyThemesKeepArtworkWithoutResolvingPlayback() async throws {
        server.respond("/Items/movie/ThemeVideos", body: #"{"Items":[],"TotalRecordCount":0}"#)
        let video = try await provider().themeVideo(for: ref)
        XCTAssertNil(video)
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertTrue(server.query(0).contains(URLQueryItem(name: "inheritFromParent", value: "true")))
        XCTAssertTrue(server.query(0).contains(URLQueryItem(name: "userId", value: "user")))
        XCTAssertTrue(server.requests[0].value(forHTTPHeaderField: "Authorization")?.contains("Token=\"tok\"") == true)
    }

    func test_directVideoUsesBackdropIDAndNativePlayerProfile() async throws {
        theme(#"{"MediaSources":[{"Id":"source","Container":"mp4","SupportsDirectPlay":true}],"PlaySessionId":"theme-session"}"#)
        let resolved = try await provider().themeVideo(for: ref)
        let video = try XCTUnwrap(resolved)
        XCTAssertTrue(video.url.path.hasSuffix("/Videos/backdrop/stream"))
        let query = URLComponents(url: video.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains(URLQueryItem(name: "ApiKey", value: "tok")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "static", value: "true")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "mediaSourceId", value: "source")))
        let body = server.jsonBody(1)
        XCTAssertEqual(body["UserId"] as? String, "user")
        XCTAssertEqual(body["SubtitleStreamIndex"] as? Int, -1)
        XCTAssertEqual(body["StartTimeTicks"] as? Int, 0)
        let profile = try XCTUnwrap(body["DeviceProfile"] as? [String: Any])
        let direct = try XCTUnwrap((profile["DirectPlayProfiles"] as? [[String: Any]])?.first)
        XCTAssertEqual(direct["Container"] as? String, "mp4,m4v,mov")
        XCTAssertEqual(direct["VideoCodec"] as? String, "h264,hevc")
        let transcode = try XCTUnwrap((profile["TranscodingProfiles"] as? [[String: Any]])?.first)
        XCTAssertEqual(transcode["Protocol"] as? String, "hls")
        XCTAssertEqual(transcode["VideoCodec"] as? String, "h264")
        XCTAssertEqual(transcode["AudioCodec"] as? String, "aac")
        await video.stop()
        XCTAssertEqual(server.requests.count, 2, "Direct playback has no encoding to stop and must not report watch progress")
    }

    func test_transcodeCleanupTargetsOnlyItsSessionAndNeverReportsWatchProgress() async throws {
        theme(#"{"MediaSources":[{"Id":"source","SupportsDirectPlay":false,"TranscodingUrl":"/videos/backdrop/master.m3u8?PlaySessionId=theme-session"}],"PlaySessionId":"theme-session"}"#)
        server.respond("/Videos/ActiveEncodings", status: 204)
        let resolved = try await provider().themeVideo(for: ref)
        let video = try XCTUnwrap(resolved)
        XCTAssertEqual(video.url.path, JellyfinFixtures.baseURL.path + "/videos/backdrop/master.m3u8")
        XCTAssertTrue(video.url.absoluteString.contains("ApiKey=tok"))
        await video.stop()
        XCTAssertEqual(server.requests.count, 3)
        XCTAssertEqual(server.requests[2].httpMethod, "DELETE")
        XCTAssertTrue(server.query(2).contains(URLQueryItem(name: "playSessionId", value: "theme-session")))
        XCTAssertTrue(server.query(2).contains { $0.name == "deviceId" && $0.value?.isEmpty == false })
        XCTAssertFalse(server.requests.contains { $0.url?.path.contains("Sessions/Playing") == true })
    }

    func test_transcodeDoesNotDuplicateReverseProxyPathOrToken() async throws {
        let base = JellyfinFixtures.baseURL.appending(path: "jellyfin")
        let prefix = base.path
        theme("""
            {"MediaSources":[{"SupportsDirectPlay":false,
            "TranscodingUrl":"\(prefix)/videos/backdrop/master.m3u8?ApiKey=tok"}],"PlaySessionId":"session"}
            """)
        let resolved = try await provider(baseURL: base).themeVideo(for: ref)
        let video = try XCTUnwrap(resolved)
        XCTAssertEqual(video.url.path, prefix + "/videos/backdrop/master.m3u8")
        let query = URLComponents(url: video.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.filter { $0.name == "ApiKey" }.count, 1)
    }

    func test_unplayableThemeKeepsArtwork() async throws {
        theme(#"{"MediaSources":[{"SupportsDirectPlay":false}],"ErrorCode":"NotAllowed"}"#)
        let video = try await provider().themeVideo(for: ref)
        XCTAssertNil(video)
    }

    func test_transcodeWithoutSessionIsNotStarted() async throws {
        theme(#"{"MediaSources":[{"TranscodingUrl":"/videos/backdrop/master.m3u8"}]}"#)
        let video = try await provider().themeVideo(for: ref)
        XCTAssertNil(video, "Every transcode must have a session ID for scoped cleanup")
    }

    func test_wrongProviderDoesNotMakeRequests() async throws {
        let video = try await provider().themeVideo(for: MediaItemRef(providerID: "plex:other", itemID: "movie"))
        XCTAssertNil(video)
        XCTAssertTrue(server.requests.isEmpty)
    }

    func test_multipleThemesChooseAValidVideoAndIgnoreMissingIDs() async throws {
        server.respond("/Items/movie/ThemeVideos", body: #"{"Items":[{}, {"Id":""}, {"Id":"a"}, {"Id":"b"}]}"#)
        for id in ["a", "b"] {
            server.respond("/Items/\(id)/PlaybackInfo", body: #"{"MediaSources":[{"SupportsDirectPlay":true}]}"#)
        }
        let video = try await provider().themeVideo(for: ref)
        XCTAssertNotNil(video)
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertTrue(["/Items/a/PlaybackInfo", "/Items/b/PlaybackInfo"].contains { server.requests[1].url?.path.hasSuffix($0) == true })
    }
}
