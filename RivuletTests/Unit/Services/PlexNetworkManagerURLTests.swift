// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexNetworkManagerURLTests.swift
//  RivuletTests
//
//  Unit tests for PlexNetworkManager URL building methods
//

import XCTest
@testable import Rivulet

final class PlexNetworkManagerURLTests: XCTestCase {

    let networkManager = PlexNetworkManager.shared
    let testServerURL = "https://192.168.1.100:32400"
    let testAuthToken = "test-auth-token"
    let testRatingKey = "12345"

    // MARK: - Direct Play URL Tests

    func testBuildDirectPlayURLIncludesToken() {
        let url = networkManager.buildStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            partKey: "/library/parts/67890/file.mp4",
            container: "mp4",
            strategy: .directPlay
        )

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("X-Plex-Token=\(testAuthToken)"))
    }

    func testBuildDirectPlayURLIncludesClientIdentifier() {
        let url = networkManager.buildStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            partKey: "/library/parts/67890/file.mp4",
            container: "mp4",
            strategy: .directPlay
        )

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("X-Plex-Client-Identifier="))
    }

    func testBuildDirectPlayURLPreservesExistingQueryParams() {
        // IVA trailers have quality params like fmt=4&bitrate=5000
        let partKey = "/library/parts/67890/file.mp4?fmt=4&bitrate=5000"
        let url = networkManager.buildStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            partKey: partKey,
            container: "mp4",
            strategy: .directPlay
        )

        XCTAssertNotNil(url)
        // Should preserve the original query params AND add Plex params
        let urlString = url!.absoluteString
        XCTAssertTrue(urlString.contains("fmt=4"))
        XCTAssertTrue(urlString.contains("bitrate=5000"))
        XCTAssertTrue(urlString.contains("X-Plex-Token="))
    }

    func testBuildDirectPlayURLReturnsNilForNonDirectPlayableContainers() {
        // MKV is not direct-playable on Apple TV
        let url = networkManager.buildStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            partKey: "/library/parts/67890/file.mkv",
            container: "mkv",
            strategy: .directPlay
        )

        XCTAssertNil(url, "MKV container should return nil for direct play")
    }

    func testBuildDirectPlayURLAcceptsMP4Container() {
        let url = networkManager.buildStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            partKey: "/library/parts/67890/file.mp4",
            container: "mp4",
            strategy: .directPlay
        )

        XCTAssertNotNil(url)
    }

    func testBuildDirectPlayURLAcceptsM4VContainer() {
        let url = networkManager.buildStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            partKey: "/library/parts/67890/file.m4v",
            container: "m4v",
            strategy: .directPlay
        )

        XCTAssertNotNil(url)
    }

    func testBuildDirectPlayURLAcceptsMOVContainer() {
        let url = networkManager.buildStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            partKey: "/library/parts/67890/file.mov",
            container: "mov",
            strategy: .directPlay
        )

        XCTAssertNotNil(url)
    }

    func testBuildDirectPlayURLAcceptsAudioContainers() {
        let audioContainers = ["mp3", "flac", "m4a", "aac"]

        for container in audioContainers {
            let url = networkManager.buildStreamURL(
                serverURL: testServerURL,
                authToken: testAuthToken,
                ratingKey: testRatingKey,
                partKey: "/library/parts/67890/file.\(container)",
                container: container,
                strategy: .directPlay,
                isAudio: true
            )

            XCTAssertNotNil(url, "Audio container \(container) should be direct-playable")
        }
    }

    // MARK: - Direct Stream URL Tests

    func testBuildDirectStreamURLUsesTranscodeEndpoint() {
        let url = networkManager.buildStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            strategy: .directStream
        )

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("/video/:/transcode/universal/start.m3u8"))
    }

    func testBuildDirectStreamURLIncludesMediaPath() {
        let url = networkManager.buildStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            strategy: .directStream
        )

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("path=/library/metadata/\(testRatingKey)"))
    }

    func testBuildDirectStreamURLUsesAudioEndpointForAudio() {
        let url = networkManager.buildStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            strategy: .directStream,
            isAudio: true
        )

        XCTAssertNotNil(url)
        // Audio endpoint is /music/:/transcode/... (with two colons)
        XCTAssertTrue(url!.absoluteString.contains("/music/:/transcode/universal/start.m3u8"))
    }

    // MARK: - HLS Transcode URL Tests

    func testBuildHLSTranscodeURLUsesTranscodeEndpoint() {
        let url = networkManager.buildStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            strategy: .hlsTranscode
        )

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("/video/:/transcode/universal/start.m3u8"))
    }

    func testBuildHLSTranscodeURLIncludesProtocolParameter() {
        let url = networkManager.buildStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            strategy: .hlsTranscode
        )

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("protocol=hls"))
    }

    func testBuildHLSTranscodeURLIncludesOffset() {
        let offsetMs = 60000 // 1 minute
        let url = networkManager.buildStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            strategy: .hlsTranscode,
            offsetMs: offsetMs
        )

        XCTAssertNotNil(url)
        // Offset is converted from ms to seconds
        XCTAssertTrue(url!.absoluteString.contains("offset=60"))
    }

    // MARK: - HLS Direct Play URL (Dolby Vision) Tests

    func test_buildHLSDirectPlayURL_sendsTheVersionIndex() throws {
        let result = try XCTUnwrap(networkManager.buildHLSDirectPlayURL(
            serverURL: testServerURL, authToken: testAuthToken, ratingKey: testRatingKey, mediaIndex: 1))
        let items = URLComponents(url: result.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "mediaIndex" }?.value, "1")
    }

    func testBuildHLSDirectPlayURLReturnsURLAndHeaders() {
        let result = networkManager.buildHLSDirectPlayURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey
        )

        XCTAssertNotNil(result)
        XCTAssertNotNil(result?.url)
        XCTAssertNotNil(result?.headers)
        XCTAssertFalse(result!.headers.isEmpty)
    }

    func testBuildHLSDirectPlayURLIncludesToken() {
        let result = networkManager.buildHLSDirectPlayURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey
        )

        XCTAssertNotNil(result)
        // Token may be in URL or in headers
        let tokenInURL = result!.url.absoluteString.contains("X-Plex-Token=\(testAuthToken)")
        let tokenInHeaders = result!.headers["X-Plex-Token"] == testAuthToken
        XCTAssertTrue(tokenInURL || tokenInHeaders, "Token should be in URL or headers")
    }

    func testBuildHLSDirectPlayURLIncludesClientProfile() {
        let result = networkManager.buildHLSDirectPlayURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            hasHDR: true,
            useDolbyVision: true
        )

        XCTAssertNotNil(result)
        let urlString = result!.url.absoluteString
        // Should include client profile for Dolby Vision
        XCTAssertTrue(urlString.contains("X-Plex-Client-Profile-Extra=") || urlString.contains("X-Plex-Client-Profile-Name="))
    }

    func testBuildHLSDirectPlayURLSetsForceVideoTranscode() {
        let result = networkManager.buildHLSDirectPlayURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            forceVideoTranscode: true
        )

        XCTAssertNotNil(result)
        // When forcing transcode, video should not be direct streamed
        let urlString = result!.url.absoluteString
        XCTAssertTrue(urlString.contains("videoCodec="))
    }

    // MARK: - Relay Transcode Cap Tests

    let relayServerURL = "https://178-79-141-27.6278e200ff8e4a93bfd8914adbc90a4b.plex.direct:8443"

    func testBuildHLSDirectPlayURLRelayServerAppliesCap() {
        let result = networkManager.buildHLSDirectPlayURL(
            serverURL: relayServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey
        )

        XCTAssertNotNil(result)
        let urlString = result!.url.absoluteString
        // 1.5 Mbps 480p rung: real transcode, not remux, with capped audio.
        XCTAssertTrue(urlString.contains("maxVideoBitrate=1500"))
        XCTAssertTrue(urlString.contains("videoResolution=720x480"))
        XCTAssertTrue(urlString.contains("directPlay=0"))
        XCTAssertTrue(urlString.contains("directStream=0"))
        XCTAssertTrue(urlString.contains("audioBitrate=320"))
        XCTAssertTrue(urlString.contains("directStreamAudio=0"))
    }

    func testBuildHLSDirectPlayURLDirectServerHasNoCap() {
        // Regression guard: a directly reachable server must be untouched by
        // the relay cap (byte-for-byte behavior preserved for non-relay).
        let result = networkManager.buildHLSDirectPlayURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey
        )

        XCTAssertNotNil(result)
        let urlString = result!.url.absoluteString
        XCTAssertFalse(urlString.contains("maxVideoBitrate="))
        XCTAssertFalse(urlString.contains("videoResolution=720x480"))
        XCTAssertTrue(urlString.contains("videoResolution=4096x2160"))
        XCTAssertTrue(urlString.contains("directPlay=1"))
        XCTAssertTrue(urlString.contains("audioBitrate=1024"))
    }

    // MARK: - Quality Step Cap Tests

    private func query(_ result: (url: URL, headers: [String: String])?) -> [String: String] {
        let items = URLComponents(url: result!.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    func testBuildHLSDirectPlayURLStepCapsLANTranscode() {
        let result = networkManager.buildHLSDirectPlayURL(
            serverURL: testServerURL, authToken: testAuthToken, ratingKey: testRatingKey,
            step: QualityStep.step(kbps: 8000))
        let q = query(result)
        XCTAssertEqual(q["maxVideoBitrate"], "8000")
        XCTAssertEqual(q["videoResolution"], "1920x1080")
        XCTAssertEqual(q["directPlay"], "0")
        XCTAssertEqual(q["directStream"], "0")
        XCTAssertEqual(q["videoCodec"], "h264")
        XCTAssertEqual(q["directStreamAudio"], "1")
        XCTAssertEqual(q["audioBitrate"], "1024")
        XCTAssertEqual(q["X-Plex-Client-Profile-Name"], "Generic")
        XCTAssertTrue(result!.headers["X-Plex-Client-Profile-Extra"]!.contains("name=video.bitrate&value=8000"))
    }

    func testBuildHLSDirectPlayURLLowStepTranscodesAudio() {
        let q = query(networkManager.buildHLSDirectPlayURL(
            serverURL: testServerURL, authToken: testAuthToken, ratingKey: testRatingKey,
            step: QualityStep.step(kbps: 2000)))
        XCTAssertEqual(q["maxVideoBitrate"], "2000")
        XCTAssertEqual(q["videoResolution"], "1280x720")
        XCTAssertEqual(q["directStreamAudio"], "0")
        XCTAssertEqual(q["audioBitrate"], "320")
    }

    func testBuildHLSDirectPlayURLRelayClampsHighStepToRelay() {
        let plain = query(networkManager.buildHLSDirectPlayURL(
            serverURL: relayServerURL, authToken: testAuthToken, ratingKey: testRatingKey))
        let stepped = query(networkManager.buildHLSDirectPlayURL(
            serverURL: relayServerURL, authToken: testAuthToken, ratingKey: testRatingKey,
            step: QualityStep.step(kbps: 8000)))
        // Identical apart from the random session id.
        XCTAssertEqual(plain.filter { $0.key != "session" }, stepped.filter { $0.key != "session" })
        XCTAssertEqual(stepped["maxVideoBitrate"], "1500")
        XCTAssertEqual(stepped["videoResolution"], "720x480")
    }

    func testBuildHLSDirectPlayURLRelayKeepsLowerStep() {
        let q = query(networkManager.buildHLSDirectPlayURL(
            serverURL: relayServerURL, authToken: testAuthToken, ratingKey: testRatingKey,
            step: QualityStep.step(kbps: 720)))
        XCTAssertEqual(q["maxVideoBitrate"], "720")
        XCTAssertEqual(q["videoResolution"], "576x320")
    }

    // MARK: - Direct Play URL Tests

    func testBuildPlaybackDirectPlayURLIncludesPartKey() {
        let partKey = "/library/parts/67890/0/file.mkv"
        let url = networkManager.buildPlaybackDirectPlayURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            partKey: partKey
        )

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains(partKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? partKey))
    }

    /// Issue #255: a part key can carry its own query string (IVA extras arrive
    /// as .../video.mp4?fmt=4&bitrate=5000). This builder ASSIGNED queryItems
    /// rather than appending, silently dropping them — while its sibling
    /// buildDirectPlayURL, 25 lines above, preserved them by name.
    func testBuildPlaybackDirectPlayURLPreservesPartKeyQueryItems() {
        let url = networkManager.buildPlaybackDirectPlayURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            partKey: "/services/iva/assets/715933/video.mp4?fmt=4&bitrate=5000"
        )

        XCTAssertNotNil(url)
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "fmt" })?.value, "4")
        XCTAssertEqual(items.first(where: { $0.name == "bitrate" })?.value, "5000")
        XCTAssertEqual(items.first(where: { $0.name == "X-Plex-Token" })?.value, testAuthToken)
        XCTAssertEqual(url!.path, "/services/iva/assets/715933/video.mp4")
    }

    func testBuildPlaybackDirectPlayURLIncludesAllPlexHeaders() {
        let url = networkManager.buildPlaybackDirectPlayURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            partKey: "/library/parts/67890/0/file.mkv"
        )

        XCTAssertNotNil(url)
        let urlString = url!.absoluteString
        XCTAssertTrue(urlString.contains("X-Plex-Token="))
        XCTAssertTrue(urlString.contains("X-Plex-Client-Identifier="))
        XCTAssertTrue(urlString.contains("X-Plex-Platform="))
        XCTAssertTrue(urlString.contains("X-Plex-Device="))
        XCTAssertTrue(urlString.contains("X-Plex-Product="))
    }

    // MARK: - Thumbnail URL Tests

    func testBuildThumbnailURLSetsCorrectDimensions() {
        let width = 300
        let height = 450
        let url = networkManager.buildThumbnailURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            thumbPath: "/library/metadata/12345/thumb/1234567890",
            width: width,
            height: height
        )

        XCTAssertNotNil(url)
        let urlString = url!.absoluteString
        XCTAssertTrue(urlString.contains("width=\(width)"))
        XCTAssertTrue(urlString.contains("height=\(height)"))
    }

    func testBuildThumbnailURLUsesTranscodeEndpoint() {
        let url = networkManager.buildThumbnailURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            thumbPath: "/library/metadata/12345/thumb/1234567890"
        )

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("/photo/:/transcode"))
    }

    func testBuildThumbnailURLIncludesThumbPath() {
        let thumbPath = "/library/metadata/12345/thumb/1234567890"
        let url = networkManager.buildThumbnailURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            thumbPath: thumbPath
        )

        XCTAssertNotNil(url)
        // The thumb path should be URL-encoded as a query parameter
        XCTAssertTrue(url!.absoluteString.contains("url="))
    }

    func testBuildThumbnailURLIncludesToken() {
        let url = networkManager.buildThumbnailURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            thumbPath: "/library/metadata/12345/thumb/1234567890"
        )

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("X-Plex-Token=\(testAuthToken)"))
    }

    func testBuildThumbnailURLUsesDefaultDimensions() {
        let url = networkManager.buildThumbnailURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            thumbPath: "/library/metadata/12345/thumb/1234567890"
        )

        XCTAssertNotNil(url)
        let urlString = url!.absoluteString
        // Default dimensions are 400x600
        XCTAssertTrue(urlString.contains("width=400"))
        XCTAssertTrue(urlString.contains("height=600"))
    }

    // MARK: - Live TV Stream URL Tests

    func testBuildLiveTVStreamURLIncludesChannelKey() {
        let channelKey = "/livetv/sessions/12345/playback"
        let url = networkManager.buildLiveTVStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            channelKey: channelKey
        )

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains(channelKey))
    }

    func testBuildLiveTVStreamURLIncludesPlexHeaders() {
        let url = networkManager.buildLiveTVStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            channelKey: "/livetv/sessions/12345/playback"
        )

        XCTAssertNotNil(url)
        let urlString = url!.absoluteString
        XCTAssertTrue(urlString.contains("X-Plex-Token="))
        XCTAssertTrue(urlString.contains("X-Plex-Client-Identifier="))
    }

    // MARK: - Plex Headers Tests

    func testPlexHeadersIncludesAllRequiredHeaders() {
        let headers = networkManager.plexHeaders(authToken: testAuthToken)

        XCTAssertEqual(headers["X-Plex-Token"], testAuthToken)
        XCTAssertNotNil(headers["X-Plex-Client-Identifier"])
        XCTAssertNotNil(headers["X-Plex-Product"])
        XCTAssertNotNil(headers["X-Plex-Platform"])
        XCTAssertNotNil(headers["X-Plex-Device"])
    }

    // MARK: - Hub Items URL Tests

    // Hub keys are real ones from /hubs/sections/{1,2}?count=24 on PMS 1.43.4
    // (2026-09-30). The token travels in headers, so none appears here.

    private let pageStart = URLQueryItem(name: "X-Plex-Container-Start", value: "24")
    private let pageSize = URLQueryItem(name: "X-Plex-Container-Size", value: "24")

    private func hubQuery(_ url: URL?) -> [URLQueryItem]? {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
    }

    /// movie.recentlyadded.1. Dropping the key's query paged the whole
    /// library in title order ("The Adventures of Huck Finn" at slot 25).
    func testHubItemsURLKeepsHubKeySort() {
        let url = PlexNetworkManager.hubItemsURL(
            serverURL: testServerURL,
            hubKey: "/library/sections/1/all?sort=addedAt:desc",
            hubIdentifier: "movie.recentlyadded.1",
            start: 24,
            count: 24
        )
        XCTAssertEqual(url?.path, "/library/sections/1/all")
        XCTAssertEqual(hubQuery(url), [URLQueryItem(name: "sort", value: "addedAt:desc"), pageStart, pageSize])
    }

    /// movie.genre.1.80. The '>' goes out percent-encoded; PMS answers
    /// `audienceRating%3E=7.0` with the same 61 matches as the raw form.
    func testHubItemsURLKeepsHubKeyFilters() {
        let url = PlexNetworkManager.hubItemsURL(
            serverURL: testServerURL,
            hubKey: "/library/sections/1/all?unwatched=1&genre=80&audienceRating>=7.0",
            hubIdentifier: "movie.genre.1.80",
            start: 24,
            count: 24
        )
        XCTAssertEqual(hubQuery(url), [
            URLQueryItem(name: "unwatched", value: "1"),
            URLQueryItem(name: "genre", value: "80"),
            URLQueryItem(name: "audienceRating>", value: "7.0"),
            pageStart,
            pageSize
        ])
    }

    func testHubItemsURLCollectionChildrenGainsOnlyPaging() {
        let url = PlexNetworkManager.hubItemsURL(
            serverURL: testServerURL,
            hubKey: "/library/collections/9144/children",
            hubIdentifier: nil,
            start: 0,
            count: 24
        )
        XCTAssertEqual(url?.path, "/library/collections/9144/children")
        XCTAssertEqual(hubQuery(url), [
            URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "24")
        ])
    }

    func testHubItemsURLHubsItemsAddsIdentifier() {
        let url = PlexNetworkManager.hubItemsURL(
            serverURL: testServerURL,
            hubKey: "/hubs/items",
            hubIdentifier: "home.movies.recent",
            start: 24,
            count: 24
        )
        XCTAssertEqual(url?.path, "/hubs/items")
        XCTAssertEqual(hubQuery(url), [pageStart, pageSize, URLQueryItem(name: "identifier", value: "home.movies.recent")])
    }

    /// Plex answers 404 without the identifier; getHubItems returns an empty
    /// page for nil, as it did before.
    func testHubItemsURLHubsItemsWithoutIdentifierIsNil() {
        XCTAssertNil(PlexNetworkManager.hubItemsURL(
            serverURL: testServerURL, hubKey: "/hubs/items", hubIdentifier: nil, start: 0, count: 24))
        XCTAssertNil(PlexNetworkManager.hubItemsURL(
            serverURL: testServerURL, hubKey: "/hubs/items", hubIdentifier: "", start: 0, count: 24))
    }

    /// PMS serves a stale cached Continue Watching for a repeated URL (with
    /// tvOS's Accept-Language), so each request must be a different URL.
    func testContinueWatchingURLIsUniquePerCall() throws {
        let first = try XCTUnwrap(PlexNetworkManager.continueWatchingURL(
            serverURL: testServerURL, count: 50, now: Date(timeIntervalSince1970: 1_000)))
        let second = try XCTUnwrap(PlexNetworkManager.continueWatchingURL(
            serverURL: testServerURL, count: 50, now: Date(timeIntervalSince1970: 1_000.5)))
        XCTAssertEqual(first.path, "/hubs/continueWatching")
        XCTAssertNotEqual(first, second)
        let items = URLComponents(url: first, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(items.contains(URLQueryItem(name: "X-Plex-Container-Start", value: "0")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "X-Plex-Container-Size", value: "50")))
    }
}
