// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  DispatcharrDVRTests.swift
//  RivuletTests
//
//  The pure pieces of Dispatcharr recording: how the key is sent, reading the
//  DVR's recordings, tying a playlist channel to the API's channel, and the
//  ids Rivulet gives rules the server keeps no id for.
//

import XCTest
@testable import Rivulet

final class DispatcharrDVRTests: XCTestCase {

    // MARK: - Authorization

    func test_authorizationHeader_apiKey_usesXAPIKey() {
        let header = DispatcharrService.authorizationHeader(for: "  abc123def  ")
        XCTAssertEqual(header?.field, "X-API-Key")
        XCTAssertEqual(header?.value, "abc123def")
    }

    func test_authorizationHeader_jwt_usesBearer() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyX2lkIjoxfQ.c2lnbmF0dXJl"
        let header = DispatcharrService.authorizationHeader(for: jwt)
        XCTAssertEqual(header?.field, "Authorization")
        XCTAssertEqual(header?.value, "Bearer \(jwt)")
    }

    func test_authorizationHeader_blank_isNil() {
        XCTAssertNil(DispatcharrService.authorizationHeader(for: "   "))
    }

    // MARK: - Recordings

    func test_recording_decodes_programTimes_andIgnoresOddProperties() throws {
        let json = """
        [{
          "id": 7,
          "channel": 12,
          "start_time": "2026-07-09T13:58:00Z",
          "end_time": "2026-07-09T15:05:00.123456+00:00",
          "task_id": null,
          "custom_properties": {
            "status": "scheduled",
            "poster_logo_id": "not a number",
            "program": {
              "title": "Evening News",
              "sub_title": "Tuesday",
              "start_time": "2026-07-09T14:00:00+00:00",
              "end_time": "2026-07-09T15:00:00+00:00",
              "tvg_id": "news.us",
              "epg_source_id": "3"
            }
          }
        }]
        """
        let recordings = try JSONDecoder().decode([DispatcharrRecording].self, from: Data(json.utf8))
        XCTAssertEqual(recordings.count, 1)
        let recording = try XCTUnwrap(recordings.first)
        XCTAssertEqual(recording.id, 7)
        XCTAssertEqual(recording.channel, 12)
        XCTAssertEqual(recording.properties.status, "scheduled")
        XCTAssertNil(recording.properties.posterLogoId)
        XCTAssertEqual(recording.properties.program?.title, "Evening News")
        XCTAssertEqual(recording.properties.program?.epgSourceId, 3)
        XCTAssertEqual(DispatcharrDates.parse(recording.properties.program?.startTime),
                       DispatcharrDates.parse("2026-07-09T14:00:00Z"))
        XCTAssertNotNil(DispatcharrDates.parse("2026-07-09T15:05:00.123456+00:00"))
    }

    func test_recording_withoutCustomProperties_stillDecodes() throws {
        let json = """
        {"id": 1, "channel": 2, "start_time": "2026-07-09T14:00:00Z",
         "end_time": "2026-07-09T15:00:00Z", "custom_properties": null}
        """
        let recording = try JSONDecoder().decode(DispatcharrRecording.self, from: Data(json.utf8))
        XCTAssertNil(recording.properties.program)
        XCTAssertNil(recording.properties.status)
    }

    // MARK: - Channel matching

    func test_streamUUID_readsProxyURL() {
        let url = URL(string: "http://host:9191/proxy/ts/stream/0F8FAD5B-D9CB-469F-A165-70867728950E")
        XCTAssertEqual(DispatcharrChannelIndex.streamUUID(url), "0f8fad5b-d9cb-469f-a165-70867728950e")
        XCTAssertNil(DispatcharrChannelIndex.streamUUID(URL(string: "http://provider/live/u/p/1.ts")))
    }

    func test_index_matchesByUUID_thenNumber_thenName() throws {
        let json = """
        [{"id": 1, "uuid": "0f8fad5b-d9cb-469f-a165-70867728950e", "name": "News", "channel_number": 5, "epg_data_id": 9},
         {"id": 2, "uuid": "7c9e6679-7425-40de-944b-e07fc1f90ae7", "name": "Sports", "channel_number": 6.1, "epg_data_id": null}]
        """
        let index = DispatcharrChannelIndex(try JSONDecoder().decode([DispatcharrChannelSummary].self,
                                                                     from: Data(json.utf8)))
        let proxied = URL(string: "http://host/proxy/ts/stream/7c9e6679-7425-40de-944b-e07fc1f90ae7")
        XCTAssertEqual(index.match(streamURL: proxied, number: 5, name: "News")?.id, 2)
        XCTAssertEqual(index.match(streamURL: nil, number: 5, name: "Other")?.id, 1)
        XCTAssertEqual(index.match(streamURL: nil, number: nil, name: "sports")?.id, 2)
        XCTAssertNil(index.match(streamURL: nil, number: nil, name: "Weather"))
    }

    // MARK: - Rules

    func test_ruleID_roundTrips() {
        let rule = DispatcharrSeriesRule(tvgId: "news|us", title: "Evening: News", mode: "new", epgSourceId: 4)
        guard case .series(let decoded) = DispatcharrRuleID(DispatcharrRuleID.series(rule).encoded) else {
            return XCTFail("series id did not round-trip")
        }
        XCTAssertEqual(decoded, rule)

        guard case .recurring(let id) = DispatcharrRuleID(DispatcharrRuleID.recurring(42).encoded) else {
            return XCTFail("recurring id did not round-trip")
        }
        XCTAssertEqual(id, 42)
        XCTAssertNil(DispatcharrRuleID("plex-subscription-1"))
    }

    func test_seriesRule_covers_matchesChannelAndTitle() throws {
        let json = """
        {"title": "Evening News", "tvg_id": "news.us", "epg_source_id": 3}
        """
        let program = try JSONDecoder().decode(DispatcharrRecording.Program.self, from: Data(json.utf8))
        XCTAssertTrue(DispatcharrSeriesRule(tvgId: "news.us", title: "Evening News", mode: "all", epgSourceId: nil)
            .covers(program))
        XCTAssertTrue(DispatcharrSeriesRule(tvgId: "news.us", title: "", mode: "all", epgSourceId: 3)
            .covers(program))
        XCTAssertFalse(DispatcharrSeriesRule(tvgId: "news.us", title: "Morning News", mode: "all", epgSourceId: nil)
            .covers(program))
        XCTAssertFalse(DispatcharrSeriesRule(tvgId: "news.us", title: nil, mode: "all", epgSourceId: 4)
            .covers(program))
        XCTAssertFalse(DispatcharrSeriesRule(tvgId: "other", title: nil, mode: "all", epgSourceId: nil)
            .covers(program))
    }
}
