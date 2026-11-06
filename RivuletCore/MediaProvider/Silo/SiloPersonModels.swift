// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// The ID belongs to the native Silo people namespace. External metadata IDs are
/// deliberately absent so callers cannot mistake one for a Plex or TMDB key.
nonisolated struct SiloPerson: Decodable, Sendable {
    let id: String
    let name: String
    let bio: String?
    let birthDate: String?
    let deathDate: String?
    let birthplace: String?
    let photoUrl: String?
    let photoThumbhash: String?
}

nonisolated struct SiloPeopleCapability: Decodable, Sendable {
    let state: String
    let allowed: Bool
    let peopleMediaScope: Bool?
    let videoWithEpisodesScope: Bool?

    var isAvailable: Bool { allowed && state == "available" && peopleMediaScope == true }
}

nonisolated struct SiloPersonCreditPage: Sendable {
    let items: [SiloItem]
    let libraryID: String?
    let total: Int
    let totalExact: Bool
    let nextCursor: String?
}

nonisolated enum SiloPeopleError: Error {
    case unavailable
    case staleAuthority
    case invalidScope
    case invalidPage
}
