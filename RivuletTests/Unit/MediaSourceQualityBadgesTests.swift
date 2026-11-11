// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaSourceQualityBadgesTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class MediaSourceQualityBadgesTests: XCTestCase {

    func test_4kDolbyVision_eac3_5_1() {
        let video = VideoTrack(
            id: "v1", codec: "hevc", profile: "Main 10", level: 153,
            width: 3840, height: 2160, frameRate: 24,
            bitrate: 50_000_000,
            videoRange: .dolbyVision(profile: 7),
            isDefault: true, scanType: "progressive"
        )
        let audio = AudioTrack(
            id: "a1", index: 0, codec: "eac3", profile: nil,
            channels: 6, channelLayout: "5.1",
            language: "en", title: nil, extendedTitle: nil,
            bitrate: 640_000, samplingRate: 48_000,
            isDefault: true, isForced: false, isSelected: true
        )
        let source = MediaSource(
            id: "1", container: "mkv", duration: 7200,
            bitrate: 50_000_000, fileSize: nil, fileName: nil,
            videoResolution: "4k",
            videoTracks: [video], audioTracks: [audio], subtitleTracks: [],
            streamKind: .directPlay, streamURL: nil
        )
        let badges = source.qualityBadges()
        XCTAssertTrue(badges.contains("4K"))
        XCTAssertTrue(badges.contains("DV"))
        XCTAssertTrue(badges.contains("E-AC3 5.1"))
    }

    func test_1080pHDR10_stereoAudio() {
        let video = VideoTrack(
            id: "v1", codec: "hevc", profile: "Main 10", level: nil,
            width: 1920, height: 1080, frameRate: 24,
            bitrate: nil, videoRange: .hdr10, isDefault: true, scanType: "progressive"
        )
        let audio = AudioTrack(
            id: "a1", index: 0, codec: "aac", profile: nil,
            channels: 2, channelLayout: "stereo",
            language: "en", title: nil, extendedTitle: nil,
            bitrate: 192_000, samplingRate: 48_000,
            isDefault: true, isForced: false, isSelected: true
        )
        let source = MediaSource(
            id: "1", container: "mp4", duration: 7200,
            bitrate: nil, fileSize: nil, fileName: nil,
            videoResolution: "1080",
            videoTracks: [video], audioTracks: [audio], subtitleTracks: [],
            streamKind: .directPlay, streamURL: nil
        )
        let badges = source.qualityBadges()
        XCTAssertTrue(badges.contains("1080p"))
        XCTAssertTrue(badges.contains("HDR"))
        XCTAssertTrue(badges.contains("AAC 2.0"))
        XCTAssertFalse(badges.contains("4K"))
        XCTAssertFalse(badges.contains("DV"))
    }

    func test_truehdAtmos_7_1() {
        let video = VideoTrack(
            id: "v1", codec: "hevc", profile: nil, level: nil,
            width: 3840, height: 2160, frameRate: 24,
            bitrate: nil, videoRange: .dolbyVision(profile: 8),
            isDefault: true, scanType: "progressive"
        )
        let audio = AudioTrack(
            id: "a1", index: 0, codec: "truehd", profile: "dolby truehd + dolby atmos",
            channels: 8, channelLayout: "7.1",
            language: "en", title: nil, extendedTitle: nil,
            bitrate: nil, samplingRate: 48_000,
            isDefault: true, isForced: false, isSelected: true
        )
        let source = MediaSource(
            id: "1", container: "mkv", duration: 7200,
            bitrate: nil, fileSize: nil, fileName: nil,
            videoResolution: "4k",
            videoTracks: [video], audioTracks: [audio], subtitleTracks: [],
            streamKind: .directPlay, streamURL: nil
        )
        XCTAssertTrue(source.qualityBadges().contains("TrueHD 7.1 Atmos"))
    }

    func test_dtsHdMa_distinctFromDts() {
        let video = VideoTrack(
            id: "v1", codec: "hevc", profile: nil, level: nil,
            width: 1920, height: 1080, frameRate: 24,
            bitrate: nil, videoRange: .sdr, isDefault: true, scanType: "progressive"
        )
        let audio = AudioTrack(
            id: "a1", index: 0, codec: "dca", profile: "ma",
            channels: 8, channelLayout: "7.1",
            language: "en", title: nil, extendedTitle: nil,
            bitrate: nil, samplingRate: 48_000,
            isDefault: true, isForced: false, isSelected: true
        )
        let source = MediaSource(
            id: "1", container: "mkv", duration: 7200,
            bitrate: nil, fileSize: nil, fileName: nil,
            videoResolution: "1080",
            videoTracks: [video], audioTracks: [audio], subtitleTracks: [],
            streamKind: .directPlay, streamURL: nil
        )
        let badges = source.qualityBadges()
        XCTAssertTrue(badges.contains("DTS-HD MA 7.1"))
        XCTAssertFalse(badges.contains("DTS 7.1"))
    }

    func test_480i_interlacedSuffix() {
        let video = VideoTrack(
            id: "v1", codec: "mpeg2video", profile: nil, level: nil,
            width: 720, height: 480, frameRate: 29.97,
            bitrate: nil, videoRange: .sdr, isDefault: true, scanType: "interlaced"
        )
        let source = MediaSource(
            id: "1", container: "mpeg", duration: 3600,
            bitrate: nil, fileSize: nil, fileName: nil,
            videoResolution: "480",
            videoTracks: [video], audioTracks: [], subtitleTracks: [],
            streamKind: .directPlay, streamURL: nil
        )
        XCTAssertTrue(source.qualityBadges().contains("480i"))
    }

    func test_720_neverInterlaced() {
        let video = VideoTrack(
            id: "v1", codec: "h264", profile: nil, level: nil,
            width: 1280, height: 720, frameRate: 59.94,
            bitrate: nil, videoRange: .sdr, isDefault: true, scanType: "interlaced"
        )
        let source = MediaSource(
            id: "1", container: "ts", duration: 3600,
            bitrate: nil, fileSize: nil, fileName: nil,
            videoResolution: "720",
            videoTracks: [video], audioTracks: [], subtitleTracks: [],
            streamKind: .directPlay, streamURL: nil
        )
        XCTAssertTrue(source.qualityBadges().contains("720p"))
        XCTAssertFalse(source.qualityBadges().contains("720i"))
    }

    func test_sdr_noHDRBadge() {
        let video = VideoTrack(
            id: "v1", codec: "h264", profile: nil, level: nil,
            width: 1280, height: 720, frameRate: 24,
            bitrate: nil, videoRange: .sdr, isDefault: true, scanType: "progressive"
        )
        let source = MediaSource(
            id: "1", container: "mp4", duration: 7200,
            bitrate: nil, fileSize: nil, fileName: nil,
            videoResolution: "720",
            videoTracks: [video], audioTracks: [], subtitleTracks: [],
            streamKind: .directPlay, streamURL: nil
        )
        let badges = source.qualityBadges()
        XCTAssertFalse(badges.contains("HDR"))
        XCTAssertFalse(badges.contains("DV"))
    }

    func test_emptyTracks_returnsEmpty() {
        let source = MediaSource(
            id: "1", container: nil, duration: 0,
            bitrate: nil, fileSize: nil, fileName: nil,
            videoResolution: nil,
            videoTracks: [], audioTracks: [], subtitleTracks: [],
            streamKind: .directPlay, streamURL: nil
        )
        XCTAssertTrue(source.qualityBadges().isEmpty)
    }

    private func source(range: VideoTrack.VideoRange, hdr10Plus: Bool) -> MediaSource {
        let video = VideoTrack(
            id: "v1", codec: "hevc", profile: "Main 10", level: nil,
            width: 3840, height: 2160, frameRate: 24, bitrate: nil,
            videoRange: range, isDefault: true, scanType: "progressive", hasHDR10Plus: hdr10Plus
        )
        return MediaSource(
            id: "1", container: "mkv", duration: 7200,
            bitrate: nil, fileSize: nil, fileName: nil, videoResolution: "4k",
            videoTracks: [video], audioTracks: [], subtitleTracks: [],
            streamKind: .directPlay, streamURL: nil
        )
    }

    func test_dolbyVisionWithHDR10Plus_showsBoth() {
        XCTAssertEqual(source(range: .dolbyVision(profile: 8), hdr10Plus: true).qualityBadges(), ["4K", "DV", "HDR10+"])
    }

    func test_hdr10Plus_isNamed() {
        XCTAssertEqual(source(range: .hdr10Plus, hdr10Plus: true).qualityBadges(), ["4K", "HDR10+"])
    }

    func test_dolbyVisionWithoutHDR10Plus_showsDVOnly() {
        XCTAssertEqual(source(range: .dolbyVision(profile: 8), hdr10Plus: false).qualityBadges(), ["4K", "DV"])
    }

    func test_detailBadges_keepRangeAndDropPlainCodecs() {
        XCTAssertEqual(source(range: .dolbyVision(profile: 8), hdr10Plus: true).detailBadges, ["4K", "DV", "HDR10+"])
    }

    /// CC, SDH and AD follow the picture and sound badges, as in the Apple TV app's row.
    func test_detailBadges_accessibilityLast() {
        func sub(_ codec: String, sdh: Bool) -> SubtitleTrack {
            SubtitleTrack(id: codec, index: 0, codec: codec, language: "en", title: nil, extendedTitle: nil,
                          isDefault: false, isForced: false, isHearingImpaired: sdh, isEmbedded: true,
                          externalURL: nil, isSelected: false)
        }
        let described = AudioTrack(
            id: "a2", index: 1, codec: "aac", profile: nil, channels: 2, channelLayout: "stereo",
            language: "en", title: "English Descriptive Audio", extendedTitle: nil,
            bitrate: nil, samplingRate: 48_000, isDefault: false, isForced: false, isSelected: false
        )
        let base = source(range: .hdr10, hdr10Plus: false)
        let full = MediaSource(
            id: base.id, container: base.container, duration: base.duration, bitrate: nil, fileSize: nil,
            fileName: nil, videoResolution: base.videoResolution, videoTracks: base.videoTracks,
            audioTracks: [described], subtitleTracks: [sub("eia_608", sdh: false), sub("srt", sdh: true)],
            streamKind: .directPlay, streamURL: nil
        )
        XCTAssertEqual(full.detailBadges, ["4K", "HDR", "CC", "SDH", "AD"])
    }

    /// 720p and 1080p read "HD"; below that gets no definition badge, as in the Apple TV app.
    func test_detailBadges_hdOnly() {
        func source(height: Int, label: String?) -> MediaSource {
            let video = VideoTrack(
                id: "v1", codec: "h264", profile: nil, level: nil,
                width: nil, height: height, frameRate: 24,
                bitrate: nil, videoRange: .sdr, isDefault: true, scanType: "progressive"
            )
            return MediaSource(
                id: "1", container: "mkv", duration: 7200,
                bitrate: nil, fileSize: nil, fileName: nil, videoResolution: label,
                videoTracks: [video], audioTracks: [], subtitleTracks: [],
                streamKind: .directPlay, streamURL: nil
            )
        }
        XCTAssertEqual(source(height: 1080, label: "1080").detailBadges, ["HD"])
        // Emby and Jellyfin send no label: the pixel height decides.
        XCTAssertEqual(source(height: 800, label: nil).detailBadges, ["HD"])
        XCTAssertEqual(source(height: 720, label: "720").detailBadges, ["HD"])
        XCTAssertEqual(source(height: 576, label: "576").detailBadges, [])
        XCTAssertEqual(source(height: 480, label: "sd").detailBadges, [])
    }
}
