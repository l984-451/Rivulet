// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class ProviderDownloadPlannerTests: XCTestCase {
    private let srtURL = URL(string: "http://media.local/Videos/ep/src/Subtitles/7/Stream.srt?api_key=SECRET")!
    private let assURL = URL(string: "http://media.local/Videos/ep/src/Subtitles/8/Stream.ass?api_key=SECRET")!

    private func item(artwork: URL? = URL(string: "http://media.local/Items/ep/Images/Primary?tag=a&api_key=SECRET")) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: "emby:srv", itemID: "ep-42"), kind: .episode, title: "Light Bulb", sortTitle: nil,
            overview: "The school gets new lights.", year: 2021, runtime: 1300,
            parentRef: MediaItemRef(providerID: "emby:srv", itemID: "season-1"),
            grandparentRef: MediaItemRef(providerID: "emby:srv", itemID: "show-1"),
            seriesTitle: "Abbott Elementary", episodeNumber: 2, seasonNumber: 1, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 61.5, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: artwork, backdrop: artwork, thumbnail: artwork, logo: nil),
            parentArtwork: MediaArtwork(poster: artwork, backdrop: nil, thumbnail: nil, logo: nil),
            grandparentArtwork: MediaArtwork(poster: artwork, backdrop: artwork, thumbnail: nil, logo: artwork))
    }

    private func source(_ id: String, height: Int = 1080, size: Int64? = 1_000_000, kbps: Int = 8000,
                        subtitles: [SubtitleTrack]? = nil) -> MediaSource {
        MediaSource(
            id: id, container: "mkv", duration: 1320, bitrate: kbps * 1000, fileSize: size, fileName: "x.mkv",
            videoResolution: "\(height)",
            videoTracks: [VideoTrack(id: "2", codec: "hevc", profile: nil, level: nil, width: height * 16 / 9, height: height,
                                     frameRate: 24, bitrate: nil, videoRange: .sdr, isDefault: true, scanType: "progressive")],
            audioTracks: [AudioTrack(id: "3", index: 1, codec: "eac3", profile: nil, channels: 6, channelLayout: "5.1",
                                     language: "eng", title: "English", extendedTitle: nil, bitrate: nil, samplingRate: 48000,
                                     isDefault: true, isForced: false, isSelected: true)],
            subtitleTracks: subtitles ?? [
                SubtitleTrack(id: "6", index: 4, codec: "pgssub", language: "eng", title: "English", extendedTitle: nil,
                              isDefault: false, isForced: false, isHearingImpaired: false, isEmbedded: true,
                              externalURL: nil, isSelected: false),
                SubtitleTrack(id: "7", index: 7, codec: "srt", language: "spa", title: "Spanish", extendedTitle: nil,
                              isDefault: false, isForced: true, isHearingImpaired: false, isEmbedded: false,
                              externalURL: srtURL, isSelected: false),
                SubtitleTrack(id: "8", index: 8, codec: "ass", language: "fra", title: "French", extendedTitle: nil,
                              isDefault: false, isForced: false, isHearingImpaired: false, isEmbedded: false,
                              externalURL: assURL, isSelected: false),
            ],
            streamKind: .directPlay, streamURL: nil)
    }

    private func detail(_ item: MediaItem, sources: [MediaSource]) -> MediaItemDetail {
        MediaItemDetail(
            item: item, tagline: nil, genres: ["Comedy"], studios: [], cast: [], directors: [], writers: [],
            chapters: [MediaChapter(id: "0", title: "Opening", start: 0, end: 355.855, thumbnailURL: nil)],
            mediaSources: sources, trailerURL: nil, contentRating: "TV-PG", nextEpisode: nil, collections: [],
            externalIDs: [:])
    }

    private let extras = PlaybackExtras(markers: [PlaybackMarker(kind: .intro, start: 30, end: 90)])

    func test_picksTheBestVersionByDefault() throws {
        let plan = try ProviderDownloadPlanner.plan(
            detail: detail(item(), sources: [source("hd", height: 1080), source("uhd", height: 2160)]),
            extras: extras, choice: .best)
        XCTAssertEqual(plan.sourceID, "uhd")
        XCTAssertEqual(plan.expectedBytes, 1_000_000)
    }

    func test_aChosenVersionWins() throws {
        let plan = try ProviderDownloadPlanner.plan(
            detail: detail(item(), sources: [source("hd", height: 1080), source("uhd", height: 2160)]),
            extras: extras, choice: .source("hd"))
        XCTAssertEqual(plan.sourceID, "hd")
    }

    func test_noVersionIsRefused() {
        XCTAssertThrowsError(try ProviderDownloadPlanner.plan(detail: detail(item(), sources: []), extras: extras, choice: .best))
    }

    func test_metadataCarriesWhatThePlayerNeedsOffline() throws {
        let plan = try ProviderDownloadPlanner.plan(detail: detail(item(), sources: [source("hd")]), extras: extras, choice: .best)
        let meta = plan.metadata
        XCTAssertEqual(meta.ratingKey, "ep-42")
        XCTAssertEqual(meta.title, "Light Bulb")
        XCTAssertEqual(meta.duration, 1_320_000)
        XCTAssertEqual(meta.Chapter?.first?.tag, "Opening")
        XCTAssertEqual(meta.Marker?.first?.type, "intro")
        XCTAssertEqual(meta.Marker?.first?.startTimeOffset, 30_000)
        let streams = try XCTUnwrap(meta.Media?.first?.Part?.first?.Stream)
        XCTAssertEqual(streams.filter { $0.streamType == 2 }.count, 1)
        XCTAssertEqual(streams.filter { $0.streamType == 3 }.count, 3)
    }

    func test_sidecarsAreTheExternalSubtitlesInOrder() throws {
        let plan = try ProviderDownloadPlanner.plan(detail: detail(item(), sources: [source("hd")]), extras: extras, choice: .best)
        XCTAssertEqual(plan.sidecars.map(\.url), [srtURL, assURL])
        XCTAssertEqual(plan.sidecars.map(\.ext), ["srt", "ass"])
        XCTAssertEqual(plan.sidecars.map(\.language), ["spa", "fra"])
        XCTAssertEqual(plan.sidecars.map(\.isForced), [true, false])
    }

    func test_storedMetadataNeverHoldsASidecarURLOrToken() throws {
        let plan = try ProviderDownloadPlanner.plan(detail: detail(item(), sources: [source("hd")]), extras: extras, choice: .best)
        let streams = try XCTUnwrap(plan.metadata.Media?.first?.Part?.first?.Stream)
        let external = streams.filter { $0.streamType == 3 && $0.key != nil }
        XCTAssertEqual(external.count, 2, "sidecars keep a key, so the player still pairs them by order")
        XCTAssertFalse(external.contains { $0.key?.contains("http") == true || $0.key?.contains("SECRET") == true })
        let json = String(decoding: try JSONEncoder().encode(plan.metadata), as: UTF8.self)
        XCTAssertFalse(json.contains("SECRET"))
    }

    func test_storedItemKeepsItsTitlesButLosesTheTokenInArtwork() throws {
        let plan = try ProviderDownloadPlanner.plan(detail: detail(item(), sources: [source("hd")]), extras: extras, choice: .best)
        XCTAssertEqual(plan.item.title, "Light Bulb")
        XCTAssertEqual(plan.item.seriesTitle, "Abbott Elementary")
        XCTAssertEqual(plan.item.ref.itemID, "ep-42")
        let json = String(decoding: try JSONEncoder().encode(plan.item), as: UTF8.self)
        XCTAssertFalse(json.contains("SECRET"))
        XCTAssertFalse(json.contains("api_key"))
        // The image itself is still addressable, minus the credential.
        XCTAssertEqual(plan.item.artwork.poster?.path, "/Items/ep/Images/Primary")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(plan.item.artwork.poster), resolvingAgainstBaseURL: false)?
            .queryItems?.map(\.name), ["tag"])
    }

    func test_anItemWithoutAnyExternalSubtitleHasNoSidecars() throws {
        let plain = source("hd", subtitles: [])
        let plan = try ProviderDownloadPlanner.plan(detail: detail(item(), sources: [plain]), extras: extras, choice: .best)
        XCTAssertTrue(plan.sidecars.isEmpty)
    }
}
