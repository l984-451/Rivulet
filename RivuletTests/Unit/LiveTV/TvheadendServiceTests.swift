// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TvheadendServiceTests.swift
//  RivuletTests
//
//  Replies measured on Tvheadend 4.3-2897 (api 20, linuxserver image) fed by an
//  IPTV network and an XMLTV grabber:
//  - Auth is Digest (MD5) by default; Basic is refused. No login: 401. A wrong
//    password or unknown user: 403, and `api/serverinfo` is open to any valid user.
//  - A user without DVR rights gets 403 from every `api/dvr` call.
//  - Imagecache is off by default (`icon_public_url` equals `icon`); on, it is
//    `imagecache/N` and needs the login.
//  - `/playlist/ticket/channel/<uuid>` lists one absolute
//    `/stream/channelid/<n>?ticket=<hex>&profile=pass` that plays with no login.
//  - Type and provider tags sit on every channel.
//  Fixture edits: a disabled channel, a picon channel, ESPN's number zeroed, NBC's
//  icon cleared, one event given a series link and one an unknown channel.
//

import XCTest
@testable import Rivulet

final class TvheadendServiceTests: XCTestCase {

    private let server = URL(string: "http://tvh.test:9981")!
    private let password = "p/ss+w@rd?:x"

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

    private func service(signedIn: Bool = true) -> TvheadendService {
        TvheadendService(account: TvheadendAccount(server: server, username: signedIn ? "user" : nil,
                                                   password: signedIn ? password : nil),
                         session: session)
    }

    private func mock(_ path: String, _ data: Data, status: Int = 200) {
        let url = URL(string: "http://tvh.test:9981/\(path)")!
        MockURLProtocol.mockResponses[url] = (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                                                    headerFields: nil)!)
    }

    /// The synchronized test group copies fixtures flat into the bundle root.
    private func fixture(_ name: String, _ ext: String = "json") throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "tvh_\(name)", withExtension: ext))
        return try Data(contentsOf: url)
    }

    private func json(_ name: String) throws -> Any {
        try JSONSerialization.jsonObject(with: fixture(name))
    }

    private func mockLineup() throws {
        mock("api/serverinfo", try fixture("serverinfo"))
        mock("api/channel/grid?limit=10000", try fixture("channel_grid"))
        mock("api/channeltag/grid?limit=1000", try fixture("channeltag_grid"))
        mock(eventsPath, try fixture("epg_events_grid"))
        mock("playlist/ticket/channel/abc", try fixture("ticket_playlist", "m3u"))
    }

    private let window = (from: Date(timeIntervalSince1970: 1_793_100_000), to: Date(timeIntervalSince1970: 1_793_200_000))

    private var eventsPath: String {
        String(service().eventsURL(from: window.from, to: window.to).absoluteString.dropFirst("http://tvh.test:9981/".count))
    }

    // MARK: Verify and errors

    func test_verify_serverinfo_passes() async throws {
        try mockLineup()
        try await service().verify()
    }

    func test_verify_htmlPage_isNotTvheadend() async {
        mock("api/serverinfo", Data("<html>router login</html>".utf8))
        do {
            try await service().verify()
            XCTFail("expected notTvheadend")
        } catch {
            XCTAssertEqual(error as? TvheadendError, .notTvheadend)
        }
    }

    func test_401_anonymous_isLoginRequired_signedIn_isInvalidLogin() {
        func error(signedIn: Bool) -> TvheadendError? {
            do {
                _ = try TvheadendService.parse(Data(), status: 401, signedIn: signedIn)
                return nil
            } catch { return error as? TvheadendError }
        }
        XCTAssertEqual(error(signedIn: false), .loginRequired)
        XCTAssertEqual(error(signedIn: true), .invalidLogin)
    }

    func test_403_isForbidden() {
        func error(loginCheck: Bool) -> TvheadendError? {
            do {
                _ = try TvheadendService.parse(Data(), status: 403, signedIn: true, loginCheck: loginCheck)
                return nil
            } catch { return error as? TvheadendError }
        }
        XCTAssertEqual(error(loginCheck: false), .forbidden)
        // Tvheadend answers a wrong digest login with 403, and serverinfo is open to every user.
        XCTAssertEqual(error(loginCheck: true), .invalidLogin)
    }

    // MARK: Channels

    func test_channels_skipDisabled_keepMissingNumberAndIcon() throws {
        let channels = TvheadendService.channels(from: try json("channel_grid"), tags: try json("channeltag_grid"),
                                                 server: server, signedIn: false)
        XCTAssertEqual(channels.map(\.name), ["FOX 6 WBRC", "ESPN", "NBC 13 WVTM", "Picon Channel"])
        let espn = try XCTUnwrap(channels.first { $0.name == "ESPN" })
        XCTAssertNil(espn.number)
        XCTAssertEqual(channels.first?.number, 6)
        XCTAssertNil(channels.first { $0.name == "NBC 13 WVTM" }?.iconURL)
    }

    func test_channels_groupFromFirstTag() throws {
        let channels = TvheadendService.channels(from: try json("channel_grid"), tags: try json("channeltag_grid"),
                                                 server: server, signedIn: true)
        XCTAssertEqual(channels.first { $0.name == "FOX 6 WBRC" }?.group, "Birmingham")
        XCTAssertEqual(channels.first { $0.name == "ESPN" }?.group, "Sports")
    }

    func test_channels_iconPrefersAbsoluteThenImagecache() throws {
        let grid = try json("channel_grid"), tags = try json("channeltag_grid")
        let anonymous = TvheadendService.channels(from: grid, tags: tags, server: server, signedIn: false)
        XCTAssertEqual(anonymous.first?.iconURL?.absoluteString, "http://logos.test/api/channels/logos/266492/cache/")
        XCTAssertEqual(anonymous.first { $0.name == "Picon Channel" }?.iconURL?.absoluteString,
                       "http://tvh.test:9981/imagecache/7")
        // The image loader sends no login, and the imagecache needs one.
        let signedIn = TvheadendService.channels(from: grid, tags: tags, server: server, signedIn: true)
        XCTAssertNil(signedIn.first { $0.name == "Picon Channel" }?.iconURL)
    }

    // MARK: Guide

    func test_events_mapTimesAndOptionalFields() throws {
        let events = TvheadendService.events(from: try json("epg_events_grid"))
        XCTAssertEqual(events.count, 5)
        let show = try XCTUnwrap(events.first { $0.eventId == 44 })
        XCTAssertEqual(show.channelUUID, "0c186d9cdf139a7a882e0040398ef048")
        XCTAssertEqual(show.start, Date(timeIntervalSince1970: 1_793_158_440))
        XCTAssertEqual(show.stop, Date(timeIntervalSince1970: 1_793_162_220))
        XCTAssertEqual(show.subtitle, "Parker Posey; Nicholas Galitzine; Dominic Fike")
        XCTAssertEqual(show.episode, "S14 E18")
        XCTAssertTrue(show.isNew)
        XCTAssertEqual(show.imageURL?.absoluteString, "http://dtil.tmsimg.com/assets/p9898935_b_h8_am.jpg?w=960&h=540")
        let local = try XCTUnwrap(events.first { $0.eventId == 116 })
        XCTAssertNil(local.subtitle)
        XCTAssertNil(local.description)
        XCTAssertNil(local.episode)
        XCTAssertFalse(local.isNew)
        XCTAssertEqual(events.first { $0.eventId == 111 }?.seriesLink, "crid://example.test/series1")
    }

    func test_eventsURL_asksOnlyTheWindow() throws {
        let url = service().eventsURL(from: window.from, to: window.to)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(url.path, "/api/epg/events/grid")
        XCTAssertEqual(items.first { $0.name == "sort" }?.value, "start")
        let filter = try XCTUnwrap(items.first { $0.name == "filter" }?.value)
        let clauses = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(filter.utf8)) as? [[String: Any]])
        XCTAssertEqual(clauses.count, 2)
        XCTAssertTrue(clauses.contains { $0["field"] as? String == "stop" && $0["comparison"] as? String == "gt"
                                         && $0["value"] as? Int == 1_793_100_000 })
        XCTAssertTrue(clauses.contains { $0["field"] as? String == "start" && $0["comparison"] as? String == "lt"
                                         && $0["value"] as? Int == 1_793_200_000 })
    }

    func test_errors_areLocalized() {
        XCTAssertEqual(TvheadendError.forbidden.localizedDescription,
                       "Tvheadend refused this user. Check its password and rights in Tvheadend.")
        XCTAssertEqual(TvheadendError.noTicket.localizedDescription,
                       LiveTVSourceConnector.tvheadendFailureCopy(for: TvheadendError.noTicket))
    }

    // MARK: Streams

    func test_streamURL_isPassProfile() {
        XCTAssertEqual(service().streamURL(channelUUID: "abc").absoluteString,
                       "http://tvh.test:9981/stream/channel/abc?profile=pass")
    }

    func test_ticketURL_fromPlaylist() throws {
        XCTAssertEqual(TvheadendService.ticketURL(fromPlaylist: try fixture("ticket_playlist", "m3u"), server: server)?
                        .absoluteString,
                       "http://tvh.test:9981/stream/channelid/113780068?ticket=TICKET&profile=pass")
        XCTAssertEqual(TvheadendService.ticketURL(fromPlaylist: Data("#EXTM3U\n/stream/channelid/5?ticket=T\n".utf8),
                                                  server: server)?.absoluteString,
                       "http://tvh.test:9981/stream/channelid/5?ticket=T")
    }

    func test_ticketedStreamURL_fetchesEveryTime() async throws {
        try mockLineup()
        let service = service()
        _ = try await service.ticketedStreamURL(channelUUID: "abc")
        _ = try await service.ticketedStreamURL(channelUUID: "abc")
        XCTAssertEqual(MockURLProtocol.requestHistory.filter { $0.url?.path == "/playlist/ticket/channel/abc" }.count, 2)
    }

    func test_ticket_emptyPlaylist_isNoTicket() async {
        mock("playlist/ticket/channel/abc", Data("#EXTM3U\n".utf8))
        do {
            _ = try await service().ticketedStreamURL(channelUUID: "abc")
            XCTFail("expected noTicket")
        } catch {
            XCTAssertEqual(error as? TvheadendError, .noTicket)
        }
    }

    // MARK: Privacy

    func test_password_neverInAnyRequestURL() async throws {
        try mockLineup()
        let service = service()
        try await service.verify()
        _ = try await service.fetchChannels()
        _ = try await service.fetchEvents(from: window.from, to: window.to)
        _ = try await service.ticketedStreamURL(channelUUID: "abc")
        XCTAssertFalse(MockURLProtocol.requestHistory.isEmpty)
        for request in MockURLProtocol.requestHistory {
            let url = request.url?.absoluteString ?? ""
            XCTAssertFalse(url.contains("p/ss") || url.contains("w@rd") || url.contains("p%2Fss"), url)
        }
    }
}
