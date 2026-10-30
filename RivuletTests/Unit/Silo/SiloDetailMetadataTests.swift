// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class SiloDetailMetadataTests: XCTestCase {
    private let baseURL = URL(string: "https://silo.invalid")!

    private func version(_ fields: String = "", hdr: Bool = false) throws -> MediaSource {
        let json = """
        {"file_id":"file-a","resolution":"2160p","codec_video":"hevc","codec_audio":"truehd",
         "hdr":\(hdr),"container":"mkv","file_size":1024,"bitrate":80000\(fields)}
        """
        let dto = try SiloJSON.decoder().decode(SiloVersion.self, from: Data(json.utf8))
        return SiloMediaMapper.source(dto, baseURL: baseURL)
    }

    func test_enabledSupplementalRTAudienceSurvivesSilosThreeRatingLimit() throws {
        let json = """
        {"content_id":"movie:mary","type":"movie","title":"Mary",
         "rating_rt_critic":95,"rating_rt_audience":95,
         "rating_sources":[{"source":"mdblist","score":83},{"source":"rt_audience","score":95}],
         "ratings":[{"source":"imdb","name":"IMDb","score":82,"display":"8.2"},
                    {"source":"tmdb","name":"TMDB","score":86,"display":"8.6"},
                    {"source":"rt_critic","name":"RT","score":95,"display":"95%"}]}
        """
        let dto = try SiloJSON.decoder().decode(SiloItem.self, from: Data(json.utf8))
        XCTAssertTrue(dto.hasSupplementalRTRatings)
        let enabled = [SiloRatingsCapability.Source(source: "rt_critic", name: "RT"),
                       SiloRatingsCapability.Source(source: "rt_audience", name: "RT Audience")]
        let detail = SiloMediaMapper.detail(dto, providerID: "silo:test", baseURL: baseURL, ratingSources: enabled)
        XCTAssertEqual(detail.ratings.map(\.source), [.imdb, .tmdb, .rottenTomatoes, .rottenTomatoesAudience])
        XCTAssertEqual(detail.ratings.last?.value, 9.5)
        XCTAssertFalse(detail.ratings.contains { $0.nativeDisplay?.sourceID == "mdblist" })

        for policy in [[], [enabled[0]]] {
            let hidden = SiloMediaMapper.detail(dto, providerID: "silo:test", baseURL: baseURL, ratingSources: policy)
            XCTAssertEqual(hidden.ratings.map(\.source), [.imdb, .tmdb, .rottenTomatoes])
        }
    }

    func test_supplementalRTKeepsCanonicalPrecedenceAndValidatesSourceScores() throws {
        let enabled = [SiloRatingsCapability.Source(source: "rt_audience", name: "RT Audience")]
        let canonicalJSON = """
        {"content_id":"movie:mary","type":"movie","title":"Mary","rating_rt_audience":95,
         "ratings":[{"source":"rt_audience","name":"Audience","score":89,"display":"89%"}]}
        """
        let canonical = try SiloJSON.decoder().decode(SiloItem.self, from: Data(canonicalJSON.utf8))
        XCTAssertFalse(canonical.hasSupplementalRTRatings)
        let detail = SiloMediaMapper.detail(canonical, providerID: "silo:test", baseURL: baseURL, ratingSources: enabled)
        XCTAssertEqual(detail.ratings.map(\.value), [8.9])
        for score in [-1, 0, 100, 101] {
            let json = """
            {"content_id":"movie:mary","type":"movie","title":"Mary","rating_rt_audience":\(score),"ratings":[]}
            """
            let dto = try SiloJSON.decoder().decode(SiloItem.self, from: Data(json.utf8))
            let detail = SiloMediaMapper.detail(dto, providerID: "silo:test", baseURL: baseURL, ratingSources: enabled)
            XCTAssertEqual(detail.ratings.map(\.value), (0...100).contains(score) ? [Double(score) / 10] : [])
        }
    }

    func test_catalogAndWatchDurationsKeepOnlyKnownVersionFactsWithoutProbedTracks() throws {
        for field in [#","duration":7200"#, #","duration_seconds":7200"#] {
            let source = try version(field, hdr: true)
            XCTAssertEqual(source.duration, 7200)
            XCTAssertEqual(source.videoTracks.first?.codec, "hevc")
            XCTAssertEqual(source.videoTracks.first?.videoRange, .hdr)
            XCTAssertNil(source.videoTracks.first?.width)
            XCTAssertNil(source.videoTracks.first?.profile)
            XCTAssertEqual(source.resolutionBadge, "4K")
            XCTAssertEqual(source.audioTracks.first?.codec, "truehd")
            XCTAssertFalse(source.audioTracks.first?.isAtmos ?? true)
            XCTAssertNil(source.audioTracks.first?.channels)
            XCTAssertEqual(source.bitrate, 80_000_000)
        }
        let unknown = try version()
        XCTAssertEqual(unknown.videoTracks.first?.videoRange, .unknown)
        XCTAssertNil(unknown.videoTracks.first?.sourceRangeLabel)
    }

    func test_atmosRequiresEvidenceOnThatAudioTrackAndJOCRequiresEAC3() throws {
        let source = try version("""
        ,"effective_audio_track_index":1,"file_name":"Film.TrueHD.Atmos.mkv","audio_tracks":[
          {"codec":"truehd","channels":8,"default":true},
          {"codec":"eac3","profile":"Dolby Digital Plus + JOC","channels":6,"default":false},
          {"codec":"truehd","profile":"JOC","default":false},
          {"codec":"truehd","embedded_title":"Dolby Atmos","default":false}
        ]
        """)
        XCTAssertEqual(source.audioTracks.map(\.isAtmos), [false, true, false, true])
        XCTAssertTrue(source.audioTracks[1].isSelected)
        let selected = try XCTUnwrap(source.audioTracks.first(where: { $0.isSelected }))
        XCTAssertTrue(selected.isAtmos)
        XCTAssertEqual(selected.codecLabel, "E-AC3", "Primary badges must describe the effective audio, not another track")
    }

    func test_explicitAtmosEvidenceReachesAudioMenuAndDetailsWithoutLabelingPlainTrueHD() throws {
        let source = try version("""
        ,"file_name":"Film.TrueHD.Atmos.mkv","audio_tracks":[
          {"codec":"truehd","channels":8,"language":"eng","default":true},
          {"codec":"truehd","embedded_title":"Dolby Atmos","channels":8,"language":"eng","default":false},
          {"codec":"truehd","title":"Dolby Atmos","channels":8,"language":"eng","default":false},
          {"codec":"truehd","title":"Main mix","embedded_title":"Dolby Atmos","channels":8,"language":"eng","default":false},
          {"codec":"truehd","layout":"7.1 Atmos","channels":8,"language":"eng","default":false},
          {"codec":"eac3","profile":"Dolby Digital Plus + JOC","channels":6,"language":"eng","default":false},
          {"codec":"truehd","profile":"JOC","channels":8,"language":"eng","default":false},
          {"codec":"truehd","profile":"Dolby TrueHD + Dolby Atmos","channels":8,"language":"eng","default":false}
        ]
        """)
        let expected = [
            "TrueHD 7.1", "TrueHD 7.1 Atmos", "TrueHD 7.1 Atmos", "TrueHD 7.1 Atmos",
            "TrueHD 7.1 Atmos", "E-AC3 5.1 Atmos", "TrueHD 7.1", "TrueHD 7.1 Atmos"
        ]
        XCTAssertEqual(source.audioTracks.map { MediaTrack(from: $0).audioMenuSubtitle }, expected)

        let item = try SiloJSON.decoder().decode(SiloItem.self, from: Data("""
        {"content_id":"movie-a","type":"movie","title":"Film"}
        """.utf8))
        let detail = SiloMediaMapper.detail(item, providerID: "silo:test", baseURL: baseURL)
        let metadata = ProviderPlaybackMetadata.make(detail: detail, source: source, extras: PlaybackExtras())
        let streams = try XCTUnwrap(metadata.Media?.first?.Part?.first?.Stream).filter(\.isAudio)
        let engineTracks = source.audioTracks.map {
            MediaTrack(id: 100 + $0.index, name: "English", language: "English",
                       codec: $0.codec, channels: $0.channels, streamIndex: $0.index)
        }
        let merged = TrackMerge.mergeAudio(engine: engineTracks, plex: streams.map { MediaTrack(from: $0) })
        XCTAssertEqual(merged.map(\.audioMenuSubtitle), expected,
                       "The player menu must retain each source track's explicit evidence after merging engine IDs")

        let sections = PlayerDetailsPaneView.mediaSections(
            metadata: metadata,
            modes: StreamingModeInfo(video: .directPlay, audio: .directPlay, subtitles: .directPlay))
        let audio = try XCTUnwrap(sections.first { $0.title == "AUDIO" })
        XCTAssertEqual(audio.rows.dropFirst().map(\.value), expected,
                       "Details must distinguish explicit Atmos from plain TrueHD without showing raw track titles")
    }

    func test_dolbyVisionProfileDoesNotInventBaseRangeAndRichFactsKeepNativeUnits() throws {
        let source = try version("""
        ,"video_tracks":[{"codec":"hevc","dv_profile":7,"dv_level":6,"dv_enhancement_layer":"fel",
          "width":3840,"height":2160,"frame_rate":"24000/1001","bit_depth":10,
          "pixel_format":"yuv420p10le","bitrate":70000,"interlaced":false}],
        "audio_tracks":[{"codec":"truehd","profile":"Dolby TrueHD + Dolby Atmos","channels":8,
          "layout":"7.1","bitrate":4000,"sample_rate":48000,"bit_depth":24,"default":true}]
        """)
        let video = try XCTUnwrap(source.videoTracks.first)
        XCTAssertEqual(video.videoRange, .dolbyVision(profile: 7))
        XCTAssertEqual(video.dolbyVisionEnhancementLayer, "fel")
        XCTAssertEqual(video.dolbyVisionLevel, 6)
        XCTAssertNil(video.compatibleRangeLabel)
        XCTAssertEqual(video.bitDepth, 10)
        XCTAssertEqual(video.bitrate, 70_000_000)
        XCTAssertEqual(try XCTUnwrap(video.frameRate), 24000.0 / 1001, accuracy: 0.00001)
        XCTAssertEqual(source.audioTracks.first?.bitrate, 4_000_000)
        XCTAssertEqual(source.audioTracks.first?.bitDepth, 24)
        XCTAssertEqual(source.audioTracks.first?.codecLabel, "TrueHD")
        XCTAssertEqual(source.audioTracks.first?.channelLayoutLabel, "7.1")
        XCTAssertTrue(source.audioTracks.first?.isAtmos ?? false)
    }

    func test_explicitRangeTypesAndCompatibilityPresenceSurviveWithoutInventingAProfile() throws {
        let cases: [(String, VideoTrack.VideoRange, String?)] = [
            (#""video_range_type":"DOVIWithHDR10Plus""#, .dolbyVision(profile: 0), "HDR10"),
            (#""video_range_type":"DOVIWithHLG""#, .dolbyVision(profile: 0), "HLG"),
            (#""dv_profile":8,"dv_bl_compat_id":1,"dv_bl_compat_id_present":true,"dv_config_present":true"#, .dolbyVision(profile: 8), "HDR10"),
            (#""dv_profile":8,"dv_bl_compat_id":4,"dv_bl_compat_id_present":false,"dv_config_present":true"#, .dolbyVision(profile: 8), nil),
            (#""video_range_type":"SDR""#, .sdr, nil)
        ]
        for (fields, expectedRange, expectedBase) in cases {
            let source = try version(",\"video_tracks\":[{\(fields),\"interlaced\":false}]", hdr: true)
            XCTAssertEqual(source.videoTracks.first?.videoRange, expectedRange)
            XCTAssertEqual(source.videoTracks.first?.compatibleRangeLabel, expectedBase)
        }
        let plus = try version(#","video_tracks":[{"video_range_type":"DOVIWithHDR10Plus","interlaced":false}]"#)
        XCTAssertTrue(plus.videoTracks.first?.hasHDR10Plus ?? false)
        XCTAssertEqual(plus.videoTracks.first?.sourceRangeLabel, "Dolby Vision")
    }

    func test_nativeMovieAndEpisodeRatingsKeepEverySourceNameAndNativeDisplayIncludingZero() throws {
        let ratings = """
        [{"source":"imdb","name":"IMDb","score":85,"display":"8.5"},
         {"source":"plugin_one","name":"One","score":84,"display":"4.2"},
         {"source":"plugin_two","name":"Two","score":0,"display":"0%"}]
        """
        for kind in ["movie", "episode"] {
            let json = """
            {"content_id":"item-a","type":"\(kind)","title":"Title","ratings":\(ratings)}
            """
            let dto = try SiloJSON.decoder().decode(SiloItem.self, from: Data(json.utf8))
            let detail = SiloMediaMapper.detail(dto, providerID: "silo:test", baseURL: baseURL)
            XCTAssertEqual(detail.chromeRatings.count, 3)
            XCTAssertEqual(detail.ratings.map(\.name), ["IMDb", "One", "Two"])
            XCTAssertEqual(detail.ratings.map(\.badgeText), ["8.5", "4.2", "0%"])
            XCTAssertTrue(detail.ratings.allSatisfy { $0.scale == nil })
            XCTAssertEqual(MediaRating.ordered(detail.ratings).count, 3)
        }
        XCTAssertNil(MediaRating(scoreOutOf100: .infinity, source: .unknown, sourceID: "x", name: "X", display: "inf"))
        XCTAssertNil(MediaRating(scoreOutOf100: 101, source: .unknown, sourceID: "x", name: "X", display: "101"))
        XCTAssertNil(SiloMediaMapper.bitsPerSecond(Int.max))
    }

    func test_nativeRatingIdentityRetainsTenDistinctPluginSources() {
        let ratings = (0..<10).compactMap {
            MediaRating(scoreOutOf100: Double($0 * 10), source: .unknown, sourceID: "source\($0)",
                        name: "Plugin \($0)", display: "\($0).0")
        }
        let ordered = MediaRating.ordered(ratings)
        XCTAssertEqual(ordered.count, 10)
        XCTAssertEqual(ordered.compactMap(\.nativeDisplay?.sourceID), ratings.compactMap(\.nativeDisplay?.sourceID))
    }

}
