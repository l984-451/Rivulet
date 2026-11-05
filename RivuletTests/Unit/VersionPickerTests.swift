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
                        contentRating: nil, nextEpisode: nil, collections: [])
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

    // MARK: - Copies on other servers

    func test_options_singleFileAndNoCopies_isEmpty() {
        XCTAssertTrue(VersionPicker.options(current: [source("a")], currentServer: "Home", copies: []).isEmpty)
    }

    func test_options_copyOnAnotherServer_ranksBestFirstAndNamesServers() {
        let copy = VersionPicker.Copy(item: JellyfinFixtures.mediaItem("m2"), server: "Office",
                                      sources: [source("b", res: "4k", height: 2160)])
        let options = VersionPicker.options(current: [source("a")], currentServer: "Home", copies: [copy])
        XCTAssertEqual(options.map(\.source.id), ["b", "a"])
        XCTAssertNotNil(options[0].copy)
        XCTAssertNil(options[1].copy)
        let labels = VersionPicker.labels(for: options)
        XCTAssertTrue(labels[0].hasPrefix("4K") && labels[0].hasSuffix(" · Office"), labels[0])
        XCTAssertTrue(labels[1].hasSuffix(" · Home"), labels[1])
    }

    func test_labels_withCopies_areResolutionRangeAndServer() {
        let copy = VersionPicker.Copy(item: JellyfinFixtures.mediaItem("m2"), server: "Office",
                                      sources: [source("b", res: "4k", height: 2160, range: .hdr10)])
        let options = VersionPicker.options(current: [source("a")], currentServer: "Home", copies: [copy])
        XCTAssertEqual(VersionPicker.labels(for: options), ["4K · HDR · Office", "1080p · Home"])
    }

    func test_labels_withCopies_rowsThatReadTheSame_keepTheFullLabel() {
        let copy = VersionPicker.Copy(item: JellyfinFixtures.mediaItem("m2"), server: "Home",
                                      sources: [source("b", codec: "h264", size: 2_980_000_000)])
        let options = VersionPicker.options(current: [source("a")], currentServer: "Home", copies: [copy])
        let labels = VersionPicker.labels(for: options)
        XCTAssertEqual(Set(labels).count, 2, "\(labels)")
        XCTAssertTrue(labels.allSatisfy { $0.contains("AAC 5.1") && $0.hasSuffix(" · Home") }, "\(labels)")
    }

    func test_options_tie_keepsThisServerFirst() {
        let copy = VersionPicker.Copy(item: JellyfinFixtures.mediaItem("m2"), server: "Office", sources: [source("b")])
        let options = VersionPicker.options(current: [source("a")], currentServer: "Home", copies: [copy])
        XCTAssertEqual(options.map(\.source.id), ["a", "b"])
    }

    func test_options_withoutCopies_namesNoServer() {
        let options = VersionPicker.options(current: [source("a"), source("b", res: "4k", height: 2160)],
                                            currentServer: "Home", copies: [])
        XCTAssertTrue(options.allSatisfy { $0.server == nil })
    }

    func test_options_sameServerTwice_namesTheLibraries() {
        let copy = VersionPicker.Copy(item: JellyfinFixtures.mediaItem("m2"), server: "Home",
                                      sources: [source("b", res: "4k", height: 2160)], library: "TV 4K")
        let options = VersionPicker.options(current: [source("a")], currentServer: "Home",
                                            currentLibrary: "TV Shows", copies: [copy])
        XCTAssertEqual(options.map(\.server), ["Home · TV 4K", "Home · TV Shows"])
    }

    func test_pick_routesEachRowToWhatItPlays() {
        let copy = JellyfinFixtures.mediaItem("m2")
        let episode = JellyfinFixtures.mediaItem("e1", kind: .episode)
        let own = VersionPicker.Option(source: source("a"), copy: nil, server: nil)
        let other = VersionPicker.Option(source: source("b"), copy: copy, server: "Office")

        guard case .version("a") = VersionPicker.pick(own, playTarget: nil) else { return XCTFail() }
        guard case .item(let item, "b") = VersionPicker.pick(other, playTarget: nil), item.ref == copy.ref
        else { return XCTFail() }
        // A show's own row plays its Play episode; a copy's row still plays the copy.
        guard case .item(let target, "a") = VersionPicker.pick(own, playTarget: episode), target.ref == episode.ref
        else { return XCTFail() }
        guard case .item(let copied, "b") = VersionPicker.pick(other, playTarget: episode), copied.ref == copy.ref
        else { return XCTFail() }
    }

    func test_options_differentServers_leaveLibrariesOut() {
        let copy = VersionPicker.Copy(item: JellyfinFixtures.mediaItem("m2"), server: "Office",
                                      sources: [source("b")], library: "Movies")
        let options = VersionPicker.options(current: [source("a")], currentServer: "Home",
                                            currentLibrary: "Movies", copies: [copy])
        XCTAssertEqual(options.map(\.server), ["Home", "Office"])
    }
}
