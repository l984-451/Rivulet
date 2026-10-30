// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

nonisolated struct SiloPageInfo: Decodable, Sendable {
    let hasMore: Bool
    let nextCursor: String?
}

nonisolated struct SiloList<Element: Decodable & Sendable>: Decodable, Sendable {
    let items: [Element]
    let page: SiloPageInfo?
}

nonisolated struct SiloCatalogPage: Decodable, Sendable {
    let items: [SiloItem]
    let total: Int
    let totalExact: Bool
    let windowCursor: String
    let page: SiloPageInfo?
}

nonisolated struct SiloLibrary: Decodable, Sendable {
    let id: String
    let name: String
    let type: String
    let sortOrder: Int
}

nonisolated struct SiloSectionLayout: Decodable, Sendable {
    let sections: [SiloSectionEntry]
}

nonisolated struct SiloSectionEntry: Decodable, Sendable {
    let id: String
    let sectionType: String
    let title: String
    let featured: Bool
    let itemLimit: Int
}

nonisolated struct SiloRecommendationRow: Decodable, Sendable {
    let type: String
    let title: String
    let items: [SiloItem]
}

/// A route contains only API identity, never an expiring artwork or stream URL.
nonisolated struct SiloHubRoute: Codable, Sendable {
    let scope: String
    var sectionId: String? = nil
    var libraryId: String? = nil

    func identifier(suffix: String = "") throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encoded = try encoder.encode(self).base64EncodedString()
        return "siloHub|\(encoded)|.\(suffix)"
    }

    static func decode(_ identifier: String) throws -> Self {
        let parts = identifier.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "siloHub", let data = Data(base64Encoded: String(parts[1])) else {
            throw MediaProviderError.notFound
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

nonisolated struct SiloCuratedCollections: Decodable, Sendable {
    let collections: [SiloCollection]
}

/// Both curated and personal collections retain their native kind and creator.
/// They are read-only collection surfaces, not editable video playlists.
nonisolated struct SiloCollection: Decodable, Sendable {
    let id: String
    let libraryId: String?
    let title: String?
    let name: String?
    let description: String?
    let posterUrl: String?
    let backdropUrl: String?
    let itemCount: Int
    let collectionType: String
    let creatorProfileId: String?
    let isShared: Bool?
}

nonisolated struct SiloCollectionRef: Codable, Sendable {
    let collectionId: String
    let libraryId: String?

    var itemID: String {
        let collection = Data(collectionId.utf8).base64EncodedString()
        let library = libraryId.map { Data($0.utf8).base64EncodedString() } ?? ""
        return "siloCollection|\(collection)|\(library)"
    }

    static func decode(_ value: String) throws -> Self {
        let parts = value.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "siloCollection",
              let collectionData = Data(base64Encoded: String(parts[1])),
              let collection = String(data: collectionData, encoding: .utf8), !collection.isEmpty,
              let libraryData = Data(base64Encoded: String(parts[2])),
              let library = String(data: libraryData, encoding: .utf8) else { throw MediaProviderError.notFound }
        return Self(collectionId: collection, libraryId: library.isEmpty ? nil : library)
    }
}

nonisolated struct SiloMembership: Decodable, Sendable {
    let isMember: Bool
}

nonisolated struct SiloSearchCapabilities: Decodable, Sendable {
    let videoWithEpisodesScope: Bool?
}

nonisolated struct SiloRequestStatus: Decodable, Sendable {
    let watchlistTitlesSupported: Bool
}

nonisolated struct SiloWatchlistTitle: Decodable, Sendable {
    let mediaType: String
    let tmdbId: Int
    let title: String
    let year: Int?
    let releaseDate: String?
    let contentRating: String?
    let posterPath: String?
    let addedAt: String
    let status: String
    let voteAverage: Double?
}
