// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TvheadendSourceTests.swift
//  RivuletTests
//
//  Tvheadend as a Live TV source: channel and guide mapping, playback URLs,
//  the saved form, and the add-source checks. Replies from the measured
//  fixtures in `Fixtures/Tvheadend` (see TvheadendServiceTests).
//

import XCTest
@testable import Rivulet

@MainActor
final class TvheadendSourceTests: XCTestCase {

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

    private func fixture(_ name: String, _ ext: String = "json") throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "tvh_\(name)", withExtension: ext))
        return try Data(contentsOf: url)
    }

    private func mock(_ path: String, _ data: Data, status: Int = 200) {
        let url = URL(string: "http://tvh.test:9981/\(path)")!
        MockURLProtocol.mockResponses[url] = (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                                                    headerFields: nil)!)
    }

    private func mockLineup() throws {
        mock("api/serverinfo", try fixture("serverinfo"))
        mock("api/channel/grid?limit=10000", try fixture("channel_grid"))
        mock("api/channeltag/grid?limit=1000", try fixture("channeltag_grid"))
        mock("playlist/ticket/channel/6425c886e330ed3d74bb8f031b88e478", try fixture("ticket_playlist", "m3u"))
    }

    /// Answers the guide request for any window with the fixture.
    private func mockGuide(from: Date, to: Date) throws {
        let url = TvheadendService(account: account()).eventsURL(from: from, to: to)
        MockURLProtocol.mockResponses[url] = (try fixture("epg_events_grid"),
                                              HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    private func account(_ username: String? = "user") -> TvheadendAccount {
        TvheadendAccount(server: server, username: username, password: username == nil ? nil : "pw")
    }

    private func provider(_ username: String? = "user") -> IPTVProvider {
        IPTVProvider(tvheadend: account(username), sourceId: "tvheadend:test", displayName: "TV", session: session)
    }

    private var connector: LiveTVSourceConnector {
        LiveTVSourceConnector(session: session)
    }

    // MARK: Identity and saving

    func test_tvheadendSourceId_stableAndPerUser() {
        let id = LiveTVDataStore.tvheadendSourceId(for: account())
        XCTAssertTrue(id.hasPrefix("tvheadend:"))
        XCTAssertEqual(id, LiveTVDataStore.tvheadendSourceId(for: account()))
        XCTAssertEqual(id, LiveTVDataStore.tvheadendSourceId(
            for: TvheadendAccount(server: URL(string: "http://TVH.test:9981")!, username: "user", password: "other")))
        XCTAssertNotEqual(id, LiveTVDataStore.tvheadendSourceId(for: account(nil)))
        XCTAssertNotEqual(id, LiveTVDataStore.tvheadendSourceId(for: account("someone")))
        XCTAssertFalse(id.contains("tvh.test"))
    }

    func test_sourceConfiguration_keepsUsernameAndCanRecord_oldConfigsDecode() throws {
        let config = LiveTVDataStore.SourceConfiguration(id: "tvheadend:x", type: "tvheadend", name: "TV",
                                                         baseURL: "http://tvh.test:9981", m3uURL: nil, epgURL: nil,
                                                         apiToken: nil, username: "user", canRecord: false)
        let decoded = try JSONDecoder().decode(LiveTVDataStore.SourceConfiguration.self,
                                               from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.username, "user")
        XCTAssertEqual(decoded.canRecord, false)
        let old = Data(#"{"id":"dispatcharr:x","type":"dispatcharr","name":"Live TV","baseURL":"http://d.test"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(LiveTVDataStore.SourceConfiguration.self, from: old).canRecord)
    }

    // MARK: Channels and guide

    func test_refreshChannels_mapsUUIDToTvgIdAndPassStream() async throws {
        try mockLineup()
        let channels = try await provider(nil).refreshChannels()
        XCTAssertEqual(channels.count, 4)
        let fox = try XCTUnwrap(channels.first { $0.name == "FOX 6 WBRC" })
        XCTAssertEqual(fox.sourceType, .tvheadend)
        XCTAssertEqual(fox.tvgId, "6425c886e330ed3d74bb8f031b88e478")
        XCTAssertEqual(fox.channelNumber, 6)
        XCTAssertEqual(fox.groupTitle, "Birmingham")
        XCTAssertEqual(fox.streamURL?.absoluteString,
                       "http://tvh.test:9981/stream/channel/6425c886e330ed3d74bb8f031b88e478?profile=pass")
    }

    func test_fetchEPG_groupsByChannelUUID_setsSourceGuid() async throws {
        try mockLineup()
        let provider = provider()
        let channels = try await provider.refreshChannels()
        let start = Date(timeIntervalSince1970: 1_793_100_000), end = Date(timeIntervalSince1970: 1_793_200_000)
        try mockGuide(from: IPTVProvider.tvheadendGuideWindow(start: start, end: end, now: start).from,
                      to: IPTVProvider.tvheadendGuideWindow(start: start, end: end, now: start).to)
        let guide = try await provider.fetchEPG(for: channels, startDate: start, endDate: end, now: start)
        let fox = try XCTUnwrap(channels.first { $0.name == "FOX 6 WBRC" })
        XCTAssertEqual(guide[fox.id]?.map(\.sourceGuid), ["108", "111", "116"])
        let nbc = try XCTUnwrap(channels.first { $0.name == "NBC 13 WVTM" })
        let show = try XCTUnwrap(guide[nbc.id]?.first)
        XCTAssertEqual(show.episodeNumber, "S14 E18")
        XCTAssertTrue(show.isNew)
        XCTAssertFalse(show.isMovie)
        XCTAssertEqual(show.id, "\(nbc.id):1793158440")
        // The event on a channel this source doesn't list is dropped.
        XCTAssertEqual(guide.values.joined().count, 4)
    }

    func test_guideWindow_coversRequestAndADay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let window = IPTVProvider.tvheadendGuideWindow(start: now, end: now.addingTimeInterval(6 * 3600), now: now)
        XCTAssertEqual(window.from, now.addingTimeInterval(-3600))
        XCTAssertEqual(window.to, now.addingTimeInterval(24 * 3600))
        let far = IPTVProvider.tvheadendGuideWindow(start: now.addingTimeInterval(3600), end: now.addingTimeInterval(40 * 3600),
                                                    now: now)
        XCTAssertEqual(far.to, now.addingTimeInterval(40 * 3600))
    }

    func test_fetchEPG_refetchesPastTheCachedWindow() async throws {
        try mockLineup()
        let provider = provider()
        let channels = try await provider.refreshChannels()
        let start = Date(timeIntervalSince1970: 1_793_100_000)
        let short = IPTVProvider.tvheadendGuideWindow(start: start, end: start.addingTimeInterval(3600), now: start)
        let long = IPTVProvider.tvheadendGuideWindow(start: start, end: start.addingTimeInterval(48 * 3600), now: start)
        try mockGuide(from: short.from, to: short.to)
        try mockGuide(from: long.from, to: long.to)
        _ = try await provider.fetchEPG(for: channels, startDate: start, endDate: start.addingTimeInterval(3600), now: start)
        _ = try await provider.fetchEPG(for: channels, startDate: start, endDate: start.addingTimeInterval(2 * 3600), now: start)
        _ = try await provider.fetchEPG(for: channels, startDate: start, endDate: start.addingTimeInterval(48 * 3600), now: start)
        XCTAssertEqual(MockURLProtocol.requestHistory.filter { $0.url?.path == "/api/epg/events/grid" }.count, 2)
    }

    // MARK: Playback

    func test_resolveStreamURL_anonymousUsesChannelURL_signedInFetchesTicket() async throws {
        try mockLineup()
        let anonymous = provider(nil)
        let channels = try await anonymous.refreshChannels()
        let channel = try XCTUnwrap(channels.first { $0.name == "FOX 6 WBRC" })
        let plain = try await anonymous.resolveStreamURL(for: channel)
        XCTAssertEqual(plain, channel.streamURL)
        let ticketed = try await provider().resolveStreamURL(for: channel)
        XCTAssertEqual(ticketed?.absoluteString,
                       "http://tvh.test:9981/stream/channelid/113780068?ticket=TICKET&profile=pass")
    }

    // MARK: Adding

    func test_request_formChecks() throws {
        XCTAssertThrowsError(try connector.tvheadendRequest(address: " ", username: "", password: "")) {
            XCTAssertEqual($0 as? LiveTVConnectError, .source("Enter your server's address first."))
        }
        XCTAssertThrowsError(try connector.tvheadendRequest(address: "tvh.test:9981", username: "user", password: "")) {
            XCTAssertEqual($0 as? LiveTVConnectError, .source("Enter both your username and password, or neither."))
        }
        let anonymous = try connector.tvheadendRequest(address: "tvh.test:9981/", username: "", password: "")
        XCTAssertEqual(anonymous.account, TvheadendAccount(server: server, username: nil, password: nil))
        let signedIn = try connector.tvheadendRequest(address: "http://tvh.test:9981", username: " user ", password: "pw")
        XCTAssertEqual(signedIn.account, account())
    }

    func test_request_movesLoginOutOfAddress() throws {
        let pasted = try connector.tvheadendRequest(address: "http://me:p%40ss@tvh.test:9981", username: "", password: "")
        XCTAssertEqual(pasted.account, TvheadendAccount(server: server, username: "me", password: "p@ss"))
        let typed = try connector.tvheadendRequest(address: "http://me:old@tvh.test:9981", username: "user", password: "pw")
        XCTAssertEqual(typed.account, account())
    }

    func test_connect_emptyChannels() async throws {
        mock("api/serverinfo", try fixture("serverinfo"))
        mock("api/channel/grid?limit=10000", Data(#"{"entries":[],"total":0}"#.utf8))
        let request = try connector.tvheadendRequest(address: "tvh.test:9981", username: "", password: "")
        do {
            try await connector.connect(request, name: "")
            XCTFail("expected no channels")
        } catch {
            XCTAssertEqual(error as? LiveTVConnectError, .source("Connected, but found no channels."))
        }
    }

    func test_connect_ticketFailureBlocksAdd() async throws {
        try mockLineup()
        mock("playlist/ticket/channel/6425c886e330ed3d74bb8f031b88e478", Data(), status: 403)
        let request = try connector.tvheadendRequest(address: "tvh.test:9981", username: "user", password: "pw")
        do {
            try await connector.connect(request, name: "")
            XCTFail("expected the ticket failure")
        } catch {
            XCTAssertEqual(error as? LiveTVConnectError,
                           .source(LiveTVSourceConnector.tvheadendFailureCopy(for: TvheadendError.forbidden)))
        }
    }

    func test_failureCopy_eachError() {
        let copy = LiveTVSourceConnector.tvheadendFailureCopy
        XCTAssertEqual(copy(TvheadendError.loginRequired), "This Tvheadend server needs a username and password.")
        XCTAssertEqual(copy(TvheadendError.invalidLogin), "Tvheadend didn't accept that username and password.")
        XCTAssertEqual(copy(TvheadendError.forbidden),
                       "Tvheadend refused this user. Check its password and rights in Tvheadend.")
        XCTAssertEqual(copy(TvheadendError.notTvheadend),
                       "That address isn't a Tvheadend server. Check the address and port.")
        XCTAssertEqual(copy(TvheadendError.noTicket),
                       "Tvheadend didn't give Rivulet a stream for this user. Check its streaming rights, or update Tvheadend.")
        XCTAssertEqual(copy(TvheadendError.httpError(500)), "Couldn't reach that server. Check the address and port.")
    }
}
