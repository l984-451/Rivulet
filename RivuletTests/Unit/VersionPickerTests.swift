// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class VersionPickerTests: XCTestCase {

    private func source(_ id: String, res: String = "1080", height: Int = 1080, codec: String = "hevc",
                        range: VideoTrack.VideoRange = .sdr, size: Int64? = 5_730_000_000,
                        file: String? = nil, name: String? = nil) -> MediaSource {
        let video = VideoTrack(id: "v\(id)", codec: codec, profile: nil, level: nil, width: nil, height: height,
                               frameRate: nil, bitrate: nil, videoRange: range, isDefault: true, scanType: nil)
        let audio = AudioTrack(id: "a\(id)", index: 0, codec: "aac", profile: nil, channels: 6,
                               channelLayout: "5.1", language: "en", title: nil, extendedTitle: nil,
                               bitrate: nil, samplingRate: nil, isDefault: true, isForced: false, isSelected: true)
        return MediaSource(id: id, container: "mkv", duration: 100, bitrate: nil, fileSize: size,
                           fileName: file, versionName: name, videoResolution: res,
                           videoTracks: [video], audioTracks: [audio], subtitleTracks: [],
                           streamKind: .directPlay, streamURL: nil)
    }

    private func detail(_ sources: [MediaSource]) -> MediaItemDetail {
        MediaItemDetail(item: JellyfinFixtures.mediaItem("m1"), tagline: nil, genres: [], studios: [], cast: [],
                        directors: [], writers: [], chapters: [], mediaSources: sources, trailerURL: nil,
                        contentRating: nil, rating: nil, nextEpisode: nil, collections: [])
    }

    func test_label_isResolutionRangeCodecAudioSize() {
        let label = VersionPicker.labels(for: [source("a", res: "4k", height: 2160,
                                                      range: .dolbyVision(profile: 8))])[0]
        XCTAssertTrue(label.hasPrefix("4K · DV · HEVC · AAC 5.1 · "), label)
        XCTAssertTrue(label.hasSuffix("GB"), label)
    }

    func test_label_leadsWithAVersionName() {
        XCTAssertTrue(VersionPicker.labels(for: [source("a", name: "Directors Cut")])[0]
            .hasPrefix("Directors Cut · 1080p"))
    }

    func test_label_skipsResolutionNames() {
        XCTAssertTrue(VersionPicker.labels(for: [source("a", name: "1080P")])[0].hasPrefix("1080p · HEVC"))
        XCTAssertTrue(VersionPicker.labels(for: [source("a", name: "4K")])[0].hasPrefix("1080p · HEVC"))
    }

    func test_labels_collision_appendsTheFileName() {
        let labels = VersionPicker.labels(for: [source("a", file: "/m/Heat (Bluray).mkv"),
                                                source("b", file: "/m/Heat (WEB).mkv")])
        XCTAssertTrue(labels[0].hasSuffix(" · Heat (Bluray)"), labels[0])
        XCTAssertTrue(labels[1].hasSuffix(" · Heat (WEB)"), labels[1])
    }

    func test_codecName() {
        XCTAssertEqual(VersionPicker.codecName("h264"), "H.264")
        XCTAssertEqual(VersionPicker.codecName("mpeg2video"), "MPEG-2")
        XCTAssertEqual(VersionPicker.codecName("prores"), "PRORES")
        XCTAssertNil(VersionPicker.codecName("unknown"))
    }

    func test_versions_bestFirst_andEmptyForOne() {
        XCTAssertEqual(VersionPicker.versions(in: detail([source("hd"), source("uhd", res: "4k", height: 2160)]))
            .map(\.id), ["uhd", "hd"])
        XCTAssertTrue(VersionPicker.versions(in: detail([source("only")])).isEmpty)
    }

    func test_versions_stackedFileIsOneVersion() {
        // One Plex Media with two Parts maps to two MediaSources sharing an id.
        XCTAssertTrue(VersionPicker.versions(in: detail([source("m"), source("m")])).isEmpty)
    }
}
