// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ProviderStreamHeadersTests.swift
//  RivuletTests
//
//  A provider stream's request headers (Plex's token and client profile ride in
//  headers, not the URL) reach the player on every route, and a provider's
//  markers arrive after the first frame.
//

import XCTest
@testable import Rivulet

@MainActor
final class ProviderStreamHeadersTests: XCTestCase {

    private let hlsURL = URL(string: "http://plex.local:32400/video/:/transcode/universal/start.m3u8?session=s1")!
    private let directURL = URL(string: "http://plex.local:32400/library/parts/1/1/file.mkv?X-Plex-Token=t")!
    private let headers = ["X-Plex-Token": "tok", "X-Plex-Client-Profile-Extra": "add-limitation(x)"]

    private func source(_ kind: MediaSource.StreamKind, url: URL) -> MediaSource {
        MediaSource(id: "src", container: "mkv", duration: 100, bitrate: nil, fileSize: nil, fileName: nil,
                    videoResolution: "1080", videoTracks: [], audioTracks: [], subtitleTracks: [],
                    streamKind: kind, streamURL: url)
    }

    private func stream(_ kind: MediaSource.StreamKind, url: URL, headers: [String: String]? = nil) -> StreamInfo {
        StreamInfo(source: source(kind, url: url), playSessionID: "ps1", trackInfoAvailable: true,
                   headers: headers ?? self.headers)
    }

    private func playback(_ provider: StubMediaProvider, _ stream: StreamInfo, extrasPending: Bool = false) -> ProviderPlayback {
        let item = JellyfinFixtures.mediaItem("m1")
        let detail = MediaItemDetail(
            item: item, tagline: nil, genres: [], studios: [], cast: [], directors: [], writers: [], chapters: [],
            mediaSources: [stream.source], trailerURL: nil, contentRating: nil, nextEpisode: nil, collections: [])
        var playback = ProviderPlayback(provider: provider, item: item, detail: detail, stream: stream, extras: PlaybackExtras())
        playback.extrasPending = extrasPending
        return playback
    }

    func test_initialRoutes_hlsKeepsTheStreamsHeaders() throws {
        let routes = try XCTUnwrap(UniversalPlayerViewModel.initialRoutes(for: stream(.hlsTranscode, url: hlsURL)))
        guard case .hls(_, let routeHeaders) = routes.primary else { return XCTFail("expected hls") }
        XCTAssertEqual(routeHeaders, headers)
    }

    func test_initialRoutes_directPlayKeepsTheStreamsHeaders() throws {
        let routes = try XCTUnwrap(UniversalPlayerViewModel.initialRoutes(for: stream(.directPlay, url: directURL)))
        guard case .aether(_, let routeHeaders) = routes.primary else { return XCTFail("expected aether") }
        XCTAssertEqual(routeHeaders, headers)
    }

    func test_initialRoutes_noHeadersStaysNil() throws {
        let routes = try XCTUnwrap(UniversalPlayerViewModel.initialRoutes(for: stream(.hlsTranscode, url: hlsURL, headers: [:])))
        guard case .hls(_, let routeHeaders) = routes.primary else { return XCTFail("expected hls") }
        XCTAssertNil(routeHeaders)
    }

    func test_viewModel_hlsStreamKeepsItsHeadersFromPrepareToPlayer() async {
        let vm = UniversalPlayerViewModel(
            providerPlayback: playback(StubMediaProvider(id: "plex:extra", kind: .plex), stream(.hlsTranscode, url: hlsURL)),
            startOffset: nil)
        await vm.prepareStreamURL()
        XCTAssertEqual(vm.streamURL, hlsURL)
        XCTAssertEqual(vm.streamHeaders, headers)
        guard case .hls(_, let routeHeaders)? = vm.playbackPlan?.primary else { return XCTFail("expected an hls plan") }
        XCTAssertEqual(routeHeaders, headers)
    }

    func test_viewModel_transcodeSwitchReturnsTheNewStreamsHeaders() async throws {
        let provider = StubMediaProvider(id: "plex:extra", kind: .plex)
        provider.transcodeResult = stream(.hlsTranscode, url: hlsURL)
        let vm = UniversalPlayerViewModel(providerPlayback: playback(provider, stream(.directPlay, url: directURL, headers: [:])),
                                          startOffset: nil)
        let hls = try await vm.switchToProviderTranscode(resumeTime: 42)
        XCTAssertEqual(hls?.url, hlsURL)
        XCTAssertEqual(hls?.headers, headers)
    }

    func test_viewModel_markersArriveAfterTheStart() async throws {
        let provider = StubMediaProvider(id: "jellyfin:srv", kind: .jellyfin)
        provider.extrasResult = PlaybackExtras(markers: [PlaybackMarker(kind: .intro, start: 1, end: 61)])
        let vm = UniversalPlayerViewModel(
            providerPlayback: playback(provider, stream(.directPlay, url: directURL, headers: [:]), extrasPending: true),
            startOffset: nil)
        for _ in 0..<50 where vm.metadata.Marker == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(vm.metadata.Marker?.compactMap(\.type), ["intro"])
        XCTAssertEqual(vm.metadata.Marker?.first?.startTimeOffset, 1000)
    }

    func test_viewModel_markersAlreadyPreparedAreNotFetchedAgain() async throws {
        let provider = StubMediaProvider(id: "jellyfin:srv", kind: .jellyfin)
        _ = UniversalPlayerViewModel(providerPlayback: playback(provider, stream(.directPlay, url: directURL, headers: [:])),
                                     startOffset: nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(provider.playbackCalls.contains { $0.hasPrefix("extras") })
    }
}
