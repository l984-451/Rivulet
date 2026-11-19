// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TMDBCredential.swift
//  Rivulet
//
//  The user's own TMDB key. A build from source can't pass App Attest, so the
//  proxy refuses it; with a key saved, `TMDBTransport` asks TMDB directly.
//  Stored in the Keychain, never synced, logged or shown. An API key rides the
//  URL (`api_key`), so the app's own URL cache can hold it too; a Read Access
//  Token rides the Authorization header.
//

import Foundation
import Synchronization

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

    private var secret: String {
        switch self {
        case .readAccessToken(let secret), .apiKey(let secret): secret
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

    /// One cheap call that only succeeds with a working credential.
    func verify(session: URLSession) async throws(TMDBCredentialError) {
        guard let request = request("/authentication") else { throw .notACredential }
        let response: URLResponse
        do { (_, response) = try await session.data(for: request) } catch { throw .unreachable }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200...299: return
        case 401: throw .refused
        default: throw .unreachable
        }
    }

    // MARK: - Saved

    private static let keychainKey = "tmdbCredential"
    /// Read on every TMDB request, so the Keychain is read once and mirrored here.
    private static let stored = Mutex(KeychainHelper.get(keychainKey).flatMap(TMDBCredential.init))

    static var saved: TMDBCredential? { stored.withLock { $0 } }

    /// Parses `text`, checks it with TMDB, then saves it. Nothing is saved on failure.
    @discardableResult
    static func saveVerified(_ text: String, session: URLSession = .shared) async throws(TMDBCredentialError) -> TMDBCredential {
        guard let credential = TMDBCredential(text) else { throw .notACredential }
        try await credential.verify(session: session)
        guard KeychainHelper.set(credential.secret, forKey: keychainKey) else { throw .notSaved }
        stored.withLock { $0 = credential }
        return credential
    }

    static func remove() {
        KeychainHelper.delete(keychainKey)
        stored.withLock { $0 = nil }
    }
}

nonisolated enum TMDBCredentialError: LocalizedError, Equatable {
    case notACredential, refused, unreachable, notSaved

    var errorDescription: String? {
        switch self {
        case .notACredential: String(localized: "That isn't a TMDB API key or Read Access Token.")
        case .refused: String(localized: "TMDB didn't accept this key.")
        case .unreachable: String(localized: "Couldn't reach TMDB. Try again.")
        case .notSaved: String(localized: "Couldn't save the key. Try again.")
        }
    }
}
