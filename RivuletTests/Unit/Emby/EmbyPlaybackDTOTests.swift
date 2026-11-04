// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyPlaybackDTOTests.swift
//  RivuletTests
//
//  The media source and stream DTOs decode every captured PlaybackInfo shape.
//

import XCTest
@testable import Rivulet

@MainActor
final class EmbyPlaybackDTOTests: XCTestCase {
    private func response(_ json: String) throws -> EmbyPlaybackInfoResponse { try EmbyTestJSON.decode(json) }

    func test_directPlay_decodesSourceAndUrls() throws {
        let info = try response(EmbyPlaybackFixtures.directPlay4_10_2)
        let source = try XCTUnwrap(info.mediaSources?.first)
        XCTAssertEqual(source.id, "mediasource_857")
        XCTAssertEqual(source.supportsDirectPlay, true)
        XCTAssertTrue(source.directStreamUrl?.hasPrefix("/videos/857/") == true, "server-relative, lowercase, no /emby")
        XCTAssertNil(source.transcodingUrl)
        XCTAssertNotNil(info.playSessionId)
        XCTAssertNotNil(source.runTimeTicks)
    }

    func test_streams_embeddedIndexesComeFirstAndSidecarsFollow() throws {
        let streams = try XCTUnwrap(try response(EmbyPlaybackFixtures.directPlay4_10_2).mediaSources?.first?.mediaStreams)
        let embedded = streams.filter { $0.isExternal != true }
        let sidecars = streams.filter { $0.isExternal == true }
        XCTAssertEqual(embedded.compactMap(\.index), Array(0...8))
        XCTAssertEqual(sidecars.compactMap(\.index), [9, 10, 11, 12])
        XCTAssertTrue(sidecars.allSatisfy { $0.type == "Subtitle" && $0.isTextSubtitleStream == true })
        XCTAssertTrue(sidecars.allSatisfy { $0.deliveryUrl?.contains("/Subtitles/") == true })
        XCTAssertEqual(streams.first?.type, "Video")
    }

    func test_streams_videoAndAudioFieldsDecode() throws {
        let streams = try XCTUnwrap(try response(EmbyPlaybackFixtures.directPlay4_10_2).mediaSources?.first?.mediaStreams)
        let video = try XCTUnwrap(streams.first { $0.type == "Video" })
        XCTAssertNotNil(video.width)
        XCTAssertNotNil(video.height)
        XCTAssertNotNil(video.codec)
        XCTAssertNotNil(video.videoRange)
        XCTAssertNotNil(video.extendedVideoType)
        let audio = try XCTUnwrap(streams.first { $0.type == "Audio" })
        XCTAssertNotNil(audio.channels)
        XCTAssertNotNil(audio.codec)
        XCTAssertNotNil(audio.displayTitle)
    }

    func test_attachments_areEmbeddedImageStreamsThatKeepTheirIndex() throws {
        let streams = try XCTUnwrap(try response(EmbyPlaybackFixtures.directPlay4K4_10_2).mediaSources?.first?.mediaStreams)
        let images = streams.filter { $0.type == "EmbeddedImage" }
        XCTAssertFalse(images.isEmpty)
        XCTAssertEqual(streams.compactMap(\.index), Array(0..<streams.count), "attachments occupy indexes")
    }

    func test_forcedTranscode_carriesATranscodingUrlAndNoDirectStream() throws {
        let source = try XCTUnwrap(try response(EmbyPlaybackFixtures.forcedTranscode4_10_2).mediaSources?.first)
        XCTAssertEqual(source.supportsDirectPlay, false)
        XCTAssertTrue(source.transcodingUrl?.hasPrefix("/videos/857/master.m3u8") == true)
        XCTAssertEqual(source.transcodingSubProtocol, "hls")
        XCTAssertNil(source.directStreamUrl)
    }

    func test_noCompatibleStream_isAnEmptySourceListWithAnErrorCode() throws {
        let info = try response(EmbyPlaybackFixtures.noCompatibleStream)
        XCTAssertEqual(info.mediaSources?.count, 0)
        XCTAssertEqual(info.errorCode, "NoCompatibleStream")
        XCTAssertNil(info.playSessionId)
    }

    func test_embyFourEight_opaqueSourceIdAndNoSourceChapters() throws {
        let source = try XCTUnwrap(try response(EmbyPlaybackFixtures.directPlay4_8_11).mediaSources?.first)
        let id = try XCTUnwrap(source.id)
        XCTAssertFalse(id.hasPrefix("mediasource_"))
        XCTAssertEqual(id.count, 32)
        XCTAssertNotNil(source.mediaStreams)
    }

    func test_embyFourEight_movieDetailKeepsItemLevelChapters() throws {
        let item: EmbyItem = try EmbyTestJSON.decode(EmbyPlaybackFixtures.movieDetail4_8_11)
        XCTAssertFalse(item.chapters?.isEmpty ?? true)
        XCTAssertTrue(item.chapters?.allSatisfy { $0.markerType == "Chapter" } == true)
        XCTAssertFalse(item.mediaSources?.isEmpty ?? true)
    }
}
