// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TMDBCredential.swift
//  Rivulet
//
//  A self-builder's own TMDB key. A build from source can't pass App Attest, so the
//  proxy refuses it; `Scripts/enthusiast-build.py --tmdb-key` writes the key to the
//  gitignored `TMDBKey.txt` beside this folder's config, and `TMDBTransport` then asks
//  TMDB directly. App Store builds never carry the file.
//

import Foundation

nonisolated enum TMDBCredential: Equatable, Sendable {
    /// The API Read Access Token, sent as `Authorization: Bearer`.
    case readAccessToken(String)
    /// The API key, sent as the `api_key` parameter.
    case apiKey(String)

    /// Either form as pasted from themoviedb.org; nil for anything else.
    init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.range(of: #"^[0-9A-Fa-f]{32}$"#, options: .regularExpression) != nil {
            self = .apiKey(text)
        } else if text.range(of: #"^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil {
            self = .readAccessToken(text)
        } else {
            return nil
        }
    }

    /// A GET on TMDB's v3 API (`path` like "/movie/popular") carrying this credential.
    func request(_ path: String, query: [URLQueryItem] = []) -> URLRequest? {
        var items = query
        if case .apiKey(let key) = self { items.append(URLQueryItem(name: "api_key", value: key)) }
        guard var components = URLComponents(string: TMDBConfig.apiBaseURL.absoluteString + path) else { return nil }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if case .readAccessToken(let token) = self { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// The key built into this copy of the app; nil for every App Store build.
    static let bundled: TMDBCredential? = Bundle.main.url(forResource: "TMDBKey", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        .flatMap(TMDBCredential.init)
}
