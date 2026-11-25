// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TMDBTransportTests.swift
//  RivuletTests
//
//  A self-build's own TMDB key: how it is read and applied, how each proxy path maps
//  to TMDB's v3 API, and that requests without a key are what they always were.
//  Every test passes its credential explicitly.
//

import XCTest
@testable import Rivulet

private typealias Route = TMDBDirectAPI.Route

final class TMDBTransportTests: XCTestCase {
    private let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJ4In0.c2ln_bmF0-dXJl"
    private let hex = "0123456789abcdef0123456789abcdef"
    private var token: TMDBCredential { .readAccessToken(jwt) }
    private var key: TMDBCredential { .apiKey(hex) }

    override func setUp() {
        super.setUp()
        RecordingURLProtocol.reset()
    }

    // MARK: - Reading a pasted credential

    func testHexIsAnAPIKeyInEitherCase() {
        XCTAssertEqual(TMDBCredential(hex), .apiKey(hex))
        XCTAssertEqual(TMDBCredential(hex.uppercased()), .apiKey(hex.uppercased()))
    }

    func testJWTIsAReadAccessToken() {
        XCTAssertEqual(TMDBCredential(jwt), .readAccessToken(jwt))
    }

    func testPastedWhitespaceIsTrimmed() {
        XCTAssertEqual(TMDBCredential("  \(hex)\n"), .apiKey(hex))
        XCTAssertEqual(TMDBCredential("\t\(jwt) "), .readAccessToken(jwt))
    }

    func testAnythingElseIsRejected() {
        let rejected = ["", "  ", String(hex.dropLast()), hex + "a", String(hex.dropLast()) + "g",
                        "abc.def", "a.b.c.d", "eyJ.a b.c", "Bearer \(jwt)"]
        for text in rejected {
            XCTAssertNil(TMDBCredential(text), text)
        }
    }

    // MARK: - Applying it

    func testTokenRidesTheBearerHeaderOnly() throws {
        let request = try XCTUnwrap(token.request("/movie/popular"))
        XCTAssertEqual(request.url?.absoluteString, "https://api.themoviedb.org/3/movie/popular")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(jwt)")
    }

    func testKeyRidesTheQueryOnly() throws {
        let request = try XCTUnwrap(key.request("/movie/popular", query: [q("page", "2")]))
        XCTAssertEqual(request.url?.absoluteString, "https://api.themoviedb.org/3/movie/popular?page=2&api_key=\(hex)")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - Proxy paths on v3

    func testListPaths() {
        XCTAssertEqual(route("tmdb/list/popular", [q("type", "tv")]), Route(path: "/tv/popular", query: []))
        XCTAssertEqual(route("tmdb/list/now_playing", []), Route(path: "/movie/now_playing", query: []))
        XCTAssertEqual(route("tmdb/list/trending", [q("type", "tv")]), Route(path: "/trending/tv/week", query: []))
    }

    func testDetailsAppendCreditsAndAskedForKeywords() {
        XCTAssertEqual(route("tmdb/details/603", [q("type", "movie"), q("append", "keywords")]),
                       Route(path: "/movie/603", query: [q("append_to_response", "credits,keywords")], foldsDetails: true))
        XCTAssertEqual(route("tmdb/details/1399", [q("type", "tv")]),
                       Route(path: "/tv/1399", query: [q("append_to_response", "credits")], foldsDetails: true))
    }

    func testPerTitlePaths() {
        XCTAssertEqual(route("tmdb/credits/1399", [q("type", "tv")]), Route(path: "/tv/1399/credits", query: []))
        XCTAssertEqual(route("tmdb/episode_credits/1399", [q("season", "2"), q("episode", "5")]),
                       Route(path: "/tv/1399/season/2/episode/5/credits", query: []))
        XCTAssertEqual(route("tmdb/person/6384", []), Route(path: "/person/6384", query: []))
        XCTAssertEqual(route("tmdb/images/603", [q("type", "movie")]), Route(path: "/movie/603/images", query: []))
        XCTAssertEqual(route("tmdb/find/tt0944947", [q("source", "imdb_id")]),
                       Route(path: "/find/tt0944947", query: [q("external_source", "imdb_id")]))
    }

    func testDiscoverPassesItsFilters() {
        let filters = [q("with_genres", "28|12"), q("with_keywords", "9715"), q("sort_by", "popularity.desc")]
        XCTAssertEqual(route("tmdb/discover/movie", [q("type", "movie")] + filters), Route(path: "/discover/movie", query: filters))
    }

    func testUnservedPathsHaveNoRoute() {
        XCTAssertNil(route("tmdb/recommendations/603", [q("type", "movie")]))
        XCTAssertNil(route("tmdb/season/1399/1", []))
        XCTAssertNil(route("tmdb/episode_credits/1399", [q("season", "1")]))
        XCTAssertNil(route("tmdb/find/tt0944947", []))
        XCTAssertNil(route("v3/list/popular", []))
    }

    // MARK: - Reshaping details

    func testDetailsLiftCreditsAndFlattenMovieKeywords() throws {
        let v3 = #"{"id":603,"credits":{"cast":[{"name":"Keanu Reeves"}],"crew":[{"name":"Lana Wachowski","job":"Director"},{"name":"Bill Pope","job":"Director of Photography"}]},"keywords":{"keywords":[{"id":1,"name":"hacker"}]}}"#
        let json = try object(TMDBDirectAPI.foldDetails(Data(v3.utf8)))
        XCTAssertNil(json["credits"])
        XCTAssertEqual(names(json["cast"]), ["Keanu Reeves"])
        XCTAssertEqual(names(json["crew"]), ["Lana Wachowski"])
        XCTAssertEqual(names(json["keywords"]), ["hacker"])
        XCTAssertEqual(json["id"] as? Int, 603)
    }

    func testDetailsFlattenTVKeywords() throws {
        let v3 = #"{"id":1399,"credits":{"cast":[],"crew":[]},"keywords":{"results":[{"id":2,"name":"dragon"}]}}"#
        let json = try object(TMDBDirectAPI.foldDetails(Data(v3.utf8)))
        XCTAssertEqual(names(json["keywords"]), ["dragon"])
        XCTAssertEqual(names(json["cast"]), [])
    }

    /// The proxy keeps the first 20 cast.
    func testDetailsKeepTheFirstTwentyCast() throws {
        let cast = (1...30).map { #"{"name":"\#($0)"}"# }.joined(separator: ",")
        let v3 = #"{"id":1,"credits":{"cast":[\#(cast)],"crew":[]}}"#
        let json = try object(TMDBDirectAPI.foldDetails(Data(v3.utf8)))
        XCTAssertEqual(names(json["cast"]), (1...20).map(String.init))
    }

    // MARK: - Routing

    func testProxyRequestsAreUnchanged() throws {
        let list = try TMDBTransport.proxyRequest("tmdb/list/popular", query: [q("type", "movie")])
        XCTAssertEqual(list.url?.absoluteString, "https://tmdb.gurleystudios.com/tmdb/list/popular?type=movie")
        XCTAssertEqual(list.httpMethod, "GET")
        XCTAssertEqual(list.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(list.value(forHTTPHeaderField: "Authorization"))
        // An empty query still leaves its "?": App Attest signs the URL as sent.
        XCTAssertEqual(try TMDBTransport.proxyRequest("tmdb/person/6384", query: []).url?.absoluteString,
                       "https://tmdb.gurleystudios.com/tmdb/person/6384?")
    }

    func testWithoutKeyAsksTheProxy() async throws {
        _ = try await TMDBTransport.data("tmdb/list/popular", query: [q("type", "movie")],
                                         session: RecordingURLProtocol.session(), credential: nil)
        let sent = try XCTUnwrap(RecordingURLProtocol.requests.last)
        XCTAssertEqual(sent.url?.absoluteString, "https://tmdb.gurleystudios.com/tmdb/list/popular?type=movie")
        XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"))
    }

    func testWithTokenAsksTMDBAndReshapesDetails() async throws {
        RecordingURLProtocol.body = Data(#"{"id":603,"credits":{"cast":[{"name":"Keanu Reeves"}],"crew":[]}}"#.utf8)
        let data = try await TMDBTransport.data("tmdb/details/603", query: [q("type", "movie")],
                                                session: RecordingURLProtocol.session(), credential: token)
        let sent = try XCTUnwrap(RecordingURLProtocol.requests.last)
        XCTAssertEqual(sent.url?.absoluteString, "https://api.themoviedb.org/3/movie/603?append_to_response=credits")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer \(jwt)")
        let json = try object(data)
        XCTAssertNil(json["credits"])
        XCTAssertEqual(names(json["cast"]), ["Keanu Reeves"])
    }

    func testWithAPIKeyTheKeyRidesTheQuery() async throws {
        _ = try await TMDBTransport.data("tmdb/find/tt0944947", query: [q("source", "imdb_id")],
                                         session: RecordingURLProtocol.session(), credential: key)
        let sent = try XCTUnwrap(RecordingURLProtocol.requests.last)
        XCTAssertEqual(sent.url?.absoluteString,
                       "https://api.themoviedb.org/3/find/tt0944947?external_source=imdb_id&api_key=\(hex)")
        XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"))
    }

    func testWithKeyAnUnservedPathFailsWithoutAsking() async {
        do {
            _ = try await TMDBTransport.data("tmdb/recommendations/603", query: [q("type", "movie")],
                                             session: RecordingURLProtocol.session(), credential: token)
            XCTFail("an unserved path must not fall back to the proxy")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .unsupportedURL)
        }
        XCTAssertTrue(RecordingURLProtocol.requests.isEmpty)
    }

    func testWithKeyAFailedAnswerThrows() async {
        RecordingURLProtocol.status = 404
        do {
            _ = try await TMDBTransport.data("tmdb/person/1", query: [], session: RecordingURLProtocol.session(), credential: token)
            XCTFail("a 404 must throw")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .badServerResponse)
        }
    }

    func testAnotherBaseIgnoresTheKey() async throws {
        _ = try await TMDBTransport.data("tmdb/list/popular", query: [q("type", "movie")],
                                         session: RecordingURLProtocol.session(),
                                         baseURL: URL(string: "https://example.test")!, credential: token)
        let sent = try XCTUnwrap(RecordingURLProtocol.requests.last)
        XCTAssertEqual(sent.url?.absoluteString, "https://example.test/tmdb/list/popular?type=movie")
        XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - Helpers

    private func q(_ name: String, _ value: String) -> URLQueryItem { URLQueryItem(name: name, value: value) }

    private func route(_ path: String, _ query: [URLQueryItem]) -> TMDBDirectAPI.Route? {
        TMDBDirectAPI.route(path, query: query)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func names(_ value: Any?) -> [String]? {
        (value as? [[String: Any]])?.compactMap { $0["name"] as? String }
    }
}

/// Records every request and answers with `status` and `body`, or fails with `failure`.
private final class RecordingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data("{}".utf8)
    nonisolated(unsafe) static var failure: Error?

    static func reset() {
        requests = []
        status = 200
        body = Data("{}".utf8)
        failure = nil
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
