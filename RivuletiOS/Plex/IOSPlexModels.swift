// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

nonisolated enum IOSPlexAPIIdentity {
    static let product = "Rivulet"
    static let platform = "iOS"
    static let device = "iPhone"

    static let clientIdentifier: String = {
        let key = "plexClientIdentifier"
        if let value = UserDefaults.standard.string(forKey: key), !value.isEmpty { return value }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }()
}

nonisolated struct IOSPlexConnection: Codable, Hashable, Sendable {
    let uri: String
    let local: Bool?
    let relay: Bool?
    let protocolType: String?

    enum CodingKeys: String, CodingKey {
        case uri, local, relay
        case protocolType = "protocol"
    }
}

nonisolated struct IOSPlexServer: Codable, Identifiable, Hashable, Sendable {
    var id: String { clientIdentifier }
    let name: String
    let clientIdentifier: String
    let provides: String
    let accessToken: String?
    let owned: Bool?
    let presence: Bool?
    let connections: [IOSPlexConnection]?
}

/// The currently authenticated Plex account returned by `/api/v2/user`.
nonisolated struct IOSPlexUserProfile: Codable, Hashable, Sendable {
    let username: String?
    let friendlyName: String?
    let title: String?
    let thumb: String?

    var displayName: String? {
        friendlyName ?? title ?? username
    }
}

nonisolated struct IOSPlexLibrary: Codable, Identifiable, Hashable, Sendable {
    var id: String { key }
    let key: String
    let type: String
    let title: String

    var icon: String {
        switch type {
        case "movie": "film.stack"
        case "show": "tv"
        case "artist": "music.note.list"
        default: "rectangle.stack"
        }
    }
}

nonisolated struct IOSPlexGuid: Codable, Hashable, Sendable {
    let id: String?
}

/// Plex artwork descriptor returned by full metadata endpoints. In
/// particular, `clearLogo` entries are transparent show/movie title art.
nonisolated struct IOSPlexImage: Codable, Hashable, Sendable {
    let alt: String?
    let type: String?
    let url: String?
}

nonisolated struct IOSPlexMarker: Codable, Identifiable, Hashable, Sendable {
    let id: Int?
    let type: String?
    let startTimeOffset: Int?
    let endTimeOffset: Int?

    var stableID: String { "\(type ?? "marker")-\(id ?? startTimeOffset ?? 0)" }
    var start: TimeInterval { TimeInterval(startTimeOffset ?? 0) / 1000 }
    var end: TimeInterval { TimeInterval(endTimeOffset ?? 0) / 1000 }
    var isCommunity: Bool { (id ?? 0) < 0 }

    var displayName: String {
        switch type {
        case "intro": "Intro"
        case "recap": "Recap"
        case "credits": "Credits"
        case "commercial": "Commercial"
        default: "Segment"
        }
    }
}

nonisolated struct IOSPlexPart: Codable, Hashable, Sendable {
    let key: String?
    let file: String?
    let duration: Int?
    let container: String?
}

nonisolated struct IOSPlexMedia: Codable, Hashable, Sendable {
    let container: String?
    let videoCodec: String?
    let audioCodec: String?
    let videoResolution: String?
    let Part: [IOSPlexPart]?
}

nonisolated struct IOSPlexItem: Codable, Identifiable, Hashable, Sendable {
    var id: String { ratingKey ?? key ?? title ?? UUID().uuidString }
    let ratingKey: String?
    let key: String?
    let type: String?
    let title: String?
    let summary: String?
    let year: Int?
    let contentRating: String?
    let rating: Double?
    let thumb: String?
    let art: String?
    let grandparentArt: String?
    let duration: Int?
    let viewOffset: Int?
    let viewCount: Int?
    let index: Int?
    let parentIndex: Int?
    let parentRatingKey: String?
    let parentGuid: String?
    let parentTitle: String?
    let grandparentRatingKey: String?
    let grandparentGuid: String?
    let grandparentTitle: String?
    let Image: [IOSPlexImage]?
    let Guid: [IOSPlexGuid]?
    let Marker: [IOSPlexMarker]?
    let Media: [IOSPlexMedia]?

    var displayTitle: String { title ?? "Untitled" }
    var isPlayable: Bool { type == "movie" || type == "episode" || type == "clip" }
    var isContainer: Bool { type == "show" || type == "season" }
    var durationSeconds: TimeInterval { TimeInterval(duration ?? 0) / 1000 }
    var resumeSeconds: TimeInterval { TimeInterval(viewOffset ?? 0) / 1000 }
    var partKey: String? { Media?.first?.Part?.first?.key }
    var clearLogoPath: String? {
        Image?.first(where: { $0.type == "clearLogo" })?.url
    }

    var subtitle: String? {
        if type == "episode" {
            let code = [parentIndex, index].compactMap { $0 }.map(String.init)
            let prefix = code.count == 2 ? "S\(code[0]) E\(code[1])" : nil
            return [prefix, grandparentTitle].compactMap { $0 }.joined(separator: " · ")
        }
        return year.map(String.init)
    }

    var imdbID: String? {
        let candidates = [grandparentGuid, parentGuid].compactMap { $0 }
            + (Guid ?? []).compactMap(\.id)
            + [key].compactMap { $0 }
        guard let value = candidates.first(where: { $0.contains("imdb://") }) else { return nil }
        return value.components(separatedBy: "imdb://").last?.components(separatedBy: "?").first
    }
}

nonisolated struct IOSPlexShelf: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let items: [IOSPlexItem]

    var isContinueWatching: Bool {
        title.localizedCaseInsensitiveContains("continue watching")
    }

    var isOnDeck: Bool {
        title.localizedCaseInsensitiveContains("on deck")
    }
}

nonisolated struct IOSPlexLibraryResponse: Decodable, Sendable {
    struct Container: Decodable, Sendable { let Directory: [IOSPlexLibrary]? }
    let MediaContainer: Container
}

nonisolated struct IOSPlexMetadataResponse: Decodable, Sendable {
    struct Container: Decodable, Sendable { let Metadata: [IOSPlexItem]? }
    let MediaContainer: Container
}

nonisolated struct IOSPlexHubResponse: Decodable, Sendable {
    struct Hub: Decodable, Sendable {
        let hubIdentifier: String?
        let title: String?
        let Metadata: [IOSPlexItem]?
    }
    struct Container: Decodable, Sendable { let Hub: [Hub]? }
    let MediaContainer: Container
}
