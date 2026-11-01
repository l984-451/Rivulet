// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexErrorMapping.swift
//  Rivulet
//
//  Convert Plex/URLError throws into MediaProviderError so callers above the
//  protocol see a consistent error surface.
//

import Foundation

extension MediaProviderError {
    static func mapping(_ error: Error) -> MediaProviderError {
        if let plexErr = error as? PlexAPIError {
            switch plexErr {
            case .invalidURL: return .backendSpecific(underlying: String(localized: "Plex URL malformed"))
            case .invalidResponse: return .backendSpecific(underlying: String(localized: "Plex returned an invalid response"))
            case .httpError(let statusCode, _):
                if statusCode == 401 || statusCode == 403 { return .unauthorized }
                if statusCode == 404 { return .notFound }
                return .backendSpecific(underlying: String(localized: "Plex HTTP \(statusCode)"))
            case .parsingError: return .backendSpecific(underlying: String(localized: "Plex response unparseable"))
            case .authenticationFailed: return .unauthorized
            case .notFound: return .notFound
            case .networkError(let inner): return .mapping(inner)
            }
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorTimedOut,
                 NSURLErrorNetworkConnectionLost:
                return .unreachable
            case NSURLErrorUserAuthenticationRequired:
                return .unauthorized
            default:
                return .backendSpecific(underlying: ns.localizedDescription)
            }
        }
        return .backendSpecific(underlying: ns.localizedDescription)
    }
}

/// Wrap an async throwing call so any thrown error becomes a MediaProviderError.
/// Provider methods use this so callers above the protocol get consistent errors.
func plexCall<T: Sendable>(_ body: () async throws -> T) async throws -> T {
    do {
        return try await body()
    } catch {
        throw MediaProviderError.mapping(error)
    }
}
