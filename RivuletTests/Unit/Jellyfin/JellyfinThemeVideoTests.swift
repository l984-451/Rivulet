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
                         client: JellyfinClient(baseURL: baseURL, token: "tok", transport: server.transport))
    }

    private func theme(_ playback: String) {
        server.respond("/Items/movie/ThemeVideos", body: #"{"Items":[{"Id":"backdrop"}]}"#)
        server.respond("/Items/backdrop/PlaybackInfo", body: playback)
    }

    func test_emptyThemesKeepArtworkWithoutResolvingPlayback() async throws {
        server.respond("/Items/movie/ThemeVideos", body: #"{"Items":[],"TotalRecordCount":0}"#)
        let url = try await provider().themeVideoURL(for: ref)
        XCTAssertNil(url)
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(server.requests[0].httpMethod, "GET")
        XCTAssertTrue(server.query(0).contains(URLQueryItem(name: "inheritFromParent", value: "true")))
        XCTAssertTrue(server.query(0).contains(URLQueryItem(name: "userId", value: "user")))
        XCTAssertTrue(server.requests[0].value(forHTTPHeaderField: "Authorization")?.contains("Token=\"tok\"") == true)
    }

    func test_missingItemsKeyIsEmpty() async throws {
        server.respond("/Items/movie/ThemeVideos", body: "{}")
        let url = try await provider().themeVideoURL(for: ref)
        XCTAssertNil(url)
    }

    func test_directVideoUsesBackdropIDAndAsksForNoTranscode() async throws {
        theme(#"{"MediaSources":[{"Id":"source","Container":"mp4","SupportsDirectPlay":true}],"PlaySessionId":"s"}"#)
        let resolved = try await provider().themeVideoURL(for: ref)
        let url = try XCTUnwrap(resolved)
        XCTAssertTrue(url.path.hasSuffix("/Videos/backdrop/stream"))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains(URLQueryItem(name: "ApiKey", value: "tok")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "static", value: "true")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "mediaSourceId", value: "source")))
        XCTAssertFalse(query.contains { $0.name.lowercased() == "playsessionid" })

        XCTAssertEqual(server.requests.count, 2)
        let body = server.jsonBody(1)
        XCTAssertEqual(body["UserId"] as? String, "user")
        XCTAssertEqual(body["SubtitleStreamIndex"] as? Int, -1)
        XCTAssertEqual(body["StartTimeTicks"] as? Int, 0)
        XCTAssertEqual(body["EnableTranscoding"] as? Bool, false)
        let profile = try XCTUnwrap(body["DeviceProfile"] as? [String: Any])
        let direct = try XCTUnwrap((profile["DirectPlayProfiles"] as? [[String: Any]])?.first)
        XCTAssertEqual(direct["Container"] as? String, "mp4,m4v,mov")
        XCTAssertEqual(direct["VideoCodec"] as? String, "h264,hevc")
        XCTAssertEqual((profile["TranscodingProfiles"] as? [Any])?.count, 0)
    }

    func test_aClipThatCannotDirectPlayIsNeverTranscoded() async throws {
        theme(#"{"MediaSources":[{"Id":"source","SupportsDirectPlay":false,"TranscodingUrl":"/videos/backdrop/master.m3u8?PlaySessionId=s"}],"PlaySessionId":"s"}"#)
        let url = try await provider().themeVideoURL(for: ref)
        XCTAssertNil(url)
        XCTAssertEqual(server.requests.count, 2, "No encoding is started or cleaned up")
        XCTAssertFalse(server.requests.contains { $0.httpMethod == "DELETE" })
    }

    func test_reverseProxyBasePathIsKeptOnce() async throws {
        let base = JellyfinFixtures.baseURL.appending(path: "jellyfin")
        theme(#"{"MediaSources":[{"Id":"source","SupportsDirectPlay":true}]}"#)
        let resolved = try await provider(baseURL: base).themeVideoURL(for: ref)
        let url = try XCTUnwrap(resolved)
        XCTAssertEqual(url.path, base.path + "/Videos/backdrop/stream")
        XCTAssertTrue(server.requests.allSatisfy { $0.url?.path.hasPrefix(base.path + "/Items/") == true })
    }

    func test_playbackInfoWithoutSourcesKeepsArtwork() async throws {
        theme(#"{"MediaSources":[],"ErrorCode":"NotAllowed"}"#)
        let url = try await provider().themeVideoURL(for: ref)
        XCTAssertNil(url)
    }

    func test_aServerErrorThrowsForTheCallerToKeepArtwork() async {
        server.respond("/Items/movie/ThemeVideos", status: 404)
        do {
            _ = try await provider().themeVideoURL(for: ref)
            XCTFail("expected a throw")
        } catch {
            guard case MediaProviderError.notFound = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func test_wrongProviderDoesNotMakeRequests() async throws {
        let url = try await provider().themeVideoURL(for: MediaItemRef(providerID: "plex:other", itemID: "movie"))
        XCTAssertNil(url)
        XCTAssertTrue(server.requests.isEmpty)
    }

    func test_multipleThemesIgnoreMissingIDsAndPickOne() async throws {
        server.respond("/Items/movie/ThemeVideos", body: #"{"Items":[{}, {"Id":""}, {"Id":"a"}, {"Id":"b"}]}"#)
        for id in ["a", "b"] {
            server.respond("/Items/\(id)/PlaybackInfo", body: #"{"MediaSources":[{"Id":"s","SupportsDirectPlay":true}]}"#)
        }
        let url = try await provider().themeVideoURL(for: ref)
        XCTAssertNotNil(url)
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertTrue(["/Items/a/PlaybackInfo", "/Items/b/PlaybackInfo"].contains { server.requests[1].url?.path.hasSuffix($0) == true })
    }
}
