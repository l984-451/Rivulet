// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TMDBTransport.swift
//  Rivulet
//
//  The one way to reach TMDB. Callers name a proxy path ("tmdb/details/603",
//  `type=movie`) and get the proxy's JSON back: from the App-Attested proxy, or,
//  in a self-build with its own key (`TMDBCredential.bundled`), from TMDB's v3 API,
//  reshaped to match (`TMDBDirectAPI`). Each caller keeps its own session.
//

import Foundation
import Synchronization

nonisolated enum TMDBTransport {
    /// The JSON for a proxy `path`; throws on a non-2xx answer. A `baseURL` other than
    /// the proxy (tests) always goes to that base, key or not.
    static func data(
        _ path: String,
        query: [URLQueryItem],
        session: URLSession,
        baseURL: URL = TMDBConfig.proxyBaseURL,
        credential: TMDBCredential? = TMDBCredential.bundled
    ) async throws -> Data {
        guard baseURL == TMDBConfig.proxyBaseURL, let credential else {
            let request = try proxyRequest(path, query: query, baseURL: baseURL)
            let (data, response) = try await session.attestedData(for: request)
            return try succeeded(data, response)
        }
        // A path the proxy doesn't serve fails rather than falling back to the proxy.
        guard let route = TMDBDirectAPI.route(path, query: query),
              let request = credential.request(route.path, query: route.query) else {
            throw URLError(.unsupportedURL)
        }
        let (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401, refusalLogged.exchange(true, ordering: .relaxed) == false {
            DiagLog.error(.network, "TMDB refused the built-in key")
        }
        let body = try succeeded(data, response)
        return route.foldsDetails ? TMDBDirectAPI.foldDetails(body) : body
    }

    /// The proxy request for `path`, as the callers have always sent it.
    static func proxyRequest(_ path: String, query: [URLQueryItem], baseURL: URL = TMDBConfig.proxyBaseURL) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw URLError(.badURL)
        }
        // Set even when empty, which leaves a trailing "?": App Attest signs the query as sent.
        components.queryItems = query
        guard let finalURL = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: finalURL)
        request.httpMethod = "GET"
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static let refusalLogged = Atomic(false)

    private static func succeeded(_ data: Data, _ response: URLResponse) throws -> Data {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
