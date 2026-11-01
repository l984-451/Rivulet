// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TvheadendDVRTests.swift
//  RivuletTests
//
//  Recording through Tvheadend, against replies measured on 4.3-2897: a single
//  airing by event id, series by series link or an anchored title rule, new
//  episodes as autorec `btype` 3, and 403 for a user without DVR rights.
//

import XCTest
@testable import Rivulet

@MainActor
final class TvheadendDVRTests: XCTestCase {

    private let server = URL(string: "http://tvh.test:9981")!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func fixture(_ name: String) throws -> Any {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "tvh_\(name)", withExtension: "json"))
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    }

    private func mock(_ path: String, _ body: String = "{}", status: Int = 200) {
        let url = URL(string: "http://tvh.test:9981/\(path)")!
        MockURLProtocol.mockResponses[url] = (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status,
                                                                               httpVersion: nil, headerFields: nil)!)
    }

    /// The form a POST sent, decoded. URLProtocol sees the body as a stream.
    private func form(_ request: URLRequest) -> [String: String] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
        }
        var result: [String: String] = [:]
        for pair in String(decoding: data, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
            result[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return result
    }

    private func requests(_ path: String) -> [URLRequest] {
        MockURLProtocol.requestHistory.filter { $0.url?.path == "/\(path)" }
    }

    private func service(signedIn: Bool = true) -> TvheadendService {
        TvheadendService(account: TvheadendAccount(server: server, username: signedIn ? "user" : nil,
                                                   password: signedIn ? "pw" : nil),
                         session: session)
    }

    private func program(guid: String?, end: Date = Date().addingTimeInterval(3600)) -> UnifiedProgram {
        UnifiedProgram(id: "c:1", channelId: "c", title: "Inside Edition", startTime: end.addingTimeInterval(-1800),
                       endTime: end, sourceGuid: guid)
    }

    private let channel = UnifiedChannel(id: "c", sourceType: .tvheadend, sourceId: "tvheadend:test", name: "FOX",
                                         tvgId: "6425c886e330ed3d74bb8f031b88e478")

    private func provider(_ username: String? = "user", canRecord: Bool? = nil) -> IPTVProvider {
        IPTVProvider(tvheadend: TvheadendAccount(server: server, username: username,
                                                 password: username == nil ? nil : "pw"),
                     sourceId: "tvheadend:test", displayName: "TV", canRecord: canRecord, session: session)
    }

    // MARK: Rules

    func test_titleRule_escapesRegex() throws {
        let conf = TvheadendService.titleRuleConf(title: "Who Wants to Be a Millionaire?", channelUUID: "c",
                                                  newOnly: false)
        XCTAssertEqual(conf["title"] as? String, "^Who Wants to Be a Millionaire\\?$")
        XCTAssertEqual(conf["channel"] as? String, "c")
        XCTAssertEqual(conf["btype"] as? Int, 0)
        XCTAssertEqual(TvheadendService.titleRuleConf(title: "A", channelUUID: "c", newOnly: true)["btype"] as? Int, 3)
    }

    func test_recordSeries_usesSeriesLinkWhenPresent_elseTitleRule() async throws {
        mock("api/dvr/autorec/create_by_series")
        mock("api/dvr/autorec/create")
        let service = service()
        try await service.recordSeries(eventId: 111, seriesLink: "crid://x", title: "Inside Edition",
                                       channelUUID: "c", newOnly: false)
        XCTAssertEqual(requests("api/dvr/autorec/create_by_series").map(form).first?["event_id"], "111")

        try await service.recordSeries(eventId: 116, seriesLink: nil, title: "Law & Order", channelUUID: "c",
                                       newOnly: false)
        // New-only always takes the title rule: a series-link rule can't filter.
        try await service.recordSeries(eventId: 111, seriesLink: "crid://x", title: "Inside Edition",
                                       channelUUID: "c", newOnly: true)
        let confs = try requests("api/dvr/autorec/create").map { request -> [String: Any] in
            let data = Data(try XCTUnwrap(form(request)["conf"]).utf8)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        XCTAssertEqual(confs.map { $0["title"] as? String }, ["^Law & Order$", "^Inside Edition$"])
        XCTAssertEqual(confs.map { $0["btype"] as? Int }, [0, 3])
        XCTAssertEqual(requests("api/dvr/autorec/create_by_series").count, 1)
    }

    func test_dvr403_isCantRecord() async {
        mock("api/dvr/entry/create_by_event", status: 403)
        do {
            try await service().recordEvent(eventId: 44)
            XCTFail("expected cantRecord")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This Tvheadend user can't record.")
        }
    }

    // MARK: Options

    func test_recordOptions_needEventIdAndFutureEnd() async throws {
        let provider = provider()
        do {
            _ = try await provider.recordOptions(for: program(guid: nil), on: channel)
            XCTFail("expected noGuideIdentity")
        } catch {
            XCTAssertEqual(error.localizedDescription, LiveTVRecordingError.noGuideIdentity.localizedDescription)
        }
        do {
            _ = try await provider.recordOptions(for: program(guid: "44", end: Date().addingTimeInterval(-60)), on: channel)
            XCTFail("expected programEnded")
        } catch {
            XCTAssertEqual(error.localizedDescription, LiveTVRecordingError.programEnded.localizedDescription)
        }
    }

    func test_recordOptions_offerSingleSeriesAndNew() async throws {
        let options = try await provider().recordOptions(for: program(guid: "44"), on: channel)
        XCTAssertEqual(options.map(\.title), ["Record", "Record Series", "Record New Episodes"])
        XCTAssertEqual(options.map(\.scope), [.single, .series, .series])
    }

    func test_record_single_postsEventId() async throws {
        mock("api/dvr/entry/create_by_event")
        let provider = provider()
        let options = try await provider.recordOptions(for: program(guid: "44"), on: channel)
        let option = try XCTUnwrap(options.first)
        try await provider.record(option, program: program(guid: "44"), on: channel)
        XCTAssertEqual(requests("api/dvr/entry/create_by_event").map(form).first?["event_id"], "44")
    }

    // MARK: Lists

    func test_recordings_mapStatusRuleAndGuid() throws {
        let recordings = TvheadendService.recordings(from: try fixture("dvr_entry_grid"))
        XCTAssertEqual(recordings.count, 3)
        XCTAssertEqual(recordings.map(\.status), [.failed, .scheduled, .scheduled])
        let ruled = recordings[1]
        XCTAssertEqual(ruled.autorecUUID, "da2dfe4c80df5f785133e24151ca152f")
        XCTAssertEqual(ruled.eventId, 179)
        XCTAssertEqual(ruled.channelUUID, "6425c886e330ed3d74bb8f031b88e478")
        XCTAssertEqual(ruled.start, Date(timeIntervalSince1970: 1_793_333_100))
        XCTAssertNil(ruled.subtitle)
        XCTAssertNil(recordings[2].autorecUUID)
        XCTAssertEqual(recordings[2].subtitle, "Parker Posey; Nicholas Galitzine; Dominic Fike")
    }

    func test_recordings_askOnlyUpcomingSorted() async throws {
        mock("api/dvr/entry/grid_upcoming?limit=1000&sort=start&dir=ASC", #"{"entries":[]}"#)
        let recordings = try await service().recordings()
        XCTAssertEqual(recordings, [])
    }

    func test_status_eachMeasuredValue() {
        XCTAssertEqual(TvheadendService.status("scheduled"), .scheduled)
        XCTAssertEqual(TvheadendService.status("recording"), .recording)
        XCTAssertEqual(TvheadendService.status("completed"), .completed)
        XCTAssertEqual(TvheadendService.status("completedWarning"), .completed)
        XCTAssertEqual(TvheadendService.status("completedError"), .failed)
        XCTAssertEqual(TvheadendService.status("completedRerecord"), .failed)
        XCTAssertEqual(TvheadendService.status("something new"), .failed)
    }

    func test_rules_titleWithoutAnchors() throws {
        let rules = TvheadendService.rules(from: try fixture("dvr_autorec_grid"))
        XCTAssertEqual(rules.map(\.title), ["Inside Edition", "Inside Edition"])
        XCTAssertEqual(rules.map(\.newOnly), [true, false])
        XCTAssertEqual(TvheadendService.ruleTitle(name: nil, pattern: "^Who Wants to Be a Millionaire\\?$"),
                       "Who Wants to Be a Millionaire?")
    }

    // MARK: Gate

    func test_supportsRecording_anonymousFalse_signedInTrue_storedFalseWins() {
        XCTAssertFalse(provider(nil).supportsRecording)
        XCTAssertTrue(provider().supportsRecording)
        XCTAssertTrue(provider(canRecord: true).supportsRecording)
        XCTAssertFalse(provider(canRecord: false).supportsRecording)
    }

    func test_canRecord_fromDVRGridStatus() async {
        mock("api/dvr/entry/grid?limit=1", #"{"entries":[]}"#)
        let allowed = await service().canRecord()
        XCTAssertEqual(allowed, true)
        mock("api/dvr/entry/grid?limit=1", status: 403)
        let refused = await service().canRecord()
        XCTAssertEqual(refused, false)
    }
}
