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
            return "Recently Added"
        case .addedAtAsc:
            return "Oldest Added"
        case .titleAsc:
            return "Title A-Z"
        case .titleDesc:
            return "Title Z-A"
        case .releaseDateDesc:
            return "Newest Releases"
        case .releaseDateAsc:
            return "Oldest Releases"
        case .ratingDesc:
            return "Highest Rated"
        case .resolutionDesc:
            return "Best Quality"
        case .resolutionAsc:
            return "Lowest Quality"
        case .lastEpisodeAddedDesc:
            return "New Episodes"
        }
    }

    /// Short name for compact display
    var shortName: String {
        switch self {
        case .addedAtDesc:
            return "Recent"
        case .addedAtAsc:
            return "Oldest"
        case .titleAsc:
            return "A-Z"
        case .titleDesc:
            return "Z-A"
        case .releaseDateDesc:
            return "Newest"
        case .releaseDateAsc:
            return "Oldest"
        case .ratingDesc:
            return "Rating"
        case .resolutionDesc:
            return "4K First"
        case .resolutionAsc:
            return "SD First"
        case .lastEpisodeAddedDesc:
            return "Episodes"
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
