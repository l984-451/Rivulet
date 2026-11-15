// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  XtreamServiceTests.swift
//  RivuletTests
//
//  Xtream Codes replies as panels really send them: numbers as strings or ints
//  in one reply, a login pasted as a get.php link, refusals as 401, 404 or a
//  200 with `auth: 0`. Shapes measured on Dispatcharr 0.32.
//

import XCTest
@testable import Rivulet

@MainActor
final class XtreamServiceTests: XCTestCase {

    private let account = XtreamAccount(server: URL(string: "http://panel.test:8080")!,
                                        username: "me", password: "p/ss+word?")

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

    // MARK: Address

    func test_pastedGetPhpLink_givesServerAndLogin() {
        let parsed = XtreamService.parseAddress(
            " http://panel.test:8080/get.php?username=me&password=secret&type=m3u_plus&output=ts ")
        XCTAssertEqual(parsed.server, "http://panel.test:8080")
        XCTAssertEqual(parsed.username, "me")
        XCTAssertEqual(parsed.password, "secret")
    }

    func test_address_keepsPathPrefix_dropsEndpointAndSlashes() {
        XCTAssertEqual(XtreamService.parseAddress("panel.test/iptv/player_api.php").server, "http://panel.test/iptv")
        XCTAssertEqual(XtreamService.parseAddress("https://panel.test:443//").server, "https://panel.test:443")
        XCTAssertNil(XtreamService.parseAddress("panel.test:8080").username)
    }

    // MARK: URLs

    func test_streamURL_escapesEachLoginSegment() {
        let url = XtreamService(account: account).streamURL(streamId: "842", format: "ts")
        XCTAssertEqual(url.absoluteString, "http://panel.test:8080/live/me/p%2Fss+word%3F/842.ts")
    }

    func test_guideURL_escapesPlusForPHP() {
        let url = XtreamService(account: account).guideURL.absoluteString
        XCTAssertTrue(url.hasPrefix("http://panel.test:8080/xmltv.php?username=me&password="), url)
        XCTAssertTrue(url.contains("%2B"), url)
        XCTAssertFalse(url.contains("+"), url)
    }

    func test_streamFormat_prefersTS() {
        XCTAssertEqual(XtreamService.streamFormat(allowed: []), "ts")
        XCTAssertEqual(XtreamService.streamFormat(allowed: ["m3u8", "TS"]), "ts")
        XCTAssertEqual(XtreamService.streamFormat(allowed: ["m3u8", "rtmp"]), "m3u8")
    }

    // MARK: Account

    func test_accountInfo_mixedTypes() throws {
        let json: [String: Any] = ["user_info": ["auth": 1, "status": "Active", "exp_date": "1800000000",
                                                 "max_connections": "2", "active_cons": 1,
                                                 "allowed_output_formats": ["ts", "m3u8"]],
                                   "server_info": ["timezone": "UTC"]]
        let info = try XtreamService.accountInfo(from: json, now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(info.maxConnections, 2)
        XCTAssertEqual(info.activeConnections, 1)
        XCTAssertEqual(info.allowedFormats, ["ts", "m3u8"])
        XCTAssertEqual(info.expiresAt, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func test_accountInfo_refusals() {
        func status(_ user: [String: Any]) -> XtreamError? {
            do {
                _ = try XtreamService.accountInfo(from: ["user_info": user], now: Date(timeIntervalSince1970: 1_700_000_000))
                return nil
            } catch { return error as? XtreamError }
        }
        XCTAssertEqual(status(["auth": 0]), .invalidLogin)
        XCTAssertEqual(status(["auth": "1", "status": "Banned"]), .banned)
        XCTAssertEqual(status(["auth": 1, "status": "Disabled"]), .disabled)
        XCTAssertEqual(status(["auth": 1, "status": "Active", "exp_date": 1_600_000_000]), .expired)
        XCTAssertNil(status(["auth": 1, "status": "Active", "exp_date": NSNull()]))
        XCTAssertNil(status(["auth": 1, "exp_date": ""]))
        XCTAssertThrowsError(try XtreamService.accountInfo(from: ["error": "x"]))
    }

    func test_parse_statusAndBody() {
        func error(_ body: String, _ status: Int) -> XtreamError? {
            do {
                _ = try XtreamService.parse(Data(body.utf8), status: status)
                return nil
            } catch { return error as? XtreamError }
        }
        XCTAssertNil(error("\u{FEFF}[]", 200))
        XCTAssertEqual(error("<html>Login</html>", 200), .notXtream)
        XCTAssertEqual(error("", 200), .notXtream)
        XCTAssertEqual(error("{\"error\": \"Unauthorized\"}", 401), .invalidLogin)
        XCTAssertEqual(error("<h1>Not Found</h1>", 404), .invalidLogin)
        XCTAssertEqual(error("", 513), .invalidLogin)
        XCTAssertEqual(error("Banned for repeated abuse", 403), .refused("Banned for repeated abuse"))
        XCTAssertEqual(error("<html>403</html>", 403), .invalidLogin)
        XCTAssertEqual(error("", 502), .httpError(502))
    }

    // MARK: Channels

    func test_channels_toleratesPanelTypes_andSkipsBrokenEntries() {
        let service = XtreamService(account: account)
        let streams: [[String: Any]] = [
            ["num": 6, "name": "FOX 6", "stream_id": 842, "stream_icon": "http://logo/6.png",
             "epg_channel_id": "6", "category_id": "3807"],
            ["num": "7.1", "name": " Sub ", "stream_id": "900", "epg_channel_id": NSNull(), "category_id": 12],
            ["name": "No id"],
            ["stream_id": 5, "name": ""],
            ["stream_id": 6, "name": "Radio", "stream_type": "radio_streams"],
            ["stream_id": 7, "name": "##### 4K UHD #####", "stream_type": "live"],
        ]
        let categories: [[String: Any]] = [["category_id": "3807", "category_name": "Local", "parent_id": 0],
                                           ["category_id": 12, "category_name": "Sports"]]
        let channels = XtreamService.channels(from: streams, categories: categories, service: service, format: "ts")
        XCTAssertEqual(channels.count, 2)
        XCTAssertEqual(channels[0].channelNumber, 6)
        XCTAssertEqual(channels[0].tvgId, "6")
        XCTAssertEqual(channels[0].groupTitle, "Local")
        XCTAssertEqual(channels[0].channelKey, "xc842")
        XCTAssertEqual(channels[0].streamURL.lastPathComponent, "842.ts")
        XCTAssertNil(channels[1].channelNumber)
        XCTAssertNil(channels[1].tvgId)
        XCTAssertEqual(channels[1].name, "Sub")
        XCTAssertEqual(channels[1].groupTitle, "Sports")
        XCTAssertTrue(XtreamService.channels(from: false, categories: nil, service: service, format: "ts").isEmpty)
    }

    func test_channels_groupRankFollowsCategoryOrder() {
        let service = XtreamService(account: account)
        let streams: [[String: Any]] = [["stream_id": 1, "name": "A", "category_id": "2"],
                                        ["stream_id": 2, "name": "B", "category_id": "1"],
                                        ["stream_id": 3, "name": "C", "category_id": "9"]]
        let categories: [[String: Any]] = [["category_id": "1", "category_name": "Zulu"],
                                           ["category_id": "2", "category_name": "Alpha"]]
        let channels = XtreamService.channels(from: streams, categories: categories, service: service, format: "ts")
        XCTAssertEqual(channels.map(\.groupRank), [1, 0, nil])
    }

    func test_fetchChannels_survivesFailedCategories() async throws {
        let service = XtreamService(account: XtreamAccount(server: URL(string: "http://panel.test")!,
                                                           username: "u", password: "p"), session: session)
        let base = "http://panel.test/player_api.php?username=u&password=p&action="
        MockURLProtocol.mockString(url: URL(string: base + "get_live_streams")!,
                                   content: "[{\"stream_id\":1,\"name\":\"A\",\"category_id\":\"9\"}]")
        MockURLProtocol.mockHTTPError(url: URL(string: base + "get_live_categories")!, statusCode: 500)
        let channels = try await service.fetchChannels(format: "ts")
        XCTAssertEqual(channels.map(\.name), ["A"])
        XCTAssertNil(channels[0].groupTitle)
    }

    // MARK: Connector

    func test_connector_formChecks_andPastedLogin() throws {
        let connector = LiveTVSourceConnector(session: session)
        XCTAssertThrowsError(try connector.xtreamRequest(address: " ", username: "u", password: "p")) {
            XCTAssertEqual($0 as? LiveTVConnectError, .source("Enter your provider's server address first."))
        }
        XCTAssertThrowsError(try connector.xtreamRequest(address: "panel.test", username: "u", password: "")) {
            XCTAssertEqual($0 as? LiveTVConnectError, .source("Enter the username and password from your provider."))
        }
        let pasted = try connector.xtreamRequest(address: "panel.test:8080/get.php?username=me&password=pw",
                                                 username: "", password: "")
        XCTAssertEqual(pasted.account, XtreamAccount(server: URL(string: "http://panel.test:8080")!,
                                                     username: "me", password: "pw"))
    }

    func test_connector_wrongPassword() async throws {
        let connector = LiveTVSourceConnector(session: session)
        let request = try connector.xtreamRequest(address: "panel.test", username: "u", password: "bad")
        MockURLProtocol.mockString(url: URL(string: "http://panel.test/player_api.php?username=u&password=bad")!,
                                   content: "{\"error\":\"Unauthorized\"}", statusCode: 401)
        do {
            try await connector.connect(request, name: "")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? LiveTVConnectError,
                           .source("The server didn't accept that username and password."))
        }
    }

    // MARK: Saved source

    func test_sourceId_hidesLogin_andSavedConfigDecodes() throws {
        let id = LiveTVDataStore.xtreamSourceId(for: account)
        XCTAssertTrue(id.hasPrefix("xtream:"))
        XCTAssertFalse(id.contains("me"))
        XCTAssertEqual(id, LiveTVDataStore.xtreamSourceId(
            for: XtreamAccount(server: URL(string: "HTTP://PANEL.test:8080")!, username: "me", password: "other")))

        let config = LiveTVDataStore.SourceConfiguration(id: id, type: "xtream", name: "X", baseURL: "http://panel.test:8080",
                                                         m3uURL: nil, epgURL: nil, apiToken: nil, username: "me")
        let decoded = try JSONDecoder().decode(LiveTVDataStore.SourceConfiguration.self,
                                               from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.username, "me")
        let legacy = try JSONDecoder().decode(LiveTVDataStore.SourceConfiguration.self, from: Data(
            "{\"id\":\"m3u:1\",\"type\":\"m3u\",\"name\":\"M\"}".utf8))
        XCTAssertNil(legacy.username)
    }
}
