// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ProviderPlaybackMetadataTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

@MainActor
final class ProviderPlaybackMetadataTests: XCTestCase {

    private let srtURL = URL(string: "http://media.local/Videos/ep/src/Subtitles/7/Stream.srt")!

    private func episodeItem(seriesTitle: String? = "Abbott Elementary") -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: "other:srv", itemID: "ep-42"),
            kind: .episode,
            title: "Light Bulb",
            sortTitle: nil,
            overview: "The school gets new lights.",
            year: 2021,
            contentRating: "TV-PG",
            runtime: 1300,
            parentRef: nil,
            grandparentRef: nil,
            seriesTitle: seriesTitle,
            episodeNumber: 2,
            seasonNumber: 1,
            childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 61.5, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil,
            grandparentArtwork: nil
        )
    }

    private func source() -> MediaSource {
        MediaSource(
            id: "src",
            container: "mkv",
            duration: 1320,
            bitrate: 8_000_000,
            fileSize: 1_000_000,
            fileName: "Abbott.S01E02.mkv",
            videoResolution: "1080",
            videoTracks: [
                VideoTrack(id: "2", codec: "hevc", profile: "Main 10", level: 120, width: 1920, height: 1080,
                           frameRate: 23.976, bitrate: nil, videoRange: .dolbyVision(profile: 8),
                           isDefault: true, scanType: "progressive")
            ],
            audioTracks: [
                AudioTrack(id: "3", index: 1, codec: "eac3", profile: nil, channels: 6, channelLayout: "5.1",
                           language: "eng", title: "English", extendedTitle: "English (EAC3 5.1)",
                           bitrate: nil, samplingRate: 48000, isDefault: true, isForced: false, isSelected: true)
            ],
            subtitleTracks: [
                SubtitleTrack(id: "6", index: 4, codec: "pgssub", language: "eng", title: "English",
                              extendedTitle: nil, isDefault: false, isForced: false, isHearingImpaired: false,
                              isEmbedded: true, externalURL: nil, isSelected: false),
                SubtitleTrack(id: "7", index: 7, codec: "srt", language: "spa", title: "Spanish",
                              extendedTitle: nil, isDefault: false, isForced: true, isHearingImpaired: true,
                              isEmbedded: false, externalURL: srtURL, isSelected: false)
            ],
            streamKind: .directPlay,
            streamURL: nil
        )
    }

    private func detail(_ item: MediaItem) -> MediaItemDetail {
        MediaItemDetail(
            item: item,
            tagline: nil,
            genres: ["Comedy", "Sitcom"],
            studios: [],
            cast: [],
            directors: [],
            writers: [],
            chapters: [
                MediaChapter(id: "0", title: "Opening", start: 0, end: 355.855, thumbnailURL: nil),
                MediaChapter(id: "1", title: "Part Two", start: 355.855, end: nil, thumbnailURL: nil)
            ],
            mediaSources: [],
            trailerURL: nil,
            contentRating: "TV-PG",
            rating: nil,
            nextEpisode: nil,
            collections: [],
            externalIDs: ["tmdb": "12345"]
        )
    }

    private func make() -> PlexMetadata {
        let extras = PlaybackExtras(markers: [PlaybackMarker(kind: .intro, start: 30, end: 90)])
        return ProviderPlaybackMetadata.make(detail: detail(episodeItem()), source: source(), extras: extras)
    }

    func test_identityAndHierarchy() {
        let m = make()
        XCTAssertEqual(m.ratingKey, "ep-42")
        XCTAssertNil(m.key)
        XCTAssertEqual(m.type, "episode")
        XCTAssertEqual(m.title, "Light Bulb")
        XCTAssertEqual(m.grandparentTitle, "Abbott Elementary")
        XCTAssertEqual(m.index, 2)
        XCTAssertEqual(m.parentIndex, 1)
        XCTAssertEqual(m.year, 2021)
        XCTAssertEqual(m.summary, "The school gets new lights.")
        XCTAssertEqual(m.contentRating, "TV-PG")
        XCTAssertEqual(m.duration, 1_320_000)
        XCTAssertEqual(m.viewOffset, 61_500)
        XCTAssertEqual(m.Genre?.compactMap(\.tag), ["Comedy", "Sitcom"])
        XCTAssertEqual(m.Guid?.compactMap(\.id).contains("tmdb://12345"), true)
        XCTAssertNil(m.thumb)
        XCTAssertNil(m.art)
    }

    func test_mediaAndPart() throws {
        let media = try XCTUnwrap(make().Media?.first)
        XCTAssertEqual(media.container, "mkv")
        XCTAssertEqual(media.videoCodec, "hevc")
        XCTAssertEqual(media.videoResolution, "1080")
        XCTAssertEqual(media.width, 1920)
        XCTAssertEqual(media.height, 1080)
        XCTAssertEqual(media.bitrate, 8000)
        XCTAssertEqual(media.audioCodec, "eac3")
        XCTAssertEqual(media.audioChannels, 6)

        let part = try XCTUnwrap(media.Part?.first)
        XCTAssertNil(part.key)
        XCTAssertEqual(part.id, 0)
        XCTAssertEqual(part.duration, 1_320_000)
        XCTAssertEqual(part.file, "Abbott.S01E02.mkv")
        XCTAssertEqual(part.size, 1_000_000)
        XCTAssertEqual(part.container, "mkv")
    }

    func test_streams() throws {
        let streams = try XCTUnwrap(make().Media?.first?.Part?.first?.Stream)
        XCTAssertEqual(streams.map(\.streamType), [1, 2, 3, 3])
        // VideoTrack carries no container index, so the video stream has none.
        XCTAssertEqual(streams.map(\.index), [nil, 1, 4, nil])

        let video = streams[0]
        XCTAssertTrue(video.isDolbyVision)
        XCTAssertEqual(video.DOVIProfile, 8)

        let audio = streams[1]
        XCTAssertEqual(audio.displayTitle, "English")
        XCTAssertEqual(audio.extendedDisplayTitle, "English (EAC3 5.1)")
        XCTAssertEqual(audio.languageCode, "eng")
        XCTAssertEqual(audio.language, Locale.current.localizedString(forLanguageCode: "eng")?.capitalized,
                       "the display name, as Plex sends it")
        XCTAssertNotEqual(audio.language, "eng")
        XCTAssertEqual(audio.channels, 6)
        XCTAssertEqual(audio.default, true)

        XCTAssertNil(streams[2].key)
        let external = streams[3]
        XCTAssertEqual(external.key, srtURL.absoluteString)
        XCTAssertEqual(external.forced, true)
        XCTAssertEqual(external.hearingImpaired, true)
        // Distinct ids even with no index, so pickers never collide.
        XCTAssertEqual(Set(streams.map(\.id)).count, streams.count)
    }

    func test_nonNumericTrackIDs_getDistinctStreamIDs() throws {
        func sidecar(_ id: String) -> SubtitleTrack {
            SubtitleTrack(id: id, index: 0, codec: "srt", language: nil, title: nil, extendedTitle: nil,
                          isDefault: false, isForced: false, isHearingImpaired: false,
                          isEmbedded: false, externalURL: srtURL, isSelected: false)
        }
        let src = MediaSource(
            id: "s", container: nil, duration: 10, bitrate: nil, fileSize: nil, fileName: nil,
            videoResolution: nil, videoTracks: [], audioTracks: [],
            subtitleTracks: [sidecar("sub-a"), sidecar("sub-b"), sidecar("12")],
            streamKind: .directPlay, streamURL: nil
        )
        let streams = try XCTUnwrap(
            ProviderPlaybackMetadata.make(detail: detail(episodeItem()), source: src, extras: PlaybackExtras())
                .Media?.first?.Part?.first?.Stream
        )
        XCTAssertEqual(streams.map(\.index), [nil, nil, nil])
        XCTAssertEqual(Set(streams.map(\.id)).count, 3)
        XCTAssertEqual(streams[2].id, 12)
    }

    func test_markersAndChapters() throws {
        let m = make()
        let marker = try XCTUnwrap(m.Marker?.first)
        XCTAssertEqual(marker.type, "intro")
        XCTAssertEqual(marker.startTimeOffset, 30_000)
        XCTAssertEqual(marker.endTimeOffset, 90_000)
        XCTAssertNotNil(m.introMarker)

        let chapters = try XCTUnwrap(m.Chapter)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[1].startTimeOffset, 355_855)
        XCTAssertEqual(chapters[0].endTimeOffset, 355_855)
        XCTAssertEqual(chapters.map(\.index), [1, 2])
        XCTAssertEqual(chapters[0].tag, "Opening")
        XCTAssertNil(chapters[0].thumb)
    }

    /// The player skips a credits, recap or commercial marker without an id,
    /// so every provider marker needs a unique one, clear of IntroDB's.
    func test_everyMarkerGetsAUniqueSyntheticID() throws {
        let extras = PlaybackExtras(markers: [
            PlaybackMarker(kind: .intro, start: 30, end: 90),
            PlaybackMarker(kind: .recap, start: 0, end: 25),
            PlaybackMarker(kind: .credits, start: 1200, end: 1290),
            PlaybackMarker(kind: .commercial, start: 600, end: 660),
        ])
        let m = ProviderPlaybackMetadata.make(detail: detail(episodeItem()), source: source(), extras: extras)
        let ids = try XCTUnwrap(m.Marker).map(\.id)
        XCTAssertFalse(ids.contains(nil))
        XCTAssertEqual(Set(ids).count, 4)
        XCTAssertTrue(ids.allSatisfy { ($0 ?? 0) < 0 && ($0 ?? 0) > -9000 })
        XCTAssertNotNil(m.creditsMarkers.first?.id)
    }

    func test_durationFallsBackToRuntime() {
        let empty = MediaSource(
            id: "s", container: nil, duration: 0, bitrate: nil, fileSize: nil, fileName: nil,
            videoResolution: nil, videoTracks: [], audioTracks: [], subtitleTracks: [],
            streamKind: .directPlay, streamURL: nil
        )
        let m = ProviderPlaybackMetadata.make(detail: detail(episodeItem()), source: empty, extras: PlaybackExtras())
        XCTAssertEqual(m.duration, 1_300_000)
        XCTAssertNil(m.Marker)
    }

    // MARK: - MediaItem.seriesTitle storage

    func test_mediaItem_withoutSeriesTitle_decodesNil() throws {
        let data = try JSONEncoder().encode(episodeItem(seriesTitle: nil))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "seriesTitle")
        let old = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(MediaItem.self, from: old)
        XCTAssertNil(decoded.seriesTitle)
        XCTAssertEqual(decoded.title, "Light Bulb")
    }

    func test_mediaItem_seriesTitle_roundTrips() throws {
        let data = try JSONEncoder().encode(episodeItem())
        XCTAssertEqual(try JSONDecoder().decode(MediaItem.self, from: data).seriesTitle, "Abbott Elementary")
    }

    func test_mediaItem_withLogo_keepsSeriesTitle() {
        let logo = URL(string: "http://x/logo.png")
        XCTAssertEqual(episodeItem().withLogoIfMissing(logo).seriesTitle, "Abbott Elementary")
    }
}
