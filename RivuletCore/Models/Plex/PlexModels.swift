// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexModels.swift
//  Rivulet
//
//  Ported from plex_watchOS - Models.swift
//  Original created by Bain Gurley on 4/19/24.
//

import Foundation

// MARK: - Plex API Configuration

/// Plex API constants
enum PlexAPI: Sendable {
    static let baseUrl = "https://plex.tv"
    static let productName = "Rivulet"

    /// Host-injected, defaulting to the tvOS app's values. The iOS app
    /// overrides both at launch (RivuletiOSApp.init), before any request is
    /// built. Injection rather than `#if os(...)` because shared code carries
    /// no platform conditionals (CLAUDE.md, Platform Boundary), and rather
    /// than `UIDevice.systemName` because that reports "iPadOS" on some iPad
    /// versions and "iOS" on others — Plex would see one app as two platforms.
    static var deviceName = "Apple TV"
    static var platform = "tvOS"

    /// Per-install UUID generated on first launch and persisted in UserDefaults.
    /// Plex uses this to distinguish devices in its Dashboard, attribute transcode
    /// sessions, and route /player control messages — sharing one identifier across
    /// devices causes Dashboard merges and cross-device transcode session collisions.
    static let clientIdentifier: String = {
        let key = "plexClientIdentifier"
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: key), !stored.isEmpty {
            return stored
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: key)
        return generated
    }()
}

// MARK: - Server/Device Models

nonisolated struct PlexDevice: Codable, Sendable {
    let name: String
    let product: String
    let productVersion: String
    let platform: String?
    let platformVersion: String?
    let device: String?
    let clientIdentifier: String
    let createdAt: String
    let lastSeenAt: String
    let provides: String
    let ownerId: String?
    let sourceTitle: String?
    let publicAddress: String?
    let accessToken: String?
    let owned: Bool?
    let home: Bool?
    let synced: Bool?
    let relay: Bool?
    let presence: Bool?
    let httpsRequired: Bool?
    let publicAddressMatches: Bool?
    let dnsRebindingProtection: Bool?
    let natLoopbackSupported: Bool?
    let connections: [PlexConnection]?

    /// Stable Plex server identity (machineIdentifier). Mirrors `clientIdentifier`
    /// from /api/v2/resources; used for provider IDs and last-known-good matching.
    /// NOT the plex.direct subdomain hash — that lives in each connection's `uri`.
    var machineIdentifier: String?

    enum CodingKeys: String, CodingKey {
        case name, product, productVersion, platform, platformVersion, device
        case clientIdentifier, createdAt, lastSeenAt, provides, ownerId
        case sourceTitle, publicAddress, accessToken, owned, home, synced
        case relay, presence, httpsRequired, publicAddressMatches
        case dnsRebindingProtection, natLoopbackSupported, connections
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        product = try container.decode(String.self, forKey: .product)
        productVersion = try container.decode(String.self, forKey: .productVersion)
        platform = try container.decodeIfPresent(String.self, forKey: .platform)
        platformVersion = try container.decodeIfPresent(String.self, forKey: .platformVersion)
        device = try container.decodeIfPresent(String.self, forKey: .device)
        clientIdentifier = try container.decode(String.self, forKey: .clientIdentifier)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        lastSeenAt = try container.decode(String.self, forKey: .lastSeenAt)
        provides = try container.decode(String.self, forKey: .provides)

        // Handle ownerId as either String or Int
        if let ownerIdString = try? container.decode(String.self, forKey: .ownerId) {
            ownerId = ownerIdString
        } else if let ownerIdInt = try? container.decode(Int.self, forKey: .ownerId) {
            ownerId = String(ownerIdInt)
        } else {
            ownerId = nil
        }

        sourceTitle = try container.decodeIfPresent(String.self, forKey: .sourceTitle)
        publicAddress = try container.decodeIfPresent(String.self, forKey: .publicAddress)
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
        owned = try container.decodeIfPresent(Bool.self, forKey: .owned)
        home = try container.decodeIfPresent(Bool.self, forKey: .home)
        synced = try container.decodeIfPresent(Bool.self, forKey: .synced)
        relay = try container.decodeIfPresent(Bool.self, forKey: .relay)
        presence = try container.decodeIfPresent(Bool.self, forKey: .presence)
        httpsRequired = try container.decodeIfPresent(Bool.self, forKey: .httpsRequired)
        publicAddressMatches = try container.decodeIfPresent(Bool.self, forKey: .publicAddressMatches)
        dnsRebindingProtection = try container.decodeIfPresent(Bool.self, forKey: .dnsRebindingProtection)
        natLoopbackSupported = try container.decodeIfPresent(Bool.self, forKey: .natLoopbackSupported)
        connections = try container.decodeIfPresent([PlexConnection].self, forKey: .connections)

        // machineIdentifier mirrors clientIdentifier (the same value Plex returns
        // from /identity and pms/servers.xml), so no separate fetch is needed.
        machineIdentifier = clientIdentifier
    }
}

nonisolated struct PlexConnection: Codable, Sendable {
    let protocolType: String
    let address: String
    let port: Int
    let uri: String
    let local: Bool
    let relay: Bool
    let IPv6: Bool

    enum CodingKeys: String, CodingKey {
        case protocolType = "protocol"
        case address, port, uri, local, relay, IPv6
    }

    /// Full URL for this connection
    var fullURL: String {
        return uri
    }
}

// MARK: - Library Models

nonisolated struct PlexLibraryContainer: Codable, Sendable {
    let MediaContainer: PlexLibraryMediaContainer
}

nonisolated struct PlexLibraryMediaContainer: Codable, Sendable {
    let size: Int
    let title1: String?
    let Directory: [PlexLibrary]?
}

nonisolated struct PlexLibrary: Codable, Identifiable, Hashable, Sendable {
    var id: String { serverID.map { "\($0)/\(key)" } ?? key }
    let key: String
    let type: String          // "movie", "show", "artist", etc.
    var title: String
    // Optional: nothing reads them, and one section without them would
    // otherwise fail the whole list.
    let agent: String?
    let scanner: String?
    let language: String?
    let uuid: String
    let updatedAt: Int?
    let createdAt: Int?
    let scannedAt: Int?
    let Location: [PlexLibraryLocation]?

    /// The user's Plex pin state for this library, from `/library/sections`:
    /// 0 or absent pinned to Home, 1 hidden from Home, 2 hidden from Home and the
    /// sidebar. PMS 1.43.3: `hidden == 0` matches having a hub on Home exactly.
    var hidden: Int?

    /// The other Plex server this library is on (`PlexMetadata.serverID`); nil for the selected one.
    var serverID: String? = nil

    /// Whether the user pinned this library to their Plex home screen.
    var isPinnedToHome: Bool { (hidden ?? 0) == 0 }

    /// Check if this is a video library
    var isVideoLibrary: Bool {
        type == "movie" || type == "show"
    }

    /// Check if this is a music library
    var isMusicLibrary: Bool {
        type == "artist"
    }

    /// Movie/show section with no metadata agent: browsed by folder.
    var hasNoMetadataAgent: Bool {
        isVideoLibrary && (agent == "tv.plex.agents.none" || agent == "com.plexapp.agents.none")
    }

    /// Check if this is a photo library
    var isPhotoLibrary: Bool {
        type == "photo"
    }
}

nonisolated struct PlexLibraryLocation: Codable, Hashable, Sendable {
    let id: Int
    let path: String
}

// MARK: - Media Container (Generic Response Wrapper)

nonisolated struct PlexMediaContainer: Codable, Sendable {
    var size: Int?
    var totalSize: Int?  // Total items in collection (for pagination)
    var librarySectionID: Int?  // Library section ID (at container level)
    var librarySectionTitle: String?
    var Metadata: [PlexMetadata]?
    var Hub: [PlexHub]?
}

nonisolated struct PlexMediaContainerWrapper: Codable, Sendable {
    var MediaContainer: PlexMediaContainer
}

/// Container for extras API response
nonisolated struct PlexExtrasMediaContainer: Codable, Sendable {
    var size: Int?
    var Metadata: [PlexExtra]?
}

nonisolated struct PlexExtrasContainerWrapper: Codable, Sendable {
    var MediaContainer: PlexExtrasMediaContainer
}

// MARK: - Hub (for home screen sections)

nonisolated struct PlexHub: Codable, Identifiable, Hashable, Sendable {
    var id: String {
        let id = hubIdentifier ?? title ?? UUID().uuidString
        return serverID.map { "\($0)/\(id)" } ?? id
    }
    /// The other Plex server this row is from (`PlexMetadata.serverID`); nil for the selected one.
    var serverID: String?
    var hubIdentifier: String?
    var title: String?
    var type: String?
    var hubKey: String?
    var key: String?
    var more: Bool?
    var size: Int?
    /// Set by `/hubs`: the user promoted this hub to their Plex home screen
    /// (Plex Web → library → Manage Recommendations → Home). Home renders the
    /// promoted set verbatim, so this is the switch that decides whether a row
    /// exists at all. Absent on `/hubs/sections/{key}` (library pages show
    /// every hub regardless of promotion), hence optional; treat nil as "not
    /// applicable" rather than as false.
    var promoted: Bool?
    var Metadata: [PlexMetadata]?

    init(
        hubIdentifier: String? = nil,
        title: String? = nil,
        type: String? = nil,
        hubKey: String? = nil,
        key: String? = nil,
        more: Bool? = nil,
        size: Int? = nil,
        promoted: Bool? = nil,
        Metadata: [PlexMetadata]? = nil
    ) {
        self.hubIdentifier = hubIdentifier
        self.title = title
        self.type = type
        self.hubKey = hubKey
        self.key = key
        self.more = more
        self.size = size
        self.promoted = promoted
        self.Metadata = Metadata
    }

    // MARK: - State-change equality

    /// Whether two hubs' item lists show the same state: `ratingKey`, `viewOffset`
    /// and `viewCount` in order. Comparing keys alone freezes Continue Watching
    /// progress bars. Both `PlexDataStore` hub refreshes use this.
    nonisolated static func metadataStateEqual(_ lhs: [PlexMetadata]?, _ rhs: [PlexMetadata]?) -> Bool {
        let l = lhs ?? []
        let r = rhs ?? []
        guard l.count == r.count else { return false }
        for (a, b) in zip(l, r) {
            if a.ratingKey != b.ratingKey { return false }
            if a.viewOffset != b.viewOffset { return false }
            if a.viewCount != b.viewCount { return false }
        }
        return true
    }
}

extension PlexHub {
    /// Matched on identifier like tvOS `PlexDataStore.isContinueWatchingFamily`,
    /// never on the localized title. On Deck is in the family.
    nonisolated var isContinueWatching: Bool {
        let id = (hubIdentifier ?? "").lowercased()
        return id.contains("continue") || id.contains("inprogress") || id.contains("ondeck")
    }

    /// The row is on the user's Plex home screen; nil `promoted` (library pages) is not.
    nonisolated var isPromoted: Bool { promoted == true }

    /// What pages this row's See All: the hub key with its query, which is the row's definition.
    /// `/hubs/items` answers 404 without its identifier, so the key carries it. Nil for Continue
    /// Watching (the cache-busted fetch) and a literal id list (`/library/metadata/1,2,3`): neither pages.
    nonisolated var pagingKey: String? {
        guard !isContinueWatching, let key = key ?? hubKey, !key.hasPrefix("/library/metadata/") else { return nil }
        guard key == "/hubs/items" || key.hasSuffix("/hubs/items") else { return key }
        guard let hubIdentifier, !hubIdentifier.isEmpty else { return nil }
        return "\(key)?identifier=\(hubIdentifier)"
    }
}

// MARK: - Media Item (Movie, Show, Episode, etc.)

nonisolated struct PlexMedia: Codable, Sendable {
    let id: Int
    let duration: Int?
    let bitrate: Int?
    let width: Int?
    let height: Int?
    let aspectRatio: Double?
    let audioChannels: Int?
    let audioCodec: String?
    let videoCodec: String?
    let videoResolution: String?
    let container: String?
    let videoFrameRate: String?
    let Part: [PlexPart]?
    // Photo EXIF, on item requests: "f/1.6", "1/5", and ISO as a string. Lenient, as every video shares this type.
    var make: PlexLenientText? = nil
    var model: PlexLenientText? = nil
    var lens: PlexLenientText? = nil
    var aperture: PlexLenientText? = nil
    var exposure: PlexLenientText? = nil
    var iso: PlexLenientText? = nil
}

/// A string or a number as text; any other shape is nil rather than a failed decode.
nonisolated struct PlexLenientText: Codable, Sendable {
    let value: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let text = try? c.decode(String.self) { value = text }
        else if let int = try? c.decode(Int.self) { value = String(int) }
        else if let number = try? c.decode(Double.self) { value = String(number) }
        else { value = nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
}

/// A photo's place, sent only with `includeGeolocation=1`.
nonisolated struct PlexGeolocation: Codable, Sendable {
    nonisolated struct Point: Codable, Sendable {
        let latitude: Double
        let longitude: Double
    }
    let Coordinates: Point?
}

nonisolated struct PlexPart: Codable, Sendable {
    let id: Int
    let key: String?            // nil only on provider display shims, never from Plex
    let duration: Int?
    let file: String?
    let size: Int?
    let container: String?
    let Stream: [PlexStream]?
}

nonisolated struct PlexChapter: Codable, Sendable {
    let id: Int?
    let tag: String?              // Chapter name (e.g., "Chapter 1", "Opening")
    let index: Int?               // Chapter sequence number
    let startTimeOffset: Int?     // Start time in milliseconds
    let endTimeOffset: Int?       // End time in milliseconds
    let thumb: String?            // Chapter thumbnail path (e.g., "/library/media/202357/chapterImages/1")
}
