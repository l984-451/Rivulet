// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ProviderPlaybackSourceTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

@MainActor
final class ProviderPlaybackSourceTests: XCTestCase {

    private let directURL = URL(string: "http://media.local/Videos/m1/stream?static=true&ApiKey=k")!
    private let hlsURL = URL(string: "http://media.local/videos/m1/master.m3u8?ApiKey=k")!
    private let srtURL = URL(string: "http://media.local/Videos/m1/src/Subtitles/0/0/Stream.srt?ApiKey=k")!
    private let assURL = URL(string: "http://media.local/Videos/m1/src/Subtitles/1/0/Stream.ass?ApiKey=k")!

    private func subtitle(_ id: String, index: Int, codec: String, language: String, title: String,
                          extendedTitle: String? = nil, forced: Bool = false, hearingImpaired: Bool = false,
                          isDefault: Bool = false, external: URL?) -> SubtitleTrack {
        SubtitleTrack(id: id, index: index, codec: codec, language: language, title: title,
                      extendedTitle: extendedTitle, isDefault: isDefault, isForced: forced,
                      isHearingImpaired: hearingImpaired, isEmbedded: external == nil,
                      externalURL: external, isSelected: false)
    }

    private func source(kind: MediaSource.StreamKind, url: URL?) -> MediaSource {
        MediaSource(
            id: "src",
            container: "mkv",
            duration: 100,
            bitrate: nil,
            fileSize: nil,
            fileName: "Heat.mkv",
            videoResolution: "1080",
            videoTracks: [],
            audioTracks: [],
            subtitleTracks: [
                subtitle("10", index: 0, codec: "srt", language: "eng", title: "English",
                         extendedTitle: "English (SRT)", hearingImpaired: true, isDefault: true, external: srtURL),
                subtitle("11", index: 5, codec: "pgssub", language: "eng", title: "English PGS", external: nil),
                subtitle("12", index: 1, codec: "ass", language: "spa", title: "Spanish", forced: true, external: assURL)
            ],
            streamKind: kind,
            streamURL: url
        )
    }

    private func stream(kind: MediaSource.StreamKind = .directPlay, url: URL? = nil) -> StreamInfo {
        StreamInfo(source: source(kind: kind, url: url ?? directURL), playSessionID: "ps1", trackInfoAvailable: true)
    }

    private func playback(provider: StubMediaProvider, stream: StreamInfo) -> ProviderPlayback {
        let item = JellyfinFixtures.mediaItem("m1")
        let detail = MediaItemDetail(
            item: item, tagline: nil, genres: [], studios: [], cast: [], directors: [], writers: [],
            chapters: [], mediaSources: [stream.source], trailerURL: nil, contentRating: nil,
            rating: nil, nextEpisode: nil, collections: []
        )
        return ProviderPlayback(provider: provider, item: item, detail: detail, stream: stream, extras: PlaybackExtras())
    }

    func test_plexSource_isDefault() {
        let metadata = ProviderPlaybackMetadata.make(
            detail: playback(provider: StubMediaProvider(), stream: stream()).detail,
            source: stream().source,
            extras: PlaybackExtras()
        )
        let vm = UniversalPlayerViewModel(metadata: metadata, serverURL: "http://plex.local:32400", authToken: "t")
        guard case .plex = vm.source else { return XCTFail("expected .plex, got \(vm.source)") }
    }

    func test_initialRoutes_directPlayHasATranscodeFallback() throws {
        let routes = try XCTUnwrap(UniversalPlayerViewModel.initialRoutes(for: stream(kind: .directPlay)))
        guard case .aether(let url, let headers) = routes.primary else {
            return XCTFail("expected aether, got \(routes.primary)")
        }
        XCTAssertEqual(url, directURL)
        XCTAssertNil(headers)
        XCTAssertTrue(routes.hasTranscodeFallback)
    }

    func test_initialRoutes_hlsPlaysOnAVPlayerWithoutFallback() throws {
        let routes = try XCTUnwrap(UniversalPlayerViewModel.initialRoutes(for: stream(kind: .hlsTranscode, url: hlsURL)))
        guard case .hls(let url, let headers) = routes.primary else {
            return XCTFail("expected hls, got \(routes.primary)")
        }
        XCTAssertEqual(url, hlsURL)
        XCTAssertNil(headers)
        XCTAssertFalse(routes.hasTranscodeFallback)
    }

    func test_providerReporting_routesToProviderReporter() async {
        let provider = StubMediaProvider(id: "jellyfin:srv", kind: .jellyfin)
        let recorder = RecordingReporter()
        provider.reporter = recorder
        let playback = playback(provider: provider, stream: stream())
        let vm = UniversalPlayerViewModel(providerPlayback: playback, startOffset: nil)
        guard case .provider = vm.source else { return XCTFail("expected .provider") }

        vm.reportPlaybackState(.playing)
        vm.reportPlaybackProgress(time: 30, force: true)
        await vm.reportFinalProgress(time: 95, duration: 100)

        XCTAssertEqual(recorder.events, ["start", "progress(30.0)", "stopped(95.0)"])
        XCTAssertEqual(provider.markedPlayed, [playback.item.ref])
    }

    func test_providerSidecars_followTheSourcesExternalTracks() {
        let vm = UniversalPlayerViewModel(
            providerPlayback: playback(provider: StubMediaProvider(id: "jellyfin:srv", kind: .jellyfin), stream: stream()),
            startOffset: nil
        )
        let sidecars = vm.aetherExternalSubtitles()
        XCTAssertEqual(sidecars.map(\.url), [srtURL, assURL])
        XCTAssertEqual(sidecars.map(\.name), ["English (SRT)", "Spanish"])
        XCTAssertEqual(sidecars.map(\.language), ["eng", "spa"])
        XCTAssertEqual(sidecars.map(\.formatHint), ["srt", "ass"])
        XCTAssertEqual(sidecars.map(\.isForced), [false, true])
        XCTAssertEqual(sidecars.map(\.isHearingImpaired), [true, false])
        XCTAssertEqual(sidecars.map(\.isDefault), [true, false])
    }

    func test_providerPlan_directPlayArmsTheTranscodeFallback() async {
        let vm = UniversalPlayerViewModel(
            providerPlayback: playback(provider: StubMediaProvider(id: "jellyfin:srv", kind: .jellyfin), stream: stream()),
            startOffset: nil
        )
        await vm.prepareStreamURL()
        XCTAssertEqual(vm.streamURL, directURL)
        XCTAssertTrue(vm.planHasHLSFallback(vm.playbackPlan))
    }

    func test_providerPlan_hlsStreamHasNoFallback() async {
        let vm = UniversalPlayerViewModel(
            providerPlayback: playback(provider: StubMediaProvider(id: "jellyfin:srv", kind: .jellyfin),
                                       stream: stream(kind: .hlsTranscode, url: hlsURL)),
            startOffset: nil
        )
        await vm.prepareStreamURL()
        XCTAssertEqual(vm.streamURL, hlsURL)
        XCTAssertNotNil(vm.playbackPlan)
        XCTAssertFalse(vm.planHasHLSFallback(vm.playbackPlan))
    }

    func test_transcodeFallback_asksTheProviderAndReportsToTheNewSession() async throws {
        let provider = StubMediaProvider(id: "jellyfin:srv", kind: .jellyfin)
        let first = RecordingReporter()
        let second = RecordingReporter()
        provider.reporter = first
        provider.transcodeResult = StreamInfo(
            source: source(kind: .hlsTranscode, url: hlsURL), playSessionID: "ps2", trackInfoAvailable: false
        )
        let playback = playback(provider: provider, stream: stream())
        let vm = UniversalPlayerViewModel(providerPlayback: playback, startOffset: nil)

        provider.reporter = second
        let url = try await vm.switchToProviderTranscode(resumeTime: 42)

        XCTAssertEqual(url, hlsURL)
        XCTAssertEqual(provider.transcodeRequests.map(\.ref), [playback.item.ref])
        XCTAssertEqual(provider.transcodeRequests.map(\.sourceID), ["src"])
        XCTAssertEqual(provider.transcodeRequests.map(\.startTime), [42])
        XCTAssertEqual(first.events, ["stopped(42.0)"])

        vm.reportPlaybackState(.playing)
        await vm.reportFinalProgress(time: 50, duration: 100)
        XCTAssertEqual(second.events, ["start", "stopped(50.0)"])
        XCTAssertEqual(first.events, ["stopped(42.0)"])
    }

    func test_variantPick_resolvesPMSAndProviderLines() {
        let pmsBase = URL(string: "http://plex.local:32400/video/:/transcode/universal/start.m3u8?session=s")!
        let pms = "#EXTM3U\n\n#EXT-X-STREAM-INF:BANDWIDTH=1\nsession/abc/base/index.m3u8\n"
        XCTAssertEqual(
            UniversalPlayerViewModel.firstVariantURL(inMaster: pms, baseURL: pmsBase)?.absoluteString,
            "http://plex.local:32400/video/:/transcode/universal/session/abc/base/index.m3u8"
        )

        let jfBase = URL(string: "http://media.local/videos/m1/master.m3u8?ApiKey=z")!
        let jf = "#EXTM3U\n\n#EXT-X-STREAM-INF:BANDWIDTH=1\nmain.m3u8?DeviceId=x&PlaySessionId=y&ApiKey=z\n"
        XCTAssertEqual(
            UniversalPlayerViewModel.firstVariantURL(inMaster: jf, baseURL: jfBase)?.absoluteString,
            "http://media.local/videos/m1/main.m3u8?DeviceId=x&PlaySessionId=y&ApiKey=z"
        )

        XCTAssertNil(UniversalPlayerViewModel.firstVariantURL(inMaster: "#EXTM3U\n\n#EXT-X-STREAM-INF:BANDWIDTH=1\n", baseURL: jfBase))
    }

    func test_markWatchedAtCredits_keepsTheProviderSessionOpen() async {
        let provider = StubMediaProvider(id: "jellyfin:srv", kind: .jellyfin)
        let recorder = RecordingReporter()
        provider.reporter = recorder
        let playback = playback(provider: provider, stream: stream())
        let vm = UniversalPlayerViewModel(providerPlayback: playback, startOffset: nil)

        vm.reportPlaybackState(.playing)
        await vm.markCurrentAsWatched()
        await vm.reportFinalProgress(time: 99, duration: 100)

        XCTAssertEqual(recorder.events, ["start", "stopped(99.0)"])
        XCTAssertEqual(provider.markedPlayed.first, playback.item.ref)
    }

    // MARK: - Up Next and autoplay

    private func episode(_ id: String, season: Int, number: Int) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: "jellyfin:srv", itemID: id),
            kind: .episode, title: "Episode \(id)", sortTitle: nil, overview: nil, year: nil, runtime: 1800,
            parentRef: MediaItemRef(providerID: "jellyfin:srv", itemID: "season\(season)"),
            grandparentRef: MediaItemRef(providerID: "jellyfin:srv", itemID: "show"),
            episodeNumber: number, seasonNumber: season, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil
        )
    }

    private func detail(_ item: MediaItem, source: MediaSource) -> MediaItemDetail {
        MediaItemDetail(
            item: item, tagline: nil, genres: [], studios: [], cast: [], directors: [], writers: [],
            chapters: [], mediaSources: [source], trailerURL: nil, contentRating: nil,
            rating: nil, nextEpisode: nil, collections: []
        )
    }

    func test_nextEpisode_withinSeason() {
        let e1 = episode("e1", season: 1, number: 1)
        let e2 = episode("e2", season: 1, number: 2)
        let e3 = episode("e3", season: 1, number: 3)
        let next = UniversalPlayerViewModel.nextEpisode(after: e1, in: [e3, e1, e2], nextSeasonEpisodes: nil)
        XCTAssertEqual(next?.ref.itemID, "e2")
    }

    func test_nextEpisode_firstOfNextSeason() {
        let e1 = episode("e1", season: 1, number: 1)
        let e2 = episode("e2", season: 1, number: 2)
        let s2e1 = episode("s2e1", season: 2, number: 1)
        let s2e2 = episode("s2e2", season: 2, number: 2)
        let next = UniversalPlayerViewModel.nextEpisode(after: e2, in: [e1, e2], nextSeasonEpisodes: [s2e2, s2e1])
        XCTAssertEqual(next?.ref.itemID, "s2e1")
    }

    func test_nextEpisode_lastEpisodeOfShow_isNil() {
        let e1 = episode("e1", season: 1, number: 1)
        let e2 = episode("e2", season: 1, number: 2)
        XCTAssertNil(UniversalPlayerViewModel.nextEpisode(after: e2, in: [e1, e2], nextSeasonEpisodes: nil))
        XCTAssertNil(UniversalPlayerViewModel.nextEpisode(after: e2, in: [e1, e2], nextSeasonEpisodes: []))
    }

    func test_providerAutoplay_swapsSourceAndReporter() async throws {
        let provider = StubMediaProvider(id: "jellyfin:srv", kind: .jellyfin)
        let first = RecordingReporter()
        let second = RecordingReporter()
        provider.reporter = first
        let e1 = episode("e1", season: 1, number: 1)
        let e2 = episode("e2", season: 1, number: 2)
        provider.childrenByParent["season1"] = [e2, e1]
        let current = ProviderPlayback(provider: provider, item: e1, detail: detail(e1, source: stream().source),
                                       stream: stream(), extras: PlaybackExtras())
        let vm = UniversalPlayerViewModel(providerPlayback: current, startOffset: nil)
        vm.reportPlaybackState(.playing)

        // The next episode's stream has no URL, so its start fails fast
        // instead of opening a connection.
        let nextSource = source(kind: .directPlay, url: nil)
        provider.detailResult = detail(e2, source: nextSource)
        provider.streamResult = StreamInfo(source: nextSource, playSessionID: "ps2", trackInfoAvailable: true)
        provider.reporter = second

        let fetched = await vm.fetchNextEpisode()
        let next = try XCTUnwrap(fetched)
        XCTAssertEqual(next.ratingKey, "e2")
        XCTAssertNil(next.Media, "a listing shim carries nothing a Plex request could be built from")
        await vm.playEpisode(next)

        guard case .provider(let playing) = vm.source else { return XCTFail("expected .provider") }
        XCTAssertEqual(playing.item.ref, e2.ref)
        XCTAssertEqual(playing.stream.playSessionID, "ps2")
        XCTAssertEqual(vm.metadata.ratingKey, "e2")
        XCTAssertEqual(first.events, ["start", "stopped(0.0)"])
        XCTAssertEqual(provider.markedPlayed.first, e1.ref)
        XCTAssertFalse(provider.markedPlayed.contains(e2.ref))
        XCTAssertNil(vm.streamURL)

        // The new episode reports to its own session only.
        let secondBefore = second.events
        vm.reportPlaybackState(.playing)
        await vm.reportFinalProgress(time: 10, duration: 100)
        XCTAssertEqual(second.events, secondBefore + ["start", "stopped(10.0)"])
        XCTAssertEqual(first.events, ["start", "stopped(0.0)"])
    }

    /// The current episode e1 is playing; the stub answers `children` with
    /// `seasonEpisodes` and the next stream (no URL, so its start fails fast).
    private func autoplayVM(_ provider: StubMediaProvider, seasonEpisodes: [MediaItem]) -> UniversalPlayerViewModel {
        provider.childrenByParent["season1"] = seasonEpisodes
        let e1 = episode("e1", season: 1, number: 1)
        let current = ProviderPlayback(provider: provider, item: e1, detail: detail(e1, source: stream().source),
                                       stream: stream(), extras: PlaybackExtras())
        let vm = UniversalPlayerViewModel(providerPlayback: current, startOffset: nil)
        vm.reportPlaybackState(.playing)
        let nextSource = source(kind: .directPlay, url: nil)
        provider.streamResult = StreamInfo(source: nextSource, playSessionID: "ps2", trackInfoAvailable: true)
        return vm
    }

    func test_providerAutoplay_upNextRowPlaysThatEpisode() async throws {
        let provider = StubMediaProvider(id: "jellyfin:srv", kind: .jellyfin)
        let e3 = episode("e3", season: 1, number: 3)
        let vm = autoplayVM(provider, seasonEpisodes: [episode("e1", season: 1, number: 1),
                                                      episode("e2", season: 1, number: 2), e3])
        provider.detailResult = detail(e3, source: source(kind: .directPlay, url: nil))

        await vm.loadUpNextEpisodes()
        XCTAssertEqual(vm.upNextEpisodes.map(\.ratingKey), ["e1", "e2", "e3"])
        let row = try XCTUnwrap(vm.upNextEpisodes.last)
        await vm.playEpisode(row)

        guard case .provider(let playing) = vm.source else { return XCTFail("expected .provider") }
        XCTAssertEqual(playing.item.ref, e3.ref)
        XCTAssertEqual(vm.metadata.ratingKey, "e3")
        XCTAssertTrue(provider.playbackCalls.contains("detail(e3)"))
    }

    func test_providerAutoplay_failedPrepareKeepsTheCurrentEpisode() async {
        let provider = StubMediaProvider(id: "jellyfin:srv", kind: .jellyfin)
        let first = RecordingReporter()
        provider.reporter = first
        let vm = autoplayVM(provider, seasonEpisodes: [episode("e1", season: 1, number: 1),
                                                      episode("e2", season: 1, number: 2)])
        // No detailResult: the detail fetch throws.

        guard let next = await vm.fetchNextEpisode() else { return XCTFail("expected a next episode") }
        await vm.playEpisode(next)

        guard case .provider(let playing) = vm.source else { return XCTFail("expected .provider") }
        XCTAssertEqual(playing.item.ref.itemID, "e1")
        XCTAssertEqual(vm.metadata.ratingKey, "e1")
        XCTAssertEqual(first.events, ["start"])
        XCTAssertTrue(provider.markedPlayed.isEmpty)
        XCTAssertEqual(vm.nextEpisodeError, "Couldn't load the next episode.")
        XCTAssertTrue(vm.isCountdownPaused)
    }

    func test_providerUpNext_leavesSpecialsOutOfTheSeason() async {
        let provider = StubMediaProvider(id: "jellyfin:srv", kind: .jellyfin)
        let vm = autoplayVM(provider, seasonEpisodes: [
            episode("e1", season: 1, number: 1),
            episode("sp", season: 0, number: 2),
            episode("e2", season: 1, number: 3)
        ])

        let next = await vm.fetchNextEpisode()
        XCTAssertEqual(next?.ratingKey, "e2")
        await vm.loadUpNextEpisodes()
        XCTAssertEqual(vm.upNextEpisodes.map(\.ratingKey), ["e1", "e2"])
    }

    // MARK: - Entry points

    func test_isPlex() {
        XCTAssertTrue(MediaItemRef(providerID: "plex:abc", itemID: "1").isPlex)
        XCTAssertFalse(MediaItemRef(providerID: "jellyfin:srv", itemID: "x").isPlex)
        XCTAssertFalse(MediaItemRef(providerID: "tmdb", itemID: "1").isPlex)
    }

    func test_prepare_fetchesDetailStreamAndExtras() async throws {
        let provider = StubMediaProvider(id: "jellyfin:srv", kind: .jellyfin)
        let expected = playback(provider: provider, stream: stream())
        let marker = PlaybackMarker(kind: .intro, start: 5, end: 30)
        provider.detailResult = expected.detail
        provider.streamResult = expected.stream
        provider.extrasResult = PlaybackExtras(markers: [marker])

        let prepared = try await ProviderPlayback.prepare(item: expected.item, provider: provider, quality: .original)

        XCTAssertEqual(Set(provider.playbackCalls), ["detail(m1)", "stream(m1,nil)", "extras(m1,src)"])
        XCTAssertEqual(provider.playbackCalls.count, 3)
        XCTAssertEqual(prepared.item.ref, expected.item.ref)
        XCTAssertEqual(prepared.detail.item.ref, expected.item.ref)
        XCTAssertEqual(prepared.stream.source.id, "src")
        XCTAssertEqual(prepared.stream.playSessionID, "ps1")
        XCTAssertEqual(prepared.extras.markers, [marker])
        XCTAssertEqual(prepared.provider.id, "jellyfin:srv")
    }

    func test_prepare_throwsTheStreamError() async {
        let provider = StubMediaProvider(id: "jellyfin:srv", kind: .jellyfin)
        let item = playback(provider: provider, stream: stream())
        provider.detailResult = item.detail
        do {
            _ = try await ProviderPlayback.prepare(item: item.item, provider: provider, quality: .original)
            XCTFail("expected a throw")
        } catch {
            guard case MediaProviderError.notFound = error else { return XCTFail("got \(error)") }
        }
    }

    func test_providerPlayback_skipsThePlexConnectionGate() {
        let provider = StubMediaProvider(id: "jellyfin:srv", kind: .jellyfin)
        XCTAssertTrue(PlayerPresenter.requiresPlexConnection(for: .plex))
        XCTAssertFalse(PlayerPresenter.requiresPlexConnection(
            for: .provider(playback(provider: provider, stream: stream()))))
    }

    func test_play_ignoresASecondPressWhileOneIsPreparing() {
        XCTAssertTrue(ProviderPlayer.claimStart())
        XCTAssertFalse(ProviderPlayer.claimStart(), "a second press while preparing")
        ProviderPlayer.finishStart()
        XCTAssertTrue(ProviderPlayer.claimStart(), "free again once the first presents or fails")
        ProviderPlayer.finishStart()
        XCTAssertFalse(ProviderPlayer.isStarting)
    }

    func test_startOffset_usesTheServersResumePoint() {
        XCTAssertEqual(ProviderPlayer.startOffset(detailOffset: 754, fromBeginning: false), 754)
        XCTAssertNil(ProviderPlayer.startOffset(detailOffset: 754, fromBeginning: true))
        XCTAssertNil(ProviderPlayer.startOffset(detailOffset: 0, fromBeginning: false))
    }

    func test_playErrorCopy() {
        XCTAssertEqual(ProviderPlayer.errorMessage(for: MediaProviderError.transcodeRequired),
                       "This server can't stream this title to Apple TV.")
        XCTAssertEqual(ProviderPlayer.errorMessage(for: MediaProviderError.unreachable),
                       "Couldn't reach the server.")
        XCTAssertEqual(ProviderPlayer.errorMessage(for: MediaProviderError.unauthorized),
                       "The server didn't accept your sign-in.")
        XCTAssertEqual(ProviderPlayer.errorMessage(for: MediaProviderError.notPlayable),
                       "Something went wrong starting playback.")
        XCTAssertEqual(ProviderPlayer.errorMessage(for: URLError(.badServerResponse)),
                       "Something went wrong starting playback.")
    }

    // MARK: - Artwork, Now Playing, content filter, Insights

    private func art(_ name: String) -> MediaArtwork {
        let url = { (kind: String) in URL(string: "http://media.local/Items/\(name)/Images/\(kind)")! }
        return MediaArtwork(poster: url("Primary"), backdrop: url("Backdrop"), thumbnail: url("Thumb"), logo: url("Logo"))
    }

    private func artPlayback(_ item: MediaItem, provider: StubMediaProvider = StubMediaProvider(id: "jellyfin:srv", kind: .jellyfin)) -> ProviderPlayback {
        let base = playback(provider: provider, stream: stream())
        return ProviderPlayback(provider: provider, item: item, detail: detail(item, source: base.stream.source),
                                stream: base.stream, extras: PlaybackExtras())
    }

    private func artEpisode(own: MediaArtwork, show: MediaArtwork) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: "jellyfin:srv", itemID: "e1"),
            kind: .episode, title: "Pilot", sortTitle: nil, overview: nil, year: nil, runtime: 1800,
            parentRef: MediaItemRef(providerID: "jellyfin:srv", itemID: "season1"),
            grandparentRef: MediaItemRef(providerID: "jellyfin:srv", itemID: "show"),
            episodeNumber: 1, seasonNumber: 1, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: own, parentArtwork: nil, grandparentArtwork: show
        )
    }

    func test_providerMovieArtwork_comesFromTheItem() {
        let movie = JellyfinFixtures.mediaItem("m1")
        let item = MediaItem(
            ref: movie.ref, kind: .movie, title: "Heat", sortTitle: nil, overview: nil, year: 1995, runtime: 100,
            parentRef: nil, grandparentRef: nil, episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: movie.userState, artwork: art("m1"), parentArtwork: nil, grandparentArtwork: nil
        )
        let vm = UniversalPlayerViewModel(providerPlayback: artPlayback(item), startOffset: nil)
        XCTAssertEqual(vm.ambientBackdropURL, art("m1").backdrop)
        XCTAssertEqual(vm.nowPlayingArtworkURL, art("m1").poster)
    }

    func test_providerEpisodeArtwork_fallsBackToTheShow() {
        let own = MediaArtwork(poster: nil, backdrop: nil, thumbnail: art("e1").thumbnail, logo: nil)
        let vm = UniversalPlayerViewModel(providerPlayback: artPlayback(artEpisode(own: own, show: art("show"))),
                                          startOffset: nil)
        XCTAssertEqual(vm.ambientBackdropURL, art("show").backdrop)
        XCTAssertEqual(vm.nowPlayingArtworkURL, art("show").poster)
    }

    func test_providerContentFilterTranscript_isTheEnglishSidecarAsIs() {
        let vm = UniversalPlayerViewModel(
            providerPlayback: playback(provider: StubMediaProvider(id: "jellyfin:srv", kind: .jellyfin), stream: stream()),
            startOffset: nil
        )
        XCTAssertEqual(vm.contentFilterTranscriptURL, srtURL)
    }

    func test_plexArtworkAndTranscript_keepTheServerTokenForm() throws {
        let metadata = try JSONDecoder().decode(PlexMetadata.self, from: Data("""
        {"ratingKey": "1", "type": "movie", "title": "Heat",
         "art": "/library/metadata/1/art/2", "thumb": "/library/metadata/1/thumb/3",
         "Media": [{"id": 1, "Part": [{"id": 1, "key": "/library/parts/1/file.mkv",
           "Stream": [{"id": 7, "streamType": 3, "codec": "srt", "languageCode": "eng",
                       "key": "/library/streams/7"}]}]}]}
        """.utf8))
        let vm = UniversalPlayerViewModel(metadata: metadata, serverURL: "http://plex:32400", authToken: "tok")
        XCTAssertEqual(vm.ambientBackdropURL?.absoluteString,
                       "http://plex:32400/library/metadata/1/art/2?X-Plex-Token=tok")
        XCTAssertEqual(vm.nowPlayingArtworkURL?.absoluteString,
                       "http://plex:32400/library/metadata/1/thumb/3?X-Plex-Token=tok")
        XCTAssertEqual(vm.contentFilterTranscriptURL?.absoluteString,
                       "http://plex:32400/library/streams/7?X-Plex-Token=tok")
    }

    func test_providerEpisodeInsights_readTheShowsIDsOnce() async {
        let provider = StubMediaProvider(id: "jellyfin:srv", kind: .jellyfin)
        let episode = artEpisode(own: art("e1"), show: art("show"))
        var showDetail = detail(JellyfinFixtures.mediaItem("show", kind: .show), source: stream().source)
        showDetail.externalIDs = ["tmdb": "1399", "tvdb": "121361"]
        provider.detailResult = showDetail
        let playback = artPlayback(episode, provider: provider)
        let vm = UniversalPlayerViewModel(providerPlayback: playback, startOffset: nil)

        let first = await vm.providerShowTmdbID(playback)
        let second = await vm.providerShowTmdbID(playback)
        XCTAssertEqual(first, 1399)
        XCTAssertEqual(second, 1399)
        XCTAssertEqual(provider.playbackCalls, ["detail(show)"])
    }

    // MARK: - Scrub thumbnails

    func test_scrubThumbnailSource_prefersServerThumbnails() {
        XCTAssertEqual(UniversalPlayerViewModel.scrubThumbnailSource(hasServerThumbnails: true), .server)
        XCTAssertEqual(UniversalPlayerViewModel.scrubThumbnailSource(hasServerThumbnails: false), .engine)
    }

    /// A Plex part keeps its BIF until the server fails to serve one.
    func test_plexPart_usesServerThumbnails() {
        var metadata = PlexMetadata()
        metadata.type = "movie"
        let part = PlexPart(id: 987_654, key: "/library/parts/987654/file.mkv", duration: 1_000,
                            file: nil, size: nil, container: "mkv", Stream: nil)
        metadata.Media = [PlexMedia(
            id: 1, duration: 1_000, bitrate: nil, width: nil, height: nil, aspectRatio: nil,
            audioChannels: nil, audioCodec: nil, videoCodec: nil, videoResolution: nil,
            container: "mkv", videoFrameRate: nil, Part: [part])]
        let vm = UniversalPlayerViewModel(metadata: metadata, serverURL: "http://plex.local:32400", authToken: "t")
        XCTAssertEqual(vm.currentScrubThumbnailSource, .server)
    }

    func test_providerItem_usesEngineThumbnails() {
        // The provider metadata carries a placeholder Part (id 0); it must never
        // reach PlexThumbnailService as a BIF request.
        let vm = UniversalPlayerViewModel(
            providerPlayback: playback(provider: StubMediaProvider(), stream: stream()), startOffset: nil)
        XCTAssertEqual(vm.currentScrubThumbnailSource, .engine)
        vm.preloadThumbnails()
        XCTAssertNil(vm.preloadedThumbnailPartId)
    }
}
