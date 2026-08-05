// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  XMLTVParserTests.swift
//  RivuletTests
//
//  Unit tests for XMLTVParser
//

import XCTest
@testable import Rivulet

final class XMLTVParserTests: XCTestCase {

    var parser: XMLTVParser!

    override func setUp() {
        super.setUp()
        parser = XMLTVParser()
    }

    override func tearDown() {
        parser = nil
        super.tearDown()
    }

    // MARK: - Date Parsing Tests

    func testParsesStandardXMLTVDate() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="ch1">
            <display-name>Test Channel</display-name>
          </channel>
          <programme start="20240115120000 +0000" stop="20240115130000 +0000" channel="ch1">
            <title>Test Program</title>
          </programme>
        </tv>
        """
        let data = xml.data(using: .utf8)!

        let result = try await parser.parse(data: data)

        XCTAssertEqual(result.programs.count, 1)
        guard let programs = result.programs["ch1"], let program = programs.first else {
            XCTFail("Should have program for ch1")
            return
        }

        // Check that the date was parsed correctly (2024-01-15 12:00:00 UTC)
        let calendar = Calendar(identifier: .gregorian)
        var components = calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: program.start)

        XCTAssertEqual(components.year, 2024)
        XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 15)
        XCTAssertEqual(components.hour, 12)
        XCTAssertEqual(components.minute, 0)
        XCTAssertEqual(components.second, 0)

        // Check stop time (2024-01-15 13:00:00 UTC)
        components = calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: program.stop)
        XCTAssertEqual(components.hour, 13)
    }

    func testParsesDateWithoutTimezone() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="ch1">
            <display-name>Test Channel</display-name>
          </channel>
          <programme start="20240115120000" stop="20240115130000" channel="ch1">
            <title>Test Program</title>
          </programme>
        </tv>
        """
        let data = xml.data(using: .utf8)!

        let result = try await parser.parse(data: data)

        // Should still parse, defaulting to UTC
        guard let programs = result.programs["ch1"], let program = programs.first else {
            XCTFail("Should have program for ch1")
            return
        }

        XCTAssertNotNil(program.start)
        XCTAssertNotNil(program.stop)
    }

    func testParsesNumericTimezoneOffset() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="ch1">
            <display-name>Perth Channel</display-name>
          </channel>
          <programme start="20260802193000 +0800" stop="20260802203000 +0800" channel="ch1">
            <title>Evening News</title>
          </programme>
        </tv>
        """

        let result = try await parser.parse(data: Data(xml.utf8))
        let program = try XCTUnwrap(result.programs["ch1"]?.first)
        let utc = Calendar(identifier: .gregorian)
            .dateComponents(in: TimeZone(identifier: "UTC")!, from: program.start)

        XCTAssertEqual(utc.hour, 11)
        XCTAssertEqual(utc.minute, 30)
    }

    func testHandlesInvalidDateGracefully() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="ch1">
            <display-name>Test Channel</display-name>
          </channel>
          <programme start="invalid" stop="20240115130000 +0000" channel="ch1">
            <title>Test Program</title>
          </programme>
          <programme start="20240115140000 +0000" stop="20240115150000 +0000" channel="ch1">
            <title>Valid Program</title>
          </programme>
        </tv>
        """
        let data = xml.data(using: .utf8)!

        let result = try await parser.parse(data: data)

        // Should skip program with invalid date
        guard let programs = result.programs["ch1"] else {
            XCTFail("Should have programs for ch1")
            return
        }

        XCTAssertEqual(programs.count, 1)
        XCTAssertEqual(programs[0].title, "Valid Program")
    }

    // MARK: - Channel Parsing Tests

    func testExtractsChannelId() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="test-channel-id">
            <display-name>Test Channel</display-name>
          </channel>
        </tv>
        """
        let data = xml.data(using: .utf8)!

        let result = try await parser.parse(data: data)

        XCTAssertNotNil(result.channels["test-channel-id"])
        XCTAssertEqual(result.channels["test-channel-id"]?.id, "test-channel-id")
    }

    func testExtractsDisplayName() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="ch1">
            <display-name>My Test Channel</display-name>
          </channel>
        </tv>
        """
        let data = xml.data(using: .utf8)!

        let result = try await parser.parse(data: data)

        XCTAssertEqual(result.channels["ch1"]?.displayName, "My Test Channel")
    }

    func testExtractsIconURL() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="ch1">
            <display-name>Test Channel</display-name>
            <icon src="http://example.com/logo.png"/>
          </channel>
        </tv>
        """
        let data = xml.data(using: .utf8)!

        let result = try await parser.parse(data: data)

        XCTAssertEqual(result.channels["ch1"]?.iconURL, "http://example.com/logo.png")
    }

    func testSkipsChannelWithoutDisplayName() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="ch1">
          </channel>
          <channel id="ch2">
            <display-name>Valid Channel</display-name>
          </channel>
        </tv>
        """
        let data = xml.data(using: .utf8)!

        let result = try await parser.parse(data: data)

        XCTAssertNil(result.channels["ch1"])
        XCTAssertNotNil(result.channels["ch2"])
    }

    // MARK: - Program Parsing Tests

    func testExtractsProgramTimes() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="ch1">
            <display-name>Test</display-name>
          </channel>
          <programme start="20240115120000 +0000" stop="20240115130000 +0000" channel="ch1">
            <title>Test</title>
          </programme>
        </tv>
        """
        let data = xml.data(using: .utf8)!

        let result = try await parser.parse(data: data)
        let program = result.programs["ch1"]?.first

        XCTAssertNotNil(program?.start)
        XCTAssertNotNil(program?.stop)
        XCTAssertTrue(program!.stop > program!.start)
    }

    func testExtractsTitle() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="ch1">
            <display-name>Test</display-name>
          </channel>
          <programme start="20240115120000 +0000" stop="20240115130000 +0000" channel="ch1">
            <title>Morning News</title>
          </programme>
        </tv>
        """
        let data = xml.data(using: .utf8)!

        let result = try await parser.parse(data: data)

        XCTAssertEqual(result.programs["ch1"]?.first?.title, "Morning News")
    }

    func testExtractsSubtitle() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="ch1">
            <display-name>Test</display-name>
          </channel>
          <programme start="20240115120000 +0000" stop="20240115130000 +0000" channel="ch1">
            <title>Show Name</title>
            <sub-title>Episode Title</sub-title>
          </programme>
        </tv>
        """
        let data = xml.data(using: .utf8)!

        let result = try await parser.parse(data: data)

        XCTAssertEqual(result.programs["ch1"]?.first?.subtitle, "Episode Title")
    }

    func testExtractsDescription() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="ch1">
            <display-name>Test</display-name>
          </channel>
          <programme start="20240115120000 +0000" stop="20240115130000 +0000" channel="ch1">
            <title>Show</title>
            <desc>This is the description of the show.</desc>
          </programme>
        </tv>
        """
        let data = xml.data(using: .utf8)!

        let result = try await parser.parse(data: data)

        XCTAssertEqual(result.programs["ch1"]?.first?.description, "This is the description of the show.")
    }

    func testConcatenatesMultipleCategories() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="ch1">
            <display-name>Test</display-name>
          </channel>
          <programme start="20240115120000 +0000" stop="20240115130000 +0000" channel="ch1">
            <title>Show</title>
            <category>Sports</category>
            <category>News</category>
          </programme>
        </tv>
        """
        let data = xml.data(using: .utf8)!

        let result = try await parser.parse(data: data)

        let category = result.programs["ch1"]?.first?.category
        XCTAssertNotNil(category)
        XCTAssertTrue(category!.contains("Sports"))
        XCTAssertTrue(category!.contains("News"))
    }

    func testDetectsNewFlag() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="ch1">
            <display-name>Test</display-name>
          </channel>
          <programme start="20240115120000 +0000" stop="20240115130000 +0000" channel="ch1">
            <title>New Episode</title>
            <new/>
          </programme>
          <programme start="20240115130000 +0000" stop="20240115140000 +0000" channel="ch1">
            <title>Rerun</title>
          </programme>
        </tv>
        """
        let data = xml.data(using: .utf8)!

        let result = try await parser.parse(data: data)
        let programs = result.programs["ch1"]!

        XCTAssertTrue(programs[0].isNew)
        XCTAssertFalse(programs[1].isNew)
    }

    func testExtractsEpisodeNumber() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="ch1">
            <display-name>Test</display-name>
          </channel>
          <programme start="20240115120000 +0000" stop="20240115130000 +0000" channel="ch1">
            <title>Show</title>
            <episode-num system="onscreen">S01E05</episode-num>
          </programme>
        </tv>
        """
        let data = xml.data(using: .utf8)!

        let result = try await parser.parse(data: data)

        XCTAssertEqual(result.programs["ch1"]?.first?.episodeNum, "S01E05")
    }

    func testExtractsProgramIcon() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="ch1">
            <display-name>Test</display-name>
          </channel>
          <programme start="20240115120000 +0000" stop="20240115130000 +0000" channel="ch1">
            <title>Show</title>
            <icon src="http://example.com/program.jpg"/>
          </programme>
        </tv>
        """
        let data = xml.data(using: .utf8)!

        let result = try await parser.parse(data: data)

        XCTAssertEqual(result.programs["ch1"]?.first?.icon, "http://example.com/program.jpg")
    }

    // MARK: - Text Accumulation Tests

    func testAccumulatesTextCorrectly() async throws {
        // XML parsers may split text across multiple foundCharacters calls
        // This tests that the parser handles that correctly
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="ch1">
            <display-name>Test Channel</display-name>
          </channel>
          <programme start="20240115120000 +0000" stop="20240115130000 +0000" channel="ch1">
            <title>Show Title</title>
            <desc>This is a longer description that might be split across multiple parser callbacks. It contains enough text to test the accumulation behavior.</desc>
          </programme>
        </tv>
        """
        let data = xml.data(using: .utf8)!

        let result = try await parser.parse(data: data)
        let desc = result.programs["ch1"]?.first?.description

        XCTAssertNotNil(desc)
        XCTAssertTrue(desc!.contains("longer description"))
        XCTAssertTrue(desc!.contains("accumulation behavior"))
    }

    // MARK: - Program Filtering Tests

    func testGetProgramsFiltersToTimeRange() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="ch1">
            <display-name>Test</display-name>
          </channel>
          <programme start="20240115100000 +0000" stop="20240115110000 +0000" channel="ch1">
            <title>Before Range</title>
          </programme>
          <programme start="20240115120000 +0000" stop="20240115130000 +0000" channel="ch1">
            <title>In Range</title>
          </programme>
          <programme start="20240115140000 +0000" stop="20240115150000 +0000" channel="ch1">
            <title>After Range</title>
          </programme>
        </tv>
        """
        let data = xml.data(using: .utf8)!

        let result = try await parser.parse(data: data)

        // Create date range: 11:30 to 13:30 UTC on 2024-01-15
        var startComponents = DateComponents()
        startComponents.year = 2024
        startComponents.month = 1
        startComponents.day = 15
        startComponents.hour = 11
        startComponents.minute = 30
        startComponents.timeZone = TimeZone(identifier: "UTC")

        var endComponents = startComponents
        endComponents.hour = 13
        endComponents.minute = 30

        let calendar = Calendar(identifier: .gregorian)
        let startDate = calendar.date(from: startComponents)!
        let endDate = calendar.date(from: endComponents)!

        let filtered = await parser.getPrograms(from: result, channelId: "ch1", startDate: startDate, endDate: endDate)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].title, "In Range")
    }

    func testGetProgramsIncludesOverlappingPrograms() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="ch1">
            <display-name>Test</display-name>
          </channel>
          <programme start="20240115110000 +0000" stop="20240115123000 +0000" channel="ch1">
            <title>Overlaps Start</title>
          </programme>
          <programme start="20240115123000 +0000" stop="20240115140000 +0000" channel="ch1">
            <title>Overlaps End</title>
          </programme>
        </tv>
        """
        let data = xml.data(using: .utf8)!

        let result = try await parser.parse(data: data)

        // Query range: 12:00 to 13:00
        var startComponents = DateComponents()
        startComponents.year = 2024
        startComponents.month = 1
        startComponents.day = 15
        startComponents.hour = 12
        startComponents.minute = 0
        startComponents.timeZone = TimeZone(identifier: "UTC")

        var endComponents = startComponents
        endComponents.hour = 13

        let calendar = Calendar(identifier: .gregorian)
        let startDate = calendar.date(from: startComponents)!
        let endDate = calendar.date(from: endComponents)!

        let filtered = await parser.getPrograms(from: result, channelId: "ch1", startDate: startDate, endDate: endDate)

        // Both programs overlap with the range
        XCTAssertEqual(filtered.count, 2)
    }

    func testGetProgramsReturnsEmptyForUnknownChannel() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="ch1">
            <display-name>Test</display-name>
          </channel>
        </tv>
        """
        let data = xml.data(using: .utf8)!

        let result = try await parser.parse(data: data)
        let filtered = await parser.getPrograms(from: result, channelId: "unknown", startDate: Date(), endDate: Date().addingTimeInterval(3600))

        XCTAssertTrue(filtered.isEmpty)
    }

    // MARK: - Error Handling Tests

    func testHandlesMalformedXML() async throws {
        let xml = "not valid xml"
        let data = xml.data(using: .utf8)!

        do {
            _ = try await parser.parse(data: data)
            XCTFail("Should throw error for malformed XML")
        } catch {
            // Expected
        }
    }

    func testSkipsProgramsWithoutTitle() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="ch1">
            <display-name>Test</display-name>
          </channel>
          <programme start="20240115120000 +0000" stop="20240115130000 +0000" channel="ch1">
          </programme>
          <programme start="20240115130000 +0000" stop="20240115140000 +0000" channel="ch1">
            <title>Valid Program</title>
          </programme>
        </tv>
        """
        let data = xml.data(using: .utf8)!

        let result = try await parser.parse(data: data)
        let programs = result.programs["ch1"]

        XCTAssertEqual(programs?.count, 1)
        XCTAssertEqual(programs?.first?.title, "Valid Program")
    }
}
