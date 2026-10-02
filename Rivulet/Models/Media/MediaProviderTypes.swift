// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaProviderTypes.swift
//  Rivulet
//
//  Shared enums for the MediaProvider protocol surface.
//

import Foundation

enum MediaProviderKind: String, Sendable, Hashable, Codable {
    case plex
    case jellyfin
}

enum ConnectionState: Sendable, Hashable {
    case connected
    case unreachable
    case unauthorized
}

enum MediaProviderError: Error, Sendable {
    case unreachable
    case unauthorized
    case notFound
    case transcodeRequired
    case notPlayable
    case backendSpecific(underlying: String)
}

extension MediaProviderKind {
    /// The server type as a source badge shows it.
    var displayName: String {
        switch self {
        case .plex: "Plex"
        case .jellyfin: "Jellyfin"
        }
    }
}
