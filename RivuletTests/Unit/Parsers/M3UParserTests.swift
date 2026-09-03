// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  M3UParserTests.swift
//  RivuletTests
//
//  Unit tests for M3UParser
//

import XCTest
@testable import Rivulet

final class M3UParserTests: XCTestCase {

    var parser: M3UParser!

    override func setUp() {
        super.setUp()
        parser = M3UParser()
    }

    override func tearDown() {
        parser = nil
        super.tearDown()
    }

    // MARK: - Header Validation Tests

    func testRejectsContentWithoutExtM3UHeader() async throws {
        let content = """
        #EXTINF:-1,Channel One
        http://example.com/stream1.m3u8
        """

        do {
            _ = try await parser.parse(content: content)
            XCTFail("Should throw error for missing header")
        } catch let error as M3UParseError {
            if case .invalidFormat(let message) = error {
                XCTAssertTrue(message.contains("header"), "Error message should mention header")
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }

    func testAcceptsExtM3UHeaderCaseInsensitive() async throws {
        let content = """
        #extm3u
        #EXTINF:-1,Channel One
        http://example.com/stream1.m3u8
        """

        let channels = try await parser.parse(content: content)
        XCTAssertEqual(channels.count, 1)
    }

    // MARK: - Basic Parsing Tests

    func testParsesBasicPlaylist() async throws {
        let content = """
        #EXTM3U
        #EXTINF:-1,Channel One
        http://example.com/stream1.m3u8
        #EXTINF:-1,Channel Two
        http://example.com/stream2.m3u8
        #EXTINF:-1,Channel Three
        http://example.com/stream3.m3u8
        """

        let channels = try await parser.parse(content: content)

        XCTAssertEqual(channels.count, 3)
        XCTAssertEqual(channels[0].name, "Channel One")
        XCTAssertEqual(channels[1].name, "Channel Two")
        XCTAssertEqual(channels[2].name, "Channel Three")
    }

    func testExtractsStreamURLs() async throws {
        let content = """
        #EXTM3U
        #EXTINF:-1,Test Channel
        http://example.com/live/stream.m3u8
        """

        let channels = try await parser.parse(content: content)

        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels[0].streamURL.absoluteString, "http://example.com/live/stream.m3u8")
    }

    // MARK: - Attribute Parsing Tests

    func testExtractsAllStandardAttributes() async throws {
        let content = """
        #EXTM3U
        #EXTINF:-1 tvg-id="ch1" tvg-name="Channel One HD" tvg-logo="http://example.com/logo.png" group-title="News" tvg-chno="42",Display Name
        http://example.com/stream.m3u8
        """

        let channels = try await parser.parse(content: content)

        XCTAssertEqual(channels.count, 1)
        let channel = channels[0]

        XCTAssertEqual(channel.tvgId, "ch1")
        XCTAssertEqual(channel.tvgName, "Channel One HD")
        XCTAssertEqual(channel.tvgLogo, "http://example.com/logo.png")
        XCTAssertEqual(channel.groupTitle, "News")
        XCTAssertEqual(channel.channelNumber, 42)
        XCTAssertEqual(channel.name, "Display Name")
    }

    func testHandlesDoubleQuotedAttributes() async throws {
        let content = """
        #EXTM3U
        #EXTINF:-1 tvg-id="channel-1" tvg-name="Test Channel",Test Channel
        http://example.com/stream.m3u8
        """

        let channels = try await parser.parse(content: content)

        XCTAssertEqual(channels[0].tvgId, "channel-1")
        XCTAssertEqual(channels[0].tvgName, "Test Channel")
    }

    func testHandlesSingleQuotedAttributes() async throws {
        let content = """
        #EXTM3U
        #EXTINF:-1 tvg-id='channel-1' tvg-name='Test Channel',Test Channel
        http://example.com/stream.m3u8
        """

        let channels = try await parser.parse(content: content)

        XCTAssertEqual(channels[0].tvgId, "channel-1")
        XCTAssertEqual(channels[0].tvgName, "Test Channel")
    }

    func testHandlesUnquotedAttributes() async throws {
        let content = """
        #EXTM3U
        #EXTINF:-1 tvg-id=ch1 tvg-chno=5 group-title=News,Test Channel
        http://example.com/stream.m3u8
        """

        let channels = try await parser.parse(content: content)

        XCTAssertEqual(channels[0].tvgId, "ch1")
        XCTAssertEqual(channels[0].channelNumber, 5)
        XCTAssertEqual(channels[0].groupTitle, "News")
    }

    func testHandlesMixedQuoteStyles() async throws {
        let content = """
        #EXTM3U
        #EXTINF:-1 tvg-id="ch1" tvg-name='Channel One' group-title=News,Test
        http://example.com/stream.m3u8
        """

        let channels = try await parser.parse(content: content)

        XCTAssertEqual(channels[0].tvgId, "ch1")
        XCTAssertEqual(channels[0].tvgName, "Channel One")
        XCTAssertEqual(channels[0].groupTitle, "News")
    }

    func testHandlesChannelNumberAttribute() async throws {
        let content = """
        #EXTM3U
        #EXTINF:-1 channel-number="100",Test Channel
        http://example.com/stream.m3u8
        """

        let channels = try await parser.parse(content: content)

        XCTAssertEqual(channels[0].channelNumber, 100)
    }

    // MARK: - Edge Cases

    func testHandlesUnicodeChannelNames() async throws {
        let content = """
        #EXTM3U
        #EXTINF:-1 tvg-name="France Télévisions",France Télévisions
        http://example.com/france.m3u8
        #EXTINF:-1 tvg-name="日本放送協会",NHK 日本放送協会
        http://example.com/nhk.m3u8
        #EXTINF:-1 tvg-name="Первый канал",Первый канал
        http://example.com/russia.m3u8
        """

        let channels = try await parser.parse(content: content)

        XCTAssertEqual(channels.count, 3)
        XCTAssertEqual(channels[0].name, "France Télévisions")
        XCTAssertEqual(channels[1].tvgName, "日本放送協会")
        XCTAssertEqual(channels[2].name, "Первый канал")
    }

    func testHandlesEmptyAttributeValues() async throws {
        let content = """
        #EXTM3U
        #EXTINF:-1 tvg-id="" tvg-name="Channel",Channel
        http://example.com/stream.m3u8
        """

        let channels = try await parser.parse(content: content)

        XCTAssertEqual(channels.count, 1)
        XCTAssertNil(channels[0].tvgId, "Empty tvg-id should be nil")
        XCTAssertEqual(channels[0].tvgName, "Channel")
    }

    func testSkipsLinesWithInvalidURLs() async throws {
        // Note: URL(string:) is lenient and percent-encodes many invalid characters.
        // A space AFTER the scheme (http:// ) is one of the few things that fails.
        let content = """
        #EXTM3U
        #EXTINF:-1,Valid Channel
        http://example.com/stream.m3u8
        #EXTINF:-1,Invalid Channel
        http://invalid host.com/stream
        #EXTINF:-1,Another Valid
        http://example.com/stream2.m3u8
        """

        let channels = try await parser.parse(content: content)

        XCTAssertEqual(channels.count, 2)
        XCTAssertEqual(channels[0].name, "Valid Channel")
        XCTAssertEqual(channels[1].name, "Another Valid")
    }

    func testSkipsChannelsWithEmptyName() async throws {
        let content = """
        #EXTM3U
        #EXTINF:-1,
        http://example.com/stream1.m3u8
        #EXTINF:-1,Valid Channel
        http://example.com/stream2.m3u8
        """

        let channels = try await parser.parse(content: content)

        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels[0].name, "Valid Channel")
    }

    func testHandlesWindowsLineEndings() async throws {
        let content = "#EXTM3U\r\n#EXTINF:-1,Channel One\r\nhttp://example.com/stream1.m3u8\r\n#EXTINF:-1,Channel Two\r\nhttp://example.com/stream2.m3u8\r\n"

        let channels = try await parser.parse(content: content)

        XCTAssertEqual(channels.count, 2)
    }

    func testSkipsOtherDirectives() async throws {
        let content = """
        #EXTM3U
        #EXTVLCOPT:network-caching=1000
        #EXTINF:-1,Channel One
        http://example.com/stream.m3u8
        #EXTGRP:News
        #EXTINF:-1,Channel Two
        http://example.com/stream2.m3u8
        """

        let channels = try await parser.parse(content: content)

        XCTAssertEqual(channels.count, 2)
    }

    // MARK: - HD Detection Tests

    func testIsHDDetectsHDInName() async throws {
        let content = """
        #EXTM3U
        #EXTINF:-1,ESPN HD
        http://example.com/espn.m3u8
        """

        let channels = try await parser.parse(content: content)

        XCTAssertTrue(channels[0].isHD)
    }

    func testIsHDDetects1080() async throws {
        let content = """
        #EXTM3U
        #EXTINF:-1,Channel 1080p
        http://example.com/stream.m3u8
        """

        let channels = try await parser.parse(content: content)

        XCTAssertTrue(channels[0].isHD)
    }

    func testIsHDDetects720() async throws {
        let content = """
        #EXTM3U
        #EXTINF:-1,Channel 720
        http://example.com/stream.m3u8
        """

        let channels = try await parser.parse(content: content)

        XCTAssertTrue(channels[0].isHD)
    }

    func testIsHDReturnsFalseForSDChannels() async throws {
        let content = """
        #EXTM3U
        #EXTINF:-1,Standard Definition Channel
        http://example.com/stream.m3u8
        """

        let channels = try await parser.parse(content: content)

        XCTAssertFalse(channels[0].isHD)
    }

    func testIsHDDetectsHDSuffix() async throws {
        let content = """
        #EXTM3U
        #EXTINF:-1,ESPNHD
        http://example.com/stream.m3u8
        """

        let channels = try await parser.parse(content: content)

        XCTAssertTrue(channels[0].isHD)
    }

    // MARK: - Data Parsing Tests

    func testParsesFromData() async throws {
        let content = """
        #EXTM3U
        #EXTINF:-1,Test Channel
        http://example.com/stream.m3u8
        """
        let data = content.data(using: .utf8)!

        let channels = try await parser.parse(data: data)

        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels[0].name, "Test Channel")
    }

    func testThrowsForInvalidEncoding() async throws {
        // Create data that can't be decoded as UTF-8
        let invalidData = Data([0xFF, 0xFE, 0x00, 0x01])

        do {
            _ = try await parser.parse(data: invalidData)
            XCTFail("Should throw error for invalid encoding")
        } catch let error as M3UParseError {
            if case .invalidEncoding = error {
                // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }

    // MARK: - Pipe-delimited headers

    func testParsesStreamURLWithUserAgentPipe() async throws {
        let content = """
        #EXTM3U
        #EXTINF:-1,Test Channel
        http://example.com/live/stream.m3u8|User-Agent=CustomPlayer/1.0
        """

        let channels = try await parser.parse(content: content)

        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels[0].streamURL.absoluteString, "http://example.com/live/stream.m3u8")
        XCTAssertEqual(channels[0].httpHeaders["User-Agent"], "CustomPlayer/1.0")
    }

    func testParsesStreamURLWithMultiplePipeHeaders() async throws {
        let content = """
        #EXTM3U
        #EXTINF:-1,Test Channel
        http://example.com/live/stream.m3u8|user-agent=Custom%20Player%202.0&Referer=http://foo.bar
        """

        let channels = try await parser.parse(content: content)

        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels[0].streamURL.absoluteString, "http://example.com/live/stream.m3u8")
        XCTAssertEqual(channels[0].httpHeaders["User-Agent"], "Custom Player 2.0")
        XCTAssertEqual(channels[0].httpHeaders["Referer"], "http://foo.bar")
    }
}
