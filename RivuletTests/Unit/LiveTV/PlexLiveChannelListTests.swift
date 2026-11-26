// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexLiveChannelListTests.swift
//  RivuletTests
//
//  Issue #338: the channel list came out of a six-hour guide grid, which a
//  slow PMS could not produce inside the request timeout. It now comes from
//  the DVR lineup, and guide loads that arrive together share one request.
//

import XCTest
@testable import Rivulet

final class PlexLiveChannelListTests: XCTestCase {

    private final class StubNetwork: PlexNetworkManager {
        /// Response body per URL path. A missing path fails the request.
        var bodies: [String: String] = [:]
        var requested: [(path: String, timeout: TimeInterval?)] = []

        override func request<T: Decodable & Sendable>(
            _ url: URL, method: String = "GET", headers: [String: String] = [:],
            body: Data? = nil, timeout: TimeInterval? = nil
        ) async throws -> T {
            requested.append((url.path, timeout))
            guard let json = bodies[url.path] else { throw URLError(.timedOut) }
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        }
    }

    private let provider = "/tv.plex.providers.epg.xmltv:34"

    private func makeNetwork() -> StubNetwork {
        let network = StubNetwork()
        network.bodies["/livetv/dvrs"] = """
        {"MediaContainer":{"Dvr":[{"key":"34","lineup":"lineup://tv.plex.providers.epg.xmltv/x#My Guide"}]}}
        """
        return network
    }

    private func channels(_ network: StubNetwork) async throws -> [PlexLiveTVChannel] {
        try await network.getLiveTVChannels(serverURL: "http://plex.test", authToken: "t")
    }

    func test_channelsComeFromTheLineup_withoutAGridRequest() async throws {
        let network = makeNetwork()
        network.bodies["\(provider)/lineups/dvr/channels"] = """
        {"MediaContainer":{"Channel":[
          {"id":"6","gridKey":"6","vcn":"6","thumb":"http://logo/6","title":"FOX 6 WBRC","callSign":"WBRC"},
          {"id":"13","vcn":"13","title":"NBC 13 WVTM","callSign":"WVTM"}]}}
        """

        let result = try await channels(network)

        XCTAssertEqual(result.map(\.ratingKey), ["6", "13"])
        XCTAssertEqual(result[0].key, "\(provider)/metadata/6")
        XCTAssertEqual(result[0].channelNumber, "6")
        XCTAssertEqual(result[0].channelCallSign, "WBRC")
        XCTAssertEqual(result[0].thumb, "http://logo/6")
        // Same "<number> <name>" form the grid gives, so the name still strips.
        XCTAssertEqual(result[0].channelTitle, "6 FOX 6 WBRC")
        XCTAssertEqual(result[0].displayName, "FOX 6 WBRC")
        XCTAssertFalse(network.requested.contains { $0.path.hasSuffix("/grid") })
    }

    /// #771: the tune takes the grid's identifier, which an XMLTV lineup can give apart from `id`.
    func test_lineupChannel_isKeyedByItsGridKey() async throws {
        let network = makeNetwork()
        network.bodies["\(provider)/lineups/dvr/channels"] = """
        {"MediaContainer":{"Channel":[{"id":"www.PRO TV HD.co.un","gridKey":"12","vcn":"12","title":"PRO TV"}]}}
        """

        let result = try await channels(network)

        XCTAssertEqual(result.map(\.channelIdentifier), ["12"])
        XCTAssertEqual(result[0].key, "\(provider)/metadata/12")
    }

    func test_lineupFailure_fallsBackToTheGrid_withTheLongTimeout() async throws {
        let network = makeNetwork()
        network.bodies["\(provider)/grid"] = """
        {"MediaContainer":{"Metadata":[{"ratingKey":"p1","Media":[
          {"channelIdentifier":"6","channelTitle":"6 FOX 6 WBRC","channelVcn":"6","channelCallSign":"WBRC"}]}]}}
        """

        let result = try await channels(network)

        XCTAssertEqual(result.map(\.ratingKey), ["6"])
        XCTAssertEqual(result[0].displayName, "FOX 6 WBRC")
        let grid = network.requested.first { $0.path.hasSuffix("/grid") }
        XCTAssertEqual(grid?.timeout, PlexNetworkManager.guideTimeout)
    }

    func test_bothFailing_givesNoChannels() async throws {
        let result = try await channels(makeNetwork())
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Shared guide loads

    private func window(from start: TimeInterval, hours: Double) -> DateInterval {
        DateInterval(start: Date(timeIntervalSince1970: start), duration: hours * 3600)
    }

    func test_guideLoad_answersCallersThatArriveTogether() {
        let loading = window(from: 1_000_000, hours: 6)
        // The same six hours, read a few seconds later.
        XCTAssertTrue(LiveTVDataStore.epgWindow(loading, covers: window(from: 1_000_004, hours: 6)))
        // The guide's start, rounded down to the half hour.
        XCTAssertTrue(LiveTVDataStore.epgWindow(loading, covers: window(from: 1_000_000 - 29 * 60, hours: 6)))
        // A shorter window inside it.
        XCTAssertTrue(LiveTVDataStore.epgWindow(window(from: 1_000_000, hours: 12), covers: loading))
    }

    func test_guideLoad_doesNotAnswerALongerWindow() {
        let loading = window(from: 1_000_000, hours: 6)
        XCTAssertFalse(LiveTVDataStore.epgWindow(loading, covers: window(from: 1_000_000, hours: 12)))
        XCTAssertFalse(LiveTVDataStore.epgWindow(loading, covers: window(from: 1_000_000 - 3 * 3600, hours: 6)))
    }
}
