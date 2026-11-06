// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyThemeVideoTests.swift
//  RivuletTests
//
//  Hand-built replies (_unverified): not captured from a live Emby server.
//

import XCTest
@testable import Rivulet

@MainActor
final class EmbyThemeVideoTests: XCTestCase {
    private let server = FakeEmbyServer()
    private let ref = MediaItemRef(providerID: "emby:srv", itemID: "movie")
    private let themes = "/Items/movie/ThemeVideos"

    private func provider(base: URL = EmbyBrowseFixtures.baseURL) -> EmbyProvider {
        EmbyProvider(serverID: "srv", displayName: "Emby", userID: "user", policy: EmbySession.Policy(),
                     client: EmbyClient(baseURL: base, token: "tok", transport: server.transport))
    }

    private func query(_ request: URLRequest) -> [URLQueryItem] {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    private func theme(_ playback: String, base: String = "") {
        server.respond(base + themes, body: #"{"Items":[{"Id":"backdrop","Name":"Theme","Type":"Video"}],"OwnerId":"movie"}"#)
        server.respond(base + "/Items/backdrop/PlaybackInfo", method: "POST", body: playback)
    }

    func test_emptyThemesKeepArtworkWithoutResolvingPlayback_unverified() async throws {
        server.respond(themes, body: #"{"Items":[],"TotalRecordCount":0}"#)
        let url = try await provider().themeVideoURL(for: ref)
        XCTAssertNil(url)
        XCTAssertEqual(server.requests.count, 1)
        let sent = query(server.requests[0])
        XCTAssertTrue(sent.contains(URLQueryItem(name: "InheritFromParent", value: "true")))
        XCTAssertTrue(sent.contains(URLQueryItem(name: "UserId", value: "user")))
        XCTAssertTrue(server.requests[0].value(forHTTPHeaderField: "Authorization")?.hasPrefix("MediaBrowser ") == true)
        XCTAssertNil(server.requests[0].value(forHTTPHeaderField: "X-Emby-Token"))
        XCTAssertTrue(server.headerProblems.isEmpty)
    }

    func test_directVideoUsesApiKeyAndAsksForNoTranscode_unverified() async throws {
        theme(#"{"MediaSources":[{"Id":"mediasource_backdrop","ItemId":"backdrop","Container":"mp4","SupportsDirectPlay":true}],"PlaySessionId":"s"}"#)
        let resolved = try await provider().themeVideoURL(for: ref)
        let url = try XCTUnwrap(resolved)
        XCTAssertEqual(url.path, "/Videos/backdrop/stream")
        let sent = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(sent.contains(URLQueryItem(name: "api_key", value: "tok")))
        XCTAssertTrue(sent.contains(URLQueryItem(name: "static", value: "true")))
        XCTAssertTrue(sent.contains(URLQueryItem(name: "MediaSourceId", value: "mediasource_backdrop")))
        XCTAssertFalse(sent.contains { $0.name.lowercased() == "playsessionid" })

        let body = (try? JSONSerialization.jsonObject(with: server.requests[1].httpBody ?? Data()) as? [String: Any]) ?? [:]
        XCTAssertEqual(server.requests[1].httpMethod, "POST")
        XCTAssertEqual(body["EnableTranscoding"] as? Bool, false)
        XCTAssertEqual(body["UserId"] as? String, "user")
        let profile = try XCTUnwrap(body["DeviceProfile"] as? [String: Any])
        let direct = try XCTUnwrap((profile["DirectPlayProfiles"] as? [[String: Any]])?.first)
        XCTAssertEqual(direct["Container"] as? String, "mp4,m4v,mov")
        XCTAssertEqual((profile["TranscodingProfiles"] as? [Any])?.count, 0)
        XCTAssertTrue(server.headerProblems.isEmpty)
    }

    func test_aClipThatCannotDirectPlayIsNeverTranscoded_unverified() async throws {
        theme(#"{"MediaSources":[{"Id":"s","ItemId":"backdrop","SupportsDirectPlay":false,"TranscodingUrl":"/videos/backdrop/master.m3u8"}]}"#)
        let url = try await provider().themeVideoURL(for: ref)
        XCTAssertNil(url)
        XCTAssertEqual(server.requests.count, 2)
    }

    func test_proxySubpathIsKeptAndNeverAnEmbyPrefixAdded_unverified() async throws {
        let base = try XCTUnwrap(URL(string: "http://emby.local:8096/media"))
        theme(#"{"MediaSources":[{"Id":"s","ItemId":"backdrop","SupportsDirectPlay":true}]}"#, base: "/media")
        let resolved = try await provider(base: base).themeVideoURL(for: ref)
        XCTAssertEqual(try XCTUnwrap(resolved).path, "/media/Videos/backdrop/stream")
        XCTAssertTrue(server.requests.allSatisfy { $0.url?.path.hasPrefix("/media/Items/") == true })
    }

    func test_numericItemIdsAreRead_unverified() async throws {
        server.respond(themes, body: #"{"Items":[{"Id":42,"Name":"Theme","Type":"Video"}]}"#)
        server.respond("/Items/42/PlaybackInfo", method: "POST", body: #"{"MediaSources":[{"Id":"s","SupportsDirectPlay":true}]}"#)
        let resolved = try await provider().themeVideoURL(for: ref)
        XCTAssertEqual(try XCTUnwrap(resolved).path, "/Videos/42/stream")
    }

    func test_noSourcesKeepsArtwork_unverified() async throws {
        theme(#"{"MediaSources":[],"ErrorCode":"NoCompatibleStream"}"#)
        let url = try await provider().themeVideoURL(for: ref)
        XCTAssertNil(url)
    }

    func test_wrongProviderDoesNotMakeRequests() async throws {
        let url = try await provider().themeVideoURL(for: MediaItemRef(providerID: "jellyfin:srv", itemID: "movie"))
        XCTAssertNil(url)
        XCTAssertTrue(server.requests.isEmpty)
    }
}
