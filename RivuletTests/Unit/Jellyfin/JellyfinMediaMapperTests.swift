// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  JellyfinMediaMapperTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

@MainActor
final class JellyfinMediaMapperTests: XCTestCase {
    private let base = JellyfinFixtures.baseURL
    private let pid = "jellyfin:srv"

    private func item(_ json: String) -> MediaItem {
        JellyfinMediaMapper.item(JellyfinFixtures.decode(json), providerID: pid, baseURL: base)
    }

    // MARK: - Items

    func test_episode_hierarchyAndNumbers() {
        let ep = item(JellyfinFixtures.episode)
        XCTAssertEqual(ep.ref, MediaItemRef(providerID: pid, itemID: "ep1"))
        XCTAssertEqual(ep.kind, .episode)
        XCTAssertEqual(ep.parentRef?.itemID, "season1")
        XCTAssertEqual(ep.grandparentRef?.itemID, "show1")
        XCTAssertEqual(ep.episodeNumber, 1)
        XCTAssertEqual(ep.seasonNumber, 1)
        XCTAssertEqual(ep.runtime, 3456)
        XCTAssertEqual(ep.releaseDate, "2008-01-20")
    }

    func test_episode_userState_fromTicksAndSevenDigitDates() throws {
        let state = item(JellyfinFixtures.episode).userState
        XCTAssertEqual(state.viewOffset, 600)
        XCTAssertTrue(state.isFavorite)
        XCTAssertFalse(state.isPlayed)
        let viewed = try XCTUnwrap(state.lastViewedAt)
        XCTAssertEqual(viewed.timeIntervalSince1970, 1_788_293_730.123, accuracy: 0.001)
    }

    func test_episode_artwork_fallsBackToShow() {
        let ep = item(JellyfinFixtures.episode)
        XCTAssertEqual(ep.artwork.poster?.absoluteString, "http://jf.local:8096/Items/ep1/Images/Primary?tag=epPrim")
        XCTAssertEqual(ep.artwork.backdrop?.absoluteString, "http://jf.local:8096/Items/show1/Images/Backdrop?tag=showBack")
        XCTAssertEqual(ep.artwork.logo?.absoluteString, "http://jf.local:8096/Items/show1/Images/Logo?tag=showLogo")
        XCTAssertEqual(ep.parentArtwork?.poster?.absoluteString, "http://jf.local:8096/Items/season1/Images/Primary?tag=seasonPrim")
        XCTAssertEqual(ep.grandparentArtwork?.poster?.absoluteString, "http://jf.local:8096/Items/show1/Images/Primary?tag=showPrim")
    }

    func test_artwork_carriesNoToken() {
        XCTAssertFalse(item(JellyfinFixtures.episode).artwork.poster!.absoluteString.contains("ApiKey"))
    }

    func test_series_childProgress_fromUnplayedCount() {
        let show = item(JellyfinFixtures.series)
        XCTAssertEqual(show.kind, .show)
        XCTAssertEqual(show.childProgress, ChildProgress(played: 12, total: 62))
    }

    func test_libraryFolderIsNeverAParent() {
        XCTAssertNil(item(JellyfinFixtures.series).parentRef)
        XCTAssertNil(item(JellyfinFixtures.movie).parentRef)
    }

    func test_bareMovie_mapsWithoutOptionalFields() {
        let movie = item(JellyfinFixtures.movie)
        XCTAssertEqual(movie.kind, .movie)
        XCTAssertNil(movie.artwork.poster)
        XCTAssertEqual(movie.userState.viewOffset, 0)
    }

    // MARK: - Libraries

    func test_libraries_keepRenderableKindsOnly() {
        let views: JFQueryResult = JellyfinFixtures.decode(JellyfinFixtures.userViews)
        let libs = views.items!.compactMap { JellyfinMediaMapper.library($0, providerID: pid) }
        XCTAssertEqual(libs.map(\.kind), [.movies, .shows, .mixed])
        XCTAssertEqual(libs.map(\.id), ["a", "b", "c"])
    }

    // MARK: - Media source

    private func source() -> MediaSource {
        let info: JFPlaybackInfoResponse = JellyfinFixtures.decode(JellyfinFixtures.playbackInfo)
        return JellyfinMediaMapper.mediaSource(
            info.mediaSources![0], itemID: "ep1", playSessionID: "psid-1", baseURL: base, token: "tok"
        )
    }

    func test_source_streamURL_isStaticFileWithApiKey() {
        XCTAssertEqual(source().streamURL?.absoluteString,
                       "http://jf.local:8096/Videos/ep1/stream?static=true&mediaSourceId=src-4k&playSessionId=psid-1&ApiKey=tok")
    }

    func test_source_fields() {
        let src = source()
        XCTAssertEqual(src.id, "src-4k")
        XCTAssertEqual(src.container, "mkv")
        XCTAssertEqual(src.duration, 3456)
        XCTAssertEqual(src.fileSize, 60_000_000_000)
        XCTAssertEqual(src.streamKind, .directPlay)
    }

    func test_video_dolbyVisionProfile() {
        let video = source().videoTracks.first
        XCTAssertEqual(video?.videoRange, .dolbyVision(profile: 8))
        XCTAssertEqual(video?.scanType, "progressive")
    }

    func test_audio_badgesMatchPlex() {
        let audio = source().audioTracks
        XCTAssertEqual(audio.map(\.index), [1, 2])
        XCTAssertEqual(audio[0].qualityLabel, "TrueHD 7.1 Atmos")
        XCTAssertEqual(audio[1].qualityLabel, "DTS-HD MA 5.1")
    }

    func test_audio_serverDefaultIsSelected() {
        let audio = source().audioTracks
        XCTAssertFalse(audio[0].isSelected)
        XCTAssertTrue(audio[1].isSelected)
    }

    func test_subtitles_externalTextGetsSidecarURL_externalImageDropped() {
        let subs = source().subtitleTracks
        XCTAssertEqual(subs.count, 3)
        XCTAssertEqual(subs[0].externalURL?.absoluteString,
                       "http://jf.local:8096/Videos/ep1/src-4k/Subtitles/0/Stream.srt")
        XCTAssertEqual(subs[1].externalURL?.absoluteString,
                       "http://jf.local:8096/Videos/ep1/src-4k/Subtitles/1/Stream.ass")
        XCTAssertTrue(subs[0].isForced)
        XCTAssertTrue(subs[0].isSelected)
        XCTAssertTrue(subs[2].isEmbedded)
        XCTAssertNil(subs[2].externalURL)
    }

    /// The engine joins tracks to this metadata on the CONTAINER stream index.
    /// Jellyfin numbers its external files first, so its Index runs ahead of
    /// the container by the number of external streams.
    func test_embeddedStreams_carryContainerIndex_notJellyfinIndex() {
        let src = source()
        XCTAssertEqual(src.audioTracks.map(\.index), [1, 2])
        XCTAssertEqual(src.subtitleTracks[2].index, 3)
    }

    /// The server's own Index stays the track id: playback reports and
    /// track selection speak Jellyfin's numbering.
    func test_trackIDs_keepJellyfinIndex() {
        let src = source()
        XCTAssertEqual(src.audioTracks.map(\.id), ["4", "5"])
        XCTAssertEqual(src.subtitleTracks.map(\.id), ["0", "1", "6"])
    }

    // MARK: - Video range

    private func range(_ type: String, transfer: String?) -> VideoTrack.VideoRange? {
        let stream: JFMediaStream = JellyfinFixtures.decode(JellyfinFixtures.videoStream(rangeType: type, transfer: transfer))
        return JellyfinMediaMapper.videoTrack(stream)?.videoRange
    }

    func test_dolbyVisionVariants_mapToDolbyVision() {
        XCTAssertEqual(range("DOVI", transfer: "smpte2084"), .dolbyVision(profile: 0))
        XCTAssertEqual(range("DOVIWithHDR10", transfer: "smpte2084"), .dolbyVision(profile: 0))
    }

    /// Out-of-spec Dolby Vision: the server keeps the base layer's range, so
    /// the badge must too.
    func test_dolbyVisionInvalid_fallsBackToBaseLayerRange() {
        XCTAssertEqual(range("DOVIInvalid", transfer: "smpte2084"), .hdr10)
        XCTAssertEqual(range("DOVIInvalid", transfer: "arib-std-b67"), .hlg)
        XCTAssertEqual(range("DOVIInvalid", transfer: "bt709"), .sdr)
        XCTAssertEqual(range("DOVIInvalid", transfer: nil), .sdr)
    }

    // MARK: - Detail

    private func detail() -> MediaItemDetail {
        JellyfinMediaMapper.detail(
            JellyfinFixtures.decode(JellyfinFixtures.series),
            nextEpisode: JellyfinFixtures.decode(JellyfinFixtures.episode),
            providerID: pid, baseURL: base, token: "tok"
        )
    }

    func test_detail_peopleByKind() {
        let d = detail()
        XCTAssertEqual(d.cast.map(\.name), ["Bryan Cranston", "Guest"])
        XCTAssertEqual(d.directors.map(\.name), ["Vince Gilligan"])
        XCTAssertEqual(d.writers.map(\.name), ["Some Writer"])
        XCTAssertEqual(d.cast[0].imageURL?.absoluteString, "http://jf.local:8096/Items/p1/Images/Primary?tag=pt")
        XCTAssertNil(d.cast[1].imageURL)
        XCTAssertEqual(d.cast[0].titleTmdbId, 1396)
        XCTAssertFalse(d.cast[0].titleIsMovie)
    }

    func test_detail_text() {
        let d = detail()
        XCTAssertEqual(d.tagline, "Remember my name")
        XCTAssertEqual(d.genres, ["Drama"])
        XCTAssertEqual(d.studios, ["AMC"])
        XCTAssertEqual(d.rating, 8.9)
        XCTAssertEqual(d.regionOfOrigin, "United States of America")
        XCTAssertEqual(d.nextEpisode?.ref.itemID, "ep1")
    }

    func test_detail_chapters_endAtNextStart() {
        let chapters = detail().chapters
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].end, 300)
        XCTAssertNil(chapters[1].end)
        XCTAssertEqual(chapters[0].thumbnailURL?.absoluteString,
                       "http://jf.local:8096/Items/show1/Images/Chapter/0?tag=c0")
    }

    func test_seriesName_becomesSeriesTitle_forEpisodesAndSeasons() {
        XCTAssertEqual(item(#"{"Id":"e","Type":"Episode","SeriesName":"Abbott Elementary"}"#).seriesTitle,
                       "Abbott Elementary")
        XCTAssertEqual(item(#"{"Id":"s","Type":"Season","SeriesName":"Abbott Elementary"}"#).seriesTitle,
                       "Abbott Elementary")
        XCTAssertNil(item(JellyfinFixtures.movie).seriesTitle)
    }

    func test_detail_providerIds_becomeLowercaseExternalIDs() {
        XCTAssertEqual(detail().externalIDs, ["tmdb": "1396", "imdb": "tt0903747"])
    }
}
