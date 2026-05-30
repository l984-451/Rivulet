//
//  MediaSourceQualityBadgesTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class MediaSourceQualityBadgesTests: XCTestCase {

    func test_4kDolbyVision_5_1Audio() {
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
            bitrate: nil, videoRange: .hdr10, isDefault: true,
            scanType: "progressive"
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
        XCTAssertFalse(badges.contains("4K"))
        XCTAssertFalse(badges.contains("DV"))
        // Stereo is now shown (as "2.0"), unlike the pre-954f81a scheme.
        XCTAssertTrue(badges.contains("AAC 2.0"))
    }

    func test_truehdAtmos_appendsAtmos() {
        let video = VideoTrack(
            id: "v1", codec: "hevc", profile: "Main 10", level: nil,
            width: 3840, height: 2160, frameRate: 24,
            bitrate: nil, videoRange: .dolbyVision(profile: 7),
            isDefault: true, scanType: "progressive"
        )
        let audio = AudioTrack(
            id: "a1", index: 0, codec: "truehd",
            profile: "dolby truehd + dolby atmos",
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
            bitrate: nil, videoRange: .sdr, isDefault: true,
            scanType: "progressive"
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

    func test_sdr_noHDRBadges() {
        let video = VideoTrack(
            id: "v1", codec: "h264", profile: nil, level: nil,
            width: 1280, height: 720, frameRate: 24,
            bitrate: nil, videoRange: .sdr, isDefault: true,
            scanType: "progressive"
        )
        let source = MediaSource(
            id: "1", container: "mp4", duration: 7200,
            bitrate: nil, fileSize: nil, fileName: nil,
            videoResolution: "720",
            videoTracks: [video], audioTracks: [], subtitleTracks: [],
            streamKind: .directPlay, streamURL: nil
        )
        let badges = source.qualityBadges()
        XCTAssertTrue(badges.contains("720p"))
        XCTAssertFalse(badges.contains("4K"))
        XCTAssertFalse(badges.contains("HDR"))
        XCTAssertFalse(badges.contains("DV"))
    }

    // MARK: - Interlaced scan-type labelling

    func test_1080i_interlacedSuffix() {
        let video = VideoTrack(
            id: "v1", codec: "mpeg2video", profile: nil, level: nil,
            width: 1920, height: 1080, frameRate: 29.97,
            bitrate: nil, videoRange: .sdr, isDefault: true,
            scanType: "interlaced"
        )
        let source = MediaSource(
            id: "1", container: "ts", duration: 3600,
            bitrate: nil, fileSize: nil, fileName: nil,
            videoResolution: "1080",
            videoTracks: [video], audioTracks: [], subtitleTracks: [],
            streamKind: .directPlay, streamURL: nil
        )
        let badges = source.qualityBadges()
        XCTAssertTrue(badges.contains("1080i"))
        XCTAssertFalse(badges.contains("1080p"))
    }

    func test_480i_interlacedSuffix() {
        let video = VideoTrack(
            id: "v1", codec: "mpeg2video", profile: nil, level: nil,
            width: 720, height: 480, frameRate: 29.97,
            bitrate: nil, videoRange: .sdr, isDefault: true,
            scanType: "interlaced"
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

    func test_576i_interlacedSuffix() {
        let video = VideoTrack(
            id: "v1", codec: "mpeg2video", profile: nil, level: nil,
            width: 720, height: 576, frameRate: 25,
            bitrate: nil, videoRange: .sdr, isDefault: true,
            scanType: "interlaced"
        )
        let source = MediaSource(
            id: "1", container: "mpeg", duration: 3600,
            bitrate: nil, fileSize: nil, fileName: nil,
            videoResolution: "576",
            videoTracks: [video], audioTracks: [], subtitleTracks: [],
            streamKind: .directPlay, streamURL: nil
        )
        XCTAssertTrue(source.qualityBadges().contains("576i"))
    }

    func test_720_neverInterlaced() {
        // 720 has no interlaced broadcast form; stay progressive even if a
        // probe oddly reports interlaced.
        let video = VideoTrack(
            id: "v1", codec: "h264", profile: nil, level: nil,
            width: 1280, height: 720, frameRate: 59.94,
            bitrate: nil, videoRange: .sdr, isDefault: true,
            scanType: "interlaced"
        )
        let source = MediaSource(
            id: "1", container: "ts", duration: 3600,
            bitrate: nil, fileSize: nil, fileName: nil,
            videoResolution: "720",
            videoTracks: [video], audioTracks: [], subtitleTracks: [],
            streamKind: .directPlay, streamURL: nil
        )
        let badges = source.qualityBadges()
        XCTAssertTrue(badges.contains("720p"))
        XCTAssertFalse(badges.contains("720i"))
    }

    func test_4k_neverInterlaced() {
        let video = VideoTrack(
            id: "v1", codec: "hevc", profile: "Main 10", level: nil,
            width: 3840, height: 2160, frameRate: 24,
            bitrate: nil, videoRange: .sdr, isDefault: true,
            scanType: "interlaced"
        )
        let source = MediaSource(
            id: "1", container: "mkv", duration: 3600,
            bitrate: nil, fileSize: nil, fileName: nil,
            videoResolution: "4k",
            videoTracks: [video], audioTracks: [], subtitleTracks: [],
            streamKind: .directPlay, streamURL: nil
        )
        XCTAssertTrue(source.qualityBadges().contains("4K"))
    }

    func test_nilScanType_assumesProgressive() {
        let video = VideoTrack(
            id: "v1", codec: "h264", profile: nil, level: nil,
            width: 1920, height: 1080, frameRate: 24,
            bitrate: nil, videoRange: .sdr, isDefault: true,
            scanType: nil
        )
        let source = MediaSource(
            id: "1", container: "mp4", duration: 3600,
            bitrate: nil, fileSize: nil, fileName: nil,
            videoResolution: "1080",
            videoTracks: [video], audioTracks: [], subtitleTracks: [],
            streamKind: .directPlay, streamURL: nil
        )
        let badges = source.qualityBadges()
        XCTAssertTrue(badges.contains("1080p"))
        XCTAssertFalse(badges.contains("1080i"))
    }

    func test_interlacedHeightFallback_whenNoProviderLabel() {
        // No provider videoResolution → height fallback path must also suffix.
        let video = VideoTrack(
            id: "v1", codec: "mpeg2video", profile: nil, level: nil,
            width: 1920, height: 1080, frameRate: 25,
            bitrate: nil, videoRange: .sdr, isDefault: true,
            scanType: "interlaced"
        )
        let source = MediaSource(
            id: "1", container: "ts", duration: 3600,
            bitrate: nil, fileSize: nil, fileName: nil,
            videoResolution: nil,
            videoTracks: [video], audioTracks: [], subtitleTracks: [],
            streamKind: .directPlay, streamURL: nil
        )
        XCTAssertTrue(source.qualityBadges().contains("1080i"))
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
}
