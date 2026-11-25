// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TMDBDirectAPI.swift
//  Rivulet
//
//  A proxy path as TMDB's own v3 request, for a self-build's own key, and the
//  details reply reshaped to what the proxy returns, so callers can't tell.
//  Only the paths the proxy serves are mapped.
//

import Foundation

nonisolated enum TMDBDirectAPI {
    nonisolated struct Route: Equatable {
        let path: String
        let query: [URLQueryItem]
        /// The reply goes through `foldDetails`.
        var foldsDetails = false
    }

    /// The v3 request for a proxy path ("tmdb/details/603" with `type=movie`); nil for a path the proxy doesn't serve.
    /// `type` (default movie) moves into the path; other parameters pass through.
    static func route(_ path: String, query: [URLQueryItem]) -> Route? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "tmdb" else { return nil }
        let id = parts[2]
        var params = query
        func take(_ name: String) -> String? {
            params.firstIndex { $0.name == name }.flatMap { params.remove(at: $0).value }
        }
        let type = take("type") ?? "movie"

        switch parts[1] {
        case "list":
            return Route(path: id == "trending" ? "/trending/\(type)/week" : "/\(type)/\(id)", query: params)
        case "details":
            let append = take("append") == "keywords" ? "credits,keywords" : "credits"
            return Route(path: "/\(type)/\(id)", query: params + [URLQueryItem(name: "append_to_response", value: append)],
                         foldsDetails: true)
        case "credits":
            return Route(path: "/\(type)/\(id)/credits", query: params)
        case "episode_credits":
            guard let season = take("season"), let episode = take("episode") else { return nil }
            return Route(path: "/tv/\(id)/season/\(season)/episode/\(episode)/credits", query: params)
        case "person":
            return Route(path: "/person/\(id)", query: params)
        case "images":
            return Route(path: "/\(type)/\(id)/images", query: params)
        case "find":
            guard let source = take("source") else { return nil }
            return Route(path: "/find/\(id)", query: [URLQueryItem(name: "external_source", value: source)] + params)
        case "discover":
            return Route(path: "/discover/\(id)", query: params)
        default:
            return nil
        }
    }

    /// The proxy's details (`flattenDetailsCredits`): the first 20 cast and the directors at the top
    /// level, and keywords as one flat list (v3 nests them as `keywords.keywords` for a film,
    /// `keywords.results` for a show).
    static func foldDetails(_ data: Data) -> Data {
        guard var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return data }
        if let credits = json.removeValue(forKey: "credits") as? [String: Any] {
            json["cast"] = Array(((credits["cast"] as? [Any]) ?? []).prefix(20))
            json["crew"] = ((credits["crew"] as? [[String: Any]]) ?? []).filter { $0["job"] as? String == "Director" }
        }
        if let keywords = json["keywords"] as? [String: Any] {
            json["keywords"] = keywords["keywords"] ?? keywords["results"] ?? [Any]()
        }
        return (try? JSONSerialization.data(withJSONObject: json)) ?? data
    }
}
