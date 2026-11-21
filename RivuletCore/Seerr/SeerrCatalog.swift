// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// What every app asks of Seerr outside a request itself: whether it is on, what a title asks it
// for, search results to request, a title's trailer and recommendations, and the quality profiles
// a request can name.

import Foundation
import os

@MainActor
enum SeerrCatalog {
    static let log = Logger(subsystem: "com.rivulet.app", category: "Seerr")

    /// Requests go out under the admin API key, so a restricted (managed) profile gets none,
    /// the same way it gets no server settings.
    static var isAvailable: Bool {
        SeerrSettings.isConfigured && !PlexUserProfileManager.shared.isRestrictedProfile
    }

    /// What a title not in the library asks Seerr for, or nil for anything else.
    static func target(_ item: MediaItem) -> (kind: SeerrTitle.Kind, tmdbID: Int)? {
        guard item.isMetadataOnly, let id = item.tmdbID else { return nil }
        switch item.kind {
        case .movie: return (.movie, id)
        case .show: return (.tv, id)
        default: return nil
        }
    }

    /// Seerr's results for `query`, minus what is already available. A Seerr that is down or
    /// misconfigured gives none; the library's own results don't depend on it.
    static func search(_ query: String) async -> [SeerrTitle] {
        guard isAvailable, let client = SeerrClient.configured else { return [] }
        do {
            return SeerrTitle.requestable(try await client.search(query))
        } catch {
            log.error("Seerr search failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// More Like This for a title not in the library: Seerr's recommendations, else TMDB's.
    static func related(to item: MediaItem) async -> [MediaItem] {
        if let client = SeerrClient.configured, let target = target(item),
           let titles = try? await client.recommendations(target.kind, target.tmdbID), !titles.isEmpty {
            return titles.map(\.mediaItem)
        }
        let source = MetadataSourceRegistry.shared.source(for: item.ref.providerID)
        return (try? await source?.recommendations(for: item.ref)) ?? []
    }

    // MARK: - Quality

    private static var qualityCache: [SeerrTitle.Kind: (fetched: Date, options: [SeerrQualityOption])] = [:]

    /// The quality profiles a movie or show can be requested in, Seerr's default first. Kept for
    /// five minutes: profiles change rarely and each read asks every Radarr or Sonarr server.
    static func qualityOptions(_ kind: SeerrTitle.Kind) async -> [SeerrQualityOption] {
        if let cached = qualityCache[kind], Date().timeIntervalSince(cached.fetched) < 300 { return cached.options }
        guard let client = SeerrClient.configured else { return [] }
        do {
            let options = try await client.qualityOptions(kind)
            qualityCache[kind] = (Date(), options)
            return options
        } catch {
            log.error("Seerr quality profiles failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}

extension SeerrTitle: Identifiable {
    var id: String { "\(kind.rawValue):\(tmdbID)" }

    /// "Movie · 2021" / "TV Show · 2024", for a search row.
    var subtitle: String {
        let kindName = kind == .movie ? String(localized: "Movie") : String(localized: "TV Show")
        guard let year = releaseDate?.prefix(4), year.count == 4 else { return kindName }
        return "\(kindName) · \(year)"
    }
}

extension SeerrTitle {
    /// The title as a metadata-only item, the same shape Discover's TMDB titles have, so the
    /// detail page can open it.
    @MainActor var mediaItem: MediaItem {
        TMDBMediaMapper.item(TMDBListItem(
            id: tmdbID, title: title, overview: overview,
            posterPath: posterPath, backdropPath: backdropPath,
            releaseDate: releaseDate, voteAverage: nil,
            mediaType: kind == .movie ? .movie : .tv))
    }
}

extension SeerrAvailability {
    /// The SF Symbol each app draws beside the state.
    var symbolName: String {
        switch self {
        case .requestable: "plus.circle"
        case .requested, .processing: "clock"
        case .partiallyAvailable, .available: "checkmark.circle"
        case .blocklisted: "nosign"
        }
    }
}
