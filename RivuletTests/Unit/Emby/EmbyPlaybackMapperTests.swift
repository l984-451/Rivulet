// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyPlaybackMapperTests.swift
//  RivuletTests
//
//  Media sources, tracks and markers mapped from captured Emby streams. Cases built by hand
//  (no capture exists) carry _unverified in their names.
//

import XCTest
@testable import Rivulet

@MainActor
final class EmbyPlaybackMapperTests: XCTestCase {
    private let base = URL(string: "http://emby.local:8096")!
    private typealias Fixtures = EmbyPlaybackStreamFixtures

    private func response(_ json: String) throws -> EmbyPlaybackInfoResponse { try EmbyTestJSON.decode(json) }

    private func rawSource(_ json: String) throws -> EmbyMediaSource {
        try XCTUnwrap(try response(json).mediaSources?.first)
    }

    private func source(_ json: String, token: String? = "tok", base: URL? = nil) throws -> MediaSource {
        let raw = try rawSource(json)
        return try XCTUnwrap(EmbyMediaMapper.mediaSource(
            raw, itemID: raw.itemId?.value ?? "0", playSessionID: "psid", baseURL: base ?? self.base, token: token))
    }

    private func stream(_ json: String) throws -> EmbyMediaStream { try EmbyTestJSON.decode(json) }

    // MARK: - Stream indexes

    func test_embeddedStreamsKeepTheContainerIndex_andSidecarsFollowAsExternalUrls() throws {
        let mapped = try source(EmbyPlaybackFixtures.directPlay4_10_2)
        XCTAssertEqual(mapped.videoTracks.map(\.id), ["0"])
        XCTAssertEqual(mapped.audioTracks.map(\.index), [1], "no Jellyfin-style offset subtraction")
        let embedded = mapped.subtitleTracks.filter(\.isEmbedded)
        XCTAssertEqual(embedded.map(\.index), Array(2...8))
        XCTAssertEqual(embedded.map(\.id), (2...8).map(String.init))
        let sidecars = mapped.subtitleTracks.filter { !$0.isEmbedded }
        XCTAssertEqual(sidecars.map(\.index), [9, 10, 11, 12])
        XCTAssertEqual(sidecars.first?.externalURL?.absoluteString,
                       "http://emby.local:8096/Videos/857/mediasource_857/Subtitles/9/0/Stream.srt?api_key=tok")
    }

    func test_sidecarUrlEqualsTheServersDeliveryUrl() throws {
        let raw = try rawSource(EmbyPlaybackFixtures.directPlay4_10_2)
        let deliveries = (raw.mediaStreams ?? []).filter { $0.isExternal == true }.compactMap(\.deliveryUrl)
        let mapped = try source(EmbyPlaybackFixtures.directPlay4_10_2)
        let built = mapped.subtitleTracks.filter { !$0.isEmbedded }.compactMap { $0.externalURL?.absoluteString }
        XCTAssertEqual(deliveries.count, 4)
        XCTAssertEqual(built.map { $0.replacingOccurrences(of: "http://emby.local:8096", with: "") },
                       deliveries.map { $0.replacingOccurrences(of: "<ACCESS_TOKEN>", with: "tok") })
    }

    func test_attachmentsAreSkippedWithoutRenumbering() throws {
        let baywatch = try source(EmbyPlaybackFixtures.directPlay4K4_10_2)
        XCTAssertEqual(baywatch.audioTracks.map(\.index), Array(1...6))
        XCTAssertEqual(baywatch.subtitleTracks.map(\.index), Array(7...11))
        let island = try source(Fixtures.island2Audio)
        XCTAssertEqual(island.audioTracks.map(\.index), [1, 2])
        XCTAssertEqual(island.subtitleTracks.map(\.index), [3, 4], "EmbeddedImage 5 and 6 are not tracks")
    }

    func test_defaultFlags_twoDefaultAudiosButOneSelected() throws {
        let island = try source(Fixtures.island2Audio)
        XCTAssertEqual(island.audioTracks.map(\.isDefault), [true, true])
        XCTAssertEqual(island.audioTracks.map(\.isSelected), [true, false], "DefaultAudioStreamIndex picks one")
    }

    func test_forcedAndLanguageFlagsOnEmbeddedSubtitles() throws {
        let mapped = try source(EmbyPlaybackFixtures.directPlay4_10_2)
        let forced = try XCTUnwrap(mapped.subtitleTracks.first { $0.index == 2 })
        XCTAssertTrue(forced.isForced)
        XCTAssertEqual(forced.language, "eng")
        XCTAssertEqual(forced.title, "Forced")
        XCTAssertEqual(forced.codec, "subrip")
        let image = try XCTUnwrap(mapped.subtitleTracks.first { $0.index == 3 })
        XCTAssertEqual(image.codec, "pgssub", "image subtitles are embedded tracks, codec lower-cased")
        XCTAssertTrue(image.isEmbedded)
        XCTAssertTrue(mapped.subtitleTracks.filter { !$0.isEmbedded }.allSatisfy { $0.codec == "srt" })
    }

    func test_imageSidecarsAreNeverOffered_unverified() throws {
        let png = try stream(#"{"Index":9,"Type":"Subtitle","Codec":"PGSSUB","IsExternal":true,"IsTextSubtitleStream":false}"#)
        XCTAssertNil(EmbyMediaMapper.subtitleTrack(png, itemID: "1", sourceID: "s", defaultIndex: nil, baseURL: base, token: "t"))
    }

    // MARK: - Codec spellings and languages

    func test_codecSpellingsMatchCaseInsensitively() throws {
        XCTAssertEqual(EmbyMediaMapper.sidecarFormat("SRT"), "srt")
        XCTAssertEqual(EmbyMediaMapper.sidecarFormat("SubRip"), "srt")
        XCTAssertEqual(EmbyMediaMapper.sidecarFormat("ASS"), "ass")
        XCTAssertEqual(EmbyMediaMapper.sidecarFormat("ssa"), "ass")
        XCTAssertEqual(EmbyMediaMapper.sidecarFormat("WebVTT"), "vtt")
        let upper = try stream(#"{"Index":1,"Type":"Audio","Codec":"EAC3","Channels":6}"#)
        XCTAssertEqual(EmbyMediaMapper.audioTrack(upper, defaultIndex: nil)?.codec, "eac3")
        let dts = try stream(#"{"Index":1,"Type":"Audio","Codec":"DTS","Channels":8}"#)
        XCTAssertEqual(EmbyMediaMapper.audioTrack(dts, defaultIndex: nil)?.codec, "dca")
        let video = try stream(#"{"Index":0,"Type":"Video","Codec":"HEVC","ExtendedVideoType":"DOLBYVISION","ExtendedVideoSubType":"DOVIPROFILE81"}"#)
        XCTAssertEqual(EmbyMediaMapper.videoTrack(video)?.codec, "hevc")
        XCTAssertEqual(EmbyMediaMapper.videoTrack(video)?.videoRange, .dolbyVision(profile: 8))
    }

    func test_languagesAreNormalizedFromBibliographicToTerminology() throws {
        let abbott = try source(Fixtures.abbottEpisode)
        let languages = abbott.subtitleTracks.compactMap(\.language)
        XCTAssertTrue(languages.contains("fra"), "fre")
        XCTAssertTrue(languages.contains("deu"), "ger")
        XCTAssertFalse(languages.contains("fre") || languages.contains("ger"))
        XCTAssertEqual(EmbyMediaMapper.language("chi"), "zho")
        XCTAssertEqual(EmbyMediaMapper.language("nob"), "nob")
        XCTAssertEqual(EmbyMediaMapper.language("ENG"), "eng")
        XCTAssertNil(EmbyMediaMapper.language("und"))
        XCTAssertNil(EmbyMediaMapper.language(nil))
    }

    // MARK: - HDR and Dolby Vision

    private func range(_ name: String) throws -> VideoTrack.VideoRange {
        let json = try XCTUnwrap(Fixtures.videoStreams[name])
        return try XCTUnwrap(EmbyMediaMapper.videoTrack(try stream(json))).videoRange
    }

    func test_hdrTable() throws {
        XCTAssertEqual(try range("sdr"), .sdr)
        XCTAssertEqual(try range("hdr10"), .hdr10)
        XCTAssertEqual(try range("dvP5"), .dolbyVision(profile: 5))
        XCTAssertEqual(try range("dvP81"), .dolbyVision(profile: 8))
        XCTAssertEqual(try range("dvHlgBase"), .dolbyVision(profile: 0), "subtype None: profile unknown")
        XCTAssertEqual(try range("dvUnknownProfile"), .dolbyVision(profile: 0))
    }

    func test_p7DualLayerThatEmbyReadsAsHdr10_staysHdr10() throws {
        XCTAssertEqual(try range("p7ReadAsHdr10"), .hdr10, "the engine's own probe is the authority")
    }

    func test_dolbyVisionP7Subtype_isProfileSeven() throws {
        let p7 = try stream(#"{"Index":0,"Type":"Video","Codec":"hevc","ExtendedVideoType":"DolbyVision","ExtendedVideoSubType":"DoviProfile76"}"#)
        XCTAssertEqual(EmbyMediaMapper.videoTrack(p7)?.videoRange, .dolbyVision(profile: 7))
    }

    func test_hdr10PlusAndHlg_unverified() throws {
        let plus = try stream(#"{"Index":0,"Type":"Video","Codec":"hevc","ExtendedVideoType":"Hdr10Plus"}"#)
        XCTAssertEqual(EmbyMediaMapper.videoTrack(plus)?.videoRange, .hdr10Plus)
        let hlg = try stream(#"{"Index":0,"Type":"Video","Codec":"hevc","ExtendedVideoType":"HyperLogGamma"}"#)
        XCTAssertEqual(EmbyMediaMapper.videoTrack(hlg)?.videoRange, .hlg)
    }

    func test_videoTrackFields() throws {
        let track = try XCTUnwrap(EmbyMediaMapper.videoTrack(try stream(try XCTUnwrap(Fixtures.videoStreams["hdr10"]))))
        XCTAssertEqual(track.codec, "hevc")
        XCTAssertEqual(track.width, 3840)
        XCTAssertEqual(track.height, 2076, "the stored size, cropped")
        XCTAssertEqual(track.level, 153)
        XCTAssertEqual(track.profile, "Main 10")
        XCTAssertEqual(track.scanType, "progressive")
    }

    // MARK: - Atmos and DTS:X by title

    private func audio(_ key: String) throws -> AudioTrack {
        try XCTUnwrap(EmbyMediaMapper.audioTrack(try stream(try XCTUnwrap(Fixtures.audioStreams[key])), defaultIndex: nil))
    }

    func test_atmosComesFromTheTitleOnTheCodecsThatCanCarryIt() throws {
        XCTAssertEqual(try audio("eac3/None").profile, "Atmos", "Title: Dolby Atmos 7.1 Mix")
        let trueHD = try audio("truehd/None")
        XCTAssertEqual(trueHD.profile, "Atmos", "only the release title says so")
        XCTAssertEqual(trueHD.qualityLabel, "TrueHD 7.1 Atmos")
        XCTAssertNil(try audio("ac3/None").profile, "the AC3 core carries the same release title")
        XCTAssertEqual(try audio("dts/DTS-HD MA").profile, "DTS-HD MA")
        XCTAssertEqual(try audio("aac/LC").profile, "LC")
    }

    func test_dtsXFromTheTitle_unverified() {
        XCTAssertEqual(EmbyMediaMapper.spatialAudioTag(codec: "dca", title: "Movie.2160p.DTS-X.7.1"), "DTS:X")
        XCTAssertEqual(EmbyMediaMapper.spatialAudioTag(codec: "dca", title: "DTS:X 7.1"), "DTS:X")
        XCTAssertNil(EmbyMediaMapper.spatialAudioTag(codec: "dca", title: "DTS-HD MA 7.1"))
        XCTAssertNil(EmbyMediaMapper.spatialAudioTag(codec: "aac", title: "Dolby Atmos"))
    }

    // MARK: - Opaque source ids

    func test_sourceIdsAreOpaque_acrossVersions() throws {
        let four8 = try source(EmbyPlaybackFixtures.directPlay4_8_11)
        XCTAssertEqual(four8.id.count, 32)
        XCTAssertFalse(four8.id.hasPrefix("mediasource_"))
        XCTAssertTrue(four8.streamURL?.absoluteString.contains("MediaSourceId=\(four8.id)&") == true)
        let four9 = try source(Fixtures.direct4_9_5)
        XCTAssertEqual(four9.id, "mediasource_19")
        XCTAssertEqual(try source(EmbyPlaybackFixtures.directPlay4_10_2).id, "mediasource_857")
    }

    func test_aSourceWithoutAnId_isDroppedNotGivenTheItemId() throws {
        let nameless: EmbyMediaSource = try EmbyTestJSON.decode(#"{"Name":"x","Container":"mkv"}"#)
        XCTAssertNil(EmbyMediaMapper.mediaSource(nameless, itemID: "857", playSessionID: nil, baseURL: base, token: "t"))
    }

    func test_sourceFieldsTheRankingNeeds() throws {
        let mapped = try source(EmbyPlaybackFixtures.directPlay4_10_2)
        XCTAssertEqual(mapped.container, "mkv")
        XCTAssertEqual(mapped.bitrate, 7_199_419)
        XCTAssertEqual(mapped.fileSize, 6_215_719_571)
        XCTAssertEqual(mapped.duration, 6906.912, accuracy: 0.001)
        XCTAssertEqual(mapped.versionName, "28 Years Later (Bluray-1080p)")
        XCTAssertEqual(mapped.fileName, "28 Years Later (Bluray-1080p).mkv", "the file's name, extension included")
        XCTAssertEqual(mapped.streamKind, .directPlay)
    }

    // MARK: - Direct URL

    func test_directUrl_isStaticWithApiKey_neverApiKeyOrHeaders() throws {
        let url = try XCTUnwrap(try source(EmbyPlaybackFixtures.directPlay4_10_2).streamURL)
        XCTAssertEqual(url.path, "/Videos/857/stream")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.map(\.name), ["static", "MediaSourceId", "PlaySessionId", "api_key"])
        XCTAssertEqual(items.map(\.value), ["true", "mediasource_857", "psid", "tok"])
        XCTAssertFalse(url.absoluteString.contains("ApiKey"))
    }

    func test_directUrl_keepsAProxySubpath() throws {
        let proxied = try source(EmbyPlaybackFixtures.directPlay4_10_2, base: URL(string: "https://media.example.com/emby-proxy/")!)
        XCTAssertEqual(proxied.streamURL?.path, "/emby-proxy/Videos/857/stream")
        XCTAssertEqual(proxied.streamURL?.host, "media.example.com")
    }

    func test_withoutAToken_aSourceHasNoStreamUrl_andTokenFreeSidecarUrls() throws {
        let listed = try source(EmbyPlaybackFixtures.directPlay4_10_2, token: nil)
        XCTAssertNil(listed.streamURL)
        let sidecars = listed.subtitleTracks.filter { !$0.isEmbedded }
        XCTAssertEqual(sidecars.first?.externalURL?.absoluteString,
                       "http://emby.local:8096/Videos/857/mediasource_857/Subtitles/9/0/Stream.srt")
        XCTAssertTrue(listed.subtitleTracks.filter(\.isEmbedded).allSatisfy { $0.externalURL == nil })
        XCTAssertEqual(listed.subtitleTracks.count, 11, "the tracks are still listed")
    }

    // MARK: - Markers

    private struct ChapterHolder: Decodable { let chapters: [EmbyChapter] }

    func test_markers_realServerChaptersAreAllFiller_soTheyYieldNone() throws {
        let holder: ChapterHolder = try EmbyTestJSON.decode(Fixtures.chapters28yl)
        XCTAssertEqual(holder.chapters.count, 17)
        XCTAssertTrue(holder.chapters.allSatisfy { $0.markerType == "Chapter" })
        XCTAssertTrue(holder.chapters.contains { $0.name == "End Credits" }, "a real name must not become a marker")
        XCTAssertEqual(EmbyMediaMapper.markers(holder.chapters, runtime: 6906.9), [])
    }

    func test_markers_introAndCredits_unverified() throws {
        let holder: ChapterHolder = try EmbyTestJSON.decode("""
        {"Chapters":[{"StartPositionTicks":0,"Name":"Chapter 1","MarkerType":"Chapter"},
        {"StartPositionTicks":600000000,"Name":"Intro","MarkerType":"IntroStart"},
        {"StartPositionTicks":1500000000,"Name":"","MarkerType":"IntroEnd"},
        {"StartPositionTicks":30000000000,"Name":"Credits","MarkerType":"CreditsStart"}]}
        """)
        XCTAssertEqual(EmbyMediaMapper.markers(holder.chapters, runtime: 3300), [
            PlaybackMarker(kind: .intro, start: 60, end: 150),
            PlaybackMarker(kind: .credits, start: 3000, end: 3300)
        ])
        XCTAssertEqual(EmbyMediaMapper.markers(holder.chapters, runtime: nil).map(\.kind), [.intro], "credits need a runtime to end on")
    }

    func test_markers_anIntroStartWithoutAnEndIsDropped_unverified() throws {
        let holder: ChapterHolder = try EmbyTestJSON.decode(#"{"Chapters":[{"StartPositionTicks":600000000,"MarkerType":"IntroStart"}]}"#)
        XCTAssertEqual(EmbyMediaMapper.markers(holder.chapters, runtime: 3300), [])
    }

    // MARK: - Track join

    /// The engine reports FFmpeg's stream index, Emby's embedded `Index` is the same number, so
    /// TrackMerge joins them directly. Jellyfin's offset (index minus sidecar count) would miss.
    func test_embeddedIndexesJoinTheEnginesTracksUnshifted() throws {
        let mapped = try source(EmbyPlaybackFixtures.directPlay4_10_2)
        let emby = mapped.subtitleTracks.map(MediaTrack.init(from:))
        // What the engine lists: the container's subtitle streams 2...8, then the four registered sidecars.
        let engineEmbedded = (2...8).map { MediaTrack(id: $0, name: "stream \($0)", streamIndex: $0) }
        let engineSidecars = (0..<4).map { MediaTrack(id: 100 + $0, name: "sidecar \($0)", isExternal: true) }
        let merged = TrackMerge.mergeSubtitles(engine: engineEmbedded + engineSidecars, plex: emby)

        for track in merged.prefix(7) {
            let counterpart = try XCTUnwrap(mapped.subtitleTracks.first { $0.index == track.streamIndex })
            XCTAssertEqual(track.extendedDisplayTitle, counterpart.extendedTitle, "index \(track.streamIndex ?? -1)")
            XCTAssertEqual(track.isForced, counterpart.isForced)
        }
        XCTAssertEqual(merged.prefix(7).map(\.id), Array(2...8), "the engine's id stays the selection key")
        let sidecarTitles = mapped.subtitleTracks.filter { !$0.isEmbedded }.map(\.extendedTitle)
        XCTAssertEqual(merged.suffix(4).map(\.extendedDisplayTitle), sidecarTitles, "sidecars pair in order")
    }

    func test_audioJoinsOnTheSameIndex() throws {
        let mapped = try source(EmbyPlaybackFixtures.directPlay4K4_10_2)
        let emby = mapped.audioTracks.map(MediaTrack.init(from:))
        let engine = (1...6).map { MediaTrack(id: $0, name: "stream \($0)", streamIndex: $0) }
        let merged = TrackMerge.mergeAudio(engine: engine, plex: emby)
        XCTAssertEqual(merged.map(\.languageCode), mapped.audioTracks.map(\.language))
        XCTAssertEqual(merged.map(\.extendedDisplayTitle), mapped.audioTracks.map(\.extendedTitle))
    }
}
