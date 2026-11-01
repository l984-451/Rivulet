// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LibrarySortOption.swift
//  Rivulet
//
//  Sort options for Plex library views
//

import Foundation

/// Available sort options for Plex libraries
/// Raw value is the Plex API sort parameter (format: field:direction)
nonisolated enum LibrarySortOption: String, CaseIterable, Codable, CustomStringConvertible {
    var description: String { displayName }
    // Date Added
    case addedAtDesc = "addedAt:desc"        // Recently Added (default)
    case addedAtAsc = "addedAt:asc"          // Oldest Added

    // Title
    case titleAsc = "titleSort:asc"          // Title A-Z
    case titleDesc = "titleSort:desc"        // Title Z-A

    // Release Date
    case releaseDateDesc = "originallyAvailableAt:desc"  // Newest Releases
    case releaseDateAsc = "originallyAvailableAt:asc"    // Oldest Releases

    // Rating
    case ratingDesc = "rating:desc"          // Highest Rated

    // Resolution (video quality)
    case resolutionDesc = "mediaHeight:desc" // Best Quality (4K first)
    case resolutionAsc = "mediaHeight:asc"   // Lowest Quality (SD first)

    // TV Shows only
    case lastEpisodeAddedDesc = "episode.addedAt:desc" // New Episodes

    /// User-friendly display name
    var displayName: String {
        switch self {
        case .addedAtDesc:
            return String(localized: "Recently Added")
        case .addedAtAsc:
            return String(localized: "Oldest Added")
        case .titleAsc:
            return String(localized: "Title A-Z")
        case .titleDesc:
            return String(localized: "Title Z-A")
        case .releaseDateDesc:
            return String(localized: "Newest Releases")
        case .releaseDateAsc:
            return String(localized: "Oldest Releases")
        case .ratingDesc:
            return String(localized: "Highest Rated")
        case .resolutionDesc:
            return String(localized: "Best Quality")
        case .resolutionAsc:
            return String(localized: "Lowest Quality")
        case .lastEpisodeAddedDesc:
            return String(localized: "New Episodes")
        }
    }

    /// Short name for compact display
    var shortName: String {
        switch self {
        case .addedAtDesc:
            return String(localized: "Recent")
        case .addedAtAsc:
            return String(localized: "Oldest")
        case .titleAsc:
            return String(localized: "A-Z")
        case .titleDesc:
            return String(localized: "Z-A")
        case .releaseDateDesc:
            return String(localized: "Newest")
        case .releaseDateAsc:
            return String(localized: "Oldest")
        case .ratingDesc:
            return String(localized: "Rating")
        case .resolutionDesc:
            return String(localized: "4K First")
        case .resolutionAsc:
            return String(localized: "SD First")
        case .lastEpisodeAddedDesc:
            return String(localized: "Episodes")
        }
    }

    /// The API parameter value for sorting
    var apiParameter: String {
        rawValue
    }

    /// Get available sort options based on library type
    /// - Parameter libraryType: The Plex library type ("movie", "show", "artist", etc.)
    /// - Returns: Array of sort options available for this library type
    static func options(for libraryType: String?) -> [LibrarySortOption] {
        guard let type = libraryType else {
            // Default options for unknown library type
            return [.addedAtDesc, .addedAtAsc, .titleAsc, .titleDesc]
        }

        switch type {
        case "movie":
            return [
                .addedAtDesc,
                .addedAtAsc,
                .titleAsc,
                .titleDesc,
                .releaseDateDesc,
                .releaseDateAsc,
                .ratingDesc,
                .resolutionDesc,
                .resolutionAsc
            ]
        case "show":
            return [
                .addedAtDesc,
                .addedAtAsc,
                .titleAsc,
                .titleDesc,
                .lastEpisodeAddedDesc,
                .ratingDesc
            ]
        case "artist":
            // Music libraries have simpler options
            return [
                .addedAtDesc,
                .addedAtAsc,
                .titleAsc,
                .titleDesc
            ]
        default:
            return [.addedAtDesc, .addedAtAsc, .titleAsc, .titleDesc]
        }
    }

    /// Get the next option in the cycle for a given library type
    func next(for libraryType: String?) -> LibrarySortOption {
        let available = LibrarySortOption.options(for: libraryType)
        guard let currentIndex = available.firstIndex(of: self) else {
            return available.first ?? .addedAtDesc
        }
        let nextIndex = (currentIndex + 1) % available.count
        return available[nextIndex]
    }
}
