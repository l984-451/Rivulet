// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveTVSourceConnectorTests.swift
//  RivuletTests
//
//  The add-source checks run in a fixed order and fail with the exact copy the
//  forms show. Only failures are exercised: a passing check adds a real source.
//

import XCTest
@testable import Rivulet

@MainActor
final class LiveTVSourceConnectorTests: XCTestCase {

    private let m3u = URL(string: "http://server.test:9191/output/m3u")!
    private let kidsM3U = URL(string: "http://server.test:9191/output/m3u/Kids")!
    private let tokenURL = URL(string: "http://server.test:9191/api/accounts/token/")!
    private let playlist = URL(string: "http://iptv.test/playlist.m3u")!
    private let oneChannel = "#EXTM3U\n#EXTINF:-1 tvg-id=\"a\",A\nhttp://iptv.test/a\n"

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private var connector: LiveTVSourceConnector {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return LiveTVSourceConnector(session: URLSession(configuration: config))
    }

    private func source(_ message: String) -> LiveTVConnectError { .source(message) }

    private func assertThrows(_ expected: LiveTVConnectError, _ body: () throws -> Void,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? LiveTVConnectError, expected, file: file, line: line)
        }
    }

    private func assertThrows(_ expected: LiveTVConnectError, _ body: () async throws -> Void,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected \(expected.message)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? LiveTVConnectError, expected, file: file, line: line)
        }
    }

    // MARK: Own server

    func test_server_formChecksInOrder() {
        assertThrows(source("Enter your server's address first.")) {
            _ = try connector.serverRequest(address: "  ", username: "u", password: "", channelProfile: "")
        }
        assertThrows(source("Enter both your username and password, or neither.")) {
            _ = try connector.serverRequest(address: "server.test:9191", username: "u", password: "",
                                            channelProfile: "")
        }
    }

    func test_server_pastedEndpointKeepsProfile_typedProfileWins() throws {
        let pasted = try connector.serverRequest(address: "htpp://server.test:9191/output/m3u/Kids/",
                                                 username: " ", password: "", channelProfile: "")
        XCTAssertEqual(pasted.baseURL.absoluteString, "http://server.test:9191")
        XCTAssertEqual(pasted.channelProfile, "Kids")
        XCTAssertEqual(pasted.username, "")

        let typed = try connector.serverRequest(address: "server.test:9191/output/m3u/Kids",
                                                username: "", password: "", channelProfile: " Sports ")
        XCTAssertEqual(typed.channelProfile, "Sports")
    }

    func test_server_unreachable() async throws {
        MockURLProtocol.mockNetworkError(url: m3u, error: .cannotConnectToHost)
        let request = try connector.serverRequest(address: "server.test:9191", username: "", password: "",
                                                  channelProfile: "")
        await assertThrows(source("Couldn't reach that server. Check the address and port.")) {
            try await connector.connect(request, name: "")
        }
    }

    func test_server_refused() async throws {
        MockURLProtocol.mockHTTPError(url: m3u, statusCode: 401)
        let request = try connector.serverRequest(address: "server.test:9191", username: "", password: "",
                                                  channelProfile: "")
        await assertThrows(source("That server refused Rivulet.")) {
            try await connector.connect(request, name: "")
        }
    }

    func test_server_emptyPlaylist_blamesProfileWhenOneIsSet() async throws {
        MockURLProtocol.mockString(url: m3u, content: "#EXTM3U\n")
        MockURLProtocol.mockString(url: kidsM3U, content: "#EXTM3U\n")
        let plain = try connector.serverRequest(address: "server.test:9191", username: "", password: "",
                                                channelProfile: "")
        await assertThrows(source("Connected, but found no channels.")) {
            try await connector.connect(plain, name: "")
        }
        let kids = try connector.serverRequest(address: "server.test:9191", username: "", password: "",
                                               channelProfile: "Kids")
        await assertThrows(source("Connected, but that channel profile has no channels. Check the name.")) {
            try await connector.connect(kids, name: "")
        }
    }

    func test_server_signInFailure_afterChannelsLoad() async throws {
        MockURLProtocol.mockString(url: m3u, content: oneChannel)
        MockURLProtocol.mockHTTPError(url: tokenURL, statusCode: 401)
        let request = try connector.serverRequest(address: "server.test:9191", username: "u", password: "p",
                                                  channelProfile: "")
        await assertThrows(source("Dispatcharr didn't accept that username and password.")) {
            try await connector.connect(request, name: "")
        }
    }

    func test_signInCopy() {
        XCTAssertEqual(LiveTVSourceConnector.signInFailureCopy(for: DispatcharrError.notFound),
                       "That server has no Dispatcharr sign-in. Clear the username and password.")
        XCTAssertEqual(LiveTVSourceConnector.signInFailureCopy(for: DispatcharrError.httpError(429)),
                       "Too many sign-in attempts. Wait a minute and try again.")
        XCTAssertEqual(LiveTVSourceConnector.signInFailureCopy(for: URLError(.timedOut)),
                       "Couldn't sign in to Dispatcharr. Try again.")
    }

    // MARK: Playlist

    func test_playlist_formChecks() throws {
        assertThrows(source("Enter your playlist URL first.")) {
            _ = try LiveTVSourceConnector.playlistRequest(m3uURL: " ", epgURL: "")
        }
        let request = try LiveTVSourceConnector.playlistRequest(m3uURL: "iptv.test/playlist.m3u/", epgURL: "")
        XCTAssertEqual(request.m3uURL, playlist)
        XCTAssertNil(request.epgURL)
    }

    func test_playlist_httpAndParseFailures() async throws {
        let request = try LiveTVSourceConnector.playlistRequest(m3uURL: playlist.absoluteString, epgURL: "")

        MockURLProtocol.mockHTTPError(url: playlist, statusCode: 403)
        await assertThrows(source("That server refused Rivulet.")) { try await connector.connect(request, name: "") }

        MockURLProtocol.mockHTTPError(url: playlist, statusCode: 404)
        await assertThrows(source("Couldn't reach that server. Check the address and port.")) {
            try await connector.connect(request, name: "")
        }

        MockURLProtocol.mockString(url: playlist, content: "#EXTM3U\n")
        await assertThrows(source("Connected, but found no channels.")) { try await connector.connect(request, name: "") }
    }

    // MARK: Suggestions

    func test_suggestedHost_onlyForLocalPlexServers() {
        XCTAssertEqual(LiveTVSourceConnector.suggestedHost(plexServerURL: "http://10.0.0.5:32400"), "10.0.0.5")
        XCTAssertEqual(LiveTVSourceConnector.suggestedHost(plexServerURL: "https://plex.example.com"), "192.168.1.100")
        XCTAssertEqual(LiveTVSourceConnector.suggestedHost(plexServerURL: nil), "192.168.1.100")
        XCTAssertEqual(LiveTVSourceConnector.serverSuggestions(host: "h").first?.value, "http://h:9191")
    }
}
