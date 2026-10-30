// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// A server-owned rung. `id` is echoed verbatim; bitrate is an estimate, not a resolution guarantee.
nonisolated struct MediaQuality: Hashable, Sendable, Codable {
    let id: String
    let displayName: String?
    let height: Int?
    let bitrateKbps: Int?
    let preservesSource: Bool
}

nonisolated enum MediaQualityPreference: Hashable, Sendable, Codable {
    case automatic
    case offered(id: String)

    var serverValue: String {
        switch self {
        case .automatic: "auto"
        case .offered(let id): id
        }
    }
}

nonisolated enum BufferingQualityPolicy: String, Hashable, Sendable, Codable {
    case never
    case ask
    case automatically
}

nonisolated struct MediaBandwidthLimit: Hashable, Sendable, Codable {
    let kbps: Int
    let source: String
    let expiresAt: Date?
}

nonisolated enum MediaDelivery: Hashable, Sendable, Codable {
    case original
    case progressiveRemux
    case hlsRemux
    case hlsTranscode
    case other(String)
}

nonisolated struct MediaEffectiveRecipe: Hashable, Sendable, Codable {
    let videoCodec: String?
    let videoSampleEntry: String?
    let segmentContainer: String?
    let audioCodec: String?
    let width: Int?
    let height: Int?
    let frameRate: Double?
    let bitrateKbps: Int?
    let dynamicRange: String?
    let audioChannels: Int?
    let audioLayout: String?
}

nonisolated struct MediaDegradation: Hashable, Sendable, Codable {
    let code: String
    let message: String
}

nonisolated struct MediaNegotiatedStatus: Hashable, Sendable, Codable {
    let delivery: MediaDelivery
    let availableQualities: [MediaQuality]
    let activeQualityID: String?
    let effectiveRecipe: MediaEffectiveRecipe?
    let decisionReason: String?
    let degradationWarnings: [MediaDegradation]
    let bandwidthLimit: MediaBandwidthLimit?
    let headerRefreshURL: URL?
}

nonisolated struct MediaCatalogFacet: Hashable, Sendable, Codable {
    let id: String
    let title: String
    let choices: [Choice]

    struct Choice: Hashable, Sendable, Codable {
        let id: String
        let title: String
        let count: Int?
    }
}

/// Persist this per provider, profile and library; IDs remain opaque to the client.
nonisolated struct MediaCatalogFilter: Hashable, Sendable, Codable {
    var selectedChoices: [String: [String]]
}

nonisolated enum MediaDismissalRail: String, Hashable, Sendable, Codable {
    case continueWatching
    case nextUp
}

/// Dismissal is a rail action; it must never erase resume progress.
nonisolated struct MediaDismissal: Hashable, Sendable, Codable {
    let item: MediaItemRef
    let rail: MediaDismissalRail
    let providerIdentity: String
    let progressUpdatedAt: String?
    let seriesID: String?
    let authorityRevision: UInt64?

    init(item: MediaItemRef, rail: MediaDismissalRail, providerIdentity: String,
         progressUpdatedAt: String? = nil, seriesID: String? = nil, authorityRevision: UInt64? = nil) {
        self.item = item
        self.rail = rail
        self.providerIdentity = providerIdentity
        self.progressUpdatedAt = progressUpdatedAt
        self.seriesID = seriesID
        self.authorityRevision = authorityRevision
    }
}

nonisolated struct MediaPersonResult: Hashable, Sendable {
    let person: MediaPerson
    let providerID: String
}
