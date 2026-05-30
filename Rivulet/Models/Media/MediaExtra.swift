//
//  MediaExtra.swift
//  Rivulet
//
//  Agnostic representation of a bonus-feature item attached to a movie,
//  show, season, or episode. Provider-mapped from `PlexExtra` today;
//  carries enough to render a 16:9 tile + play through the universal
//  player by ratingKey.
//

import Foundation

struct MediaExtra: Identifiable, Hashable, Sendable {
    /// Provider-native ID (Plex ratingKey).
    let id: String
    let title: String
    let subtype: ExtraSubtype
    let durationSec: Int?
    let thumbURL: URL?
}

/// Canonical Plex extra categories. Render order is the declaration
/// order below.
enum ExtraSubtype: Int, CaseIterable, Sendable, Comparable {
    case trailer
    case featurette
    case behindTheScenes
    case deletedScene
    case interview
    case scene
    case short
    case unknown

    /// Map Plex's raw `subtype` / `extraType` strings to the enum.
    /// Plex uses `sceneOrSample` interchangeably with `deletedScene` on
    /// some library types; both map to `.deletedScene`.
    static func fromPlex(subtype: String?, extraType: Int?) -> ExtraSubtype {
        switch subtype {
        case "trailer": return .trailer
        case "featurette": return .featurette
        case "behindTheScenes": return .behindTheScenes
        case "deletedScene", "sceneOrSample": return .deletedScene
        case "interview": return .interview
        case "scene": return .scene
        case "short": return .short
        default:
            // Fallback to extraType when subtype is absent/unrecognised.
            // Plex uses extraType=1 for trailer; other integer codes are
            // inconsistent across versions, so don't over-map.
            if extraType == 1 { return .trailer }
            return .unknown
        }
    }

    static func < (lhs: ExtraSubtype, rhs: ExtraSubtype) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Human-readable label for the type row on an extra's detail page.
    var displayName: String {
        switch self {
        case .trailer:         return "Trailer"
        case .featurette:      return "Featurette"
        case .behindTheScenes: return "Behind the Scenes"
        case .deletedScene:    return "Deleted Scene"
        case .interview:       return "Interview"
        case .scene:           return "Scene"
        case .short:           return "Short"
        case .unknown:         return "Extra"
        }
    }
}
