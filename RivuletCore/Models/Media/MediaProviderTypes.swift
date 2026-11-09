// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaProviderTypes.swift
//  Rivulet
//
//  Shared enums for the MediaProvider protocol surface.
//

import Foundation

enum MediaProviderKind: String, Sendable, Hashable, Codable, CaseIterable {
    case plex
    case jellyfin
    case emby
}

enum ConnectionState: Sendable, Hashable {
    case connected
    case unreachable
    case unauthorized
}

nonisolated enum MediaProviderError: Error, Sendable {
    case unreachable
    case unauthorized
    case notFound
    case transcodeRequired
    case notPlayable
    case backendSpecific(underlying: String)
}

extension MediaProviderError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unreachable: String(localized: "Couldn't reach the server.")
        case .unauthorized: String(localized: "The server didn't accept the sign-in.")
        case .notFound: String(localized: "The server doesn't have that.")
        default: nil
        }
    }
}

extension MediaProviderKind {
    /// The kind a provider id names ("jellyfin:<serverID>"), nil for any other id.
    nonisolated init?(providerID: String) {
        guard let colon = providerID.firstIndex(of: ":"),
              let kind = Self(rawValue: String(providerID[..<colon])) else { return nil }
        self = kind
    }

    /// The servers beside the selected Plex one, in the order Home and the sidebar list them.
    static let otherServerKinds = allCases.filter { $0 != .plex }

    /// The server type as a source badge shows it.
    var displayName: String {
        switch self {
        case .plex: "Plex"
        case .jellyfin: "Jellyfin"
        case .emby: "Emby"
        }
    }
}
