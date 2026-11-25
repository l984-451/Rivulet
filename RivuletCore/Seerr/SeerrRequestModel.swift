// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// A title's request state for the SwiftUI apps (iOS, Mac): what Seerr says about it, its seasons,
// the quality profiles to choose from, and the request itself. The views only draw it.

import Combine
import Foundation
import os

@MainActor
final class SeerrRequestModel: ObservableObject {
    let kind: SeerrTitle.Kind
    let tmdbID: Int

    /// What the button says: Request while anything can still be asked for, else the state.
    @Published private(set) var state: SeerrAvailability = .requestable
    /// A show's seasons, specials left out; empty for a movie.
    @Published private(set) var seasons: [SeerrSeason] = []
    /// The profiles to choose from; one or none means there is nothing to choose.
    @Published private(set) var qualities: [SeerrQualityOption] = []
    @Published private(set) var isLoaded = false
    @Published private(set) var isRequesting = false
    /// The last failure, for an alert.
    @Published var error: String?

    /// A model for a title not in the library, or nil when Seerr is off or the title is anything else.
    init?(item: MediaItem) {
        guard SeerrCatalog.isAvailable, let target = SeerrCatalog.target(item) else { return nil }
        kind = target.kind
        tmdbID = target.tmdbID
    }

    var requestableSeasons: [Int] { SeerrSeasons.requestableNumbers(seasons) }

    /// Whether the button does anything: a movie that can be requested, or a show with a season left.
    var canRequest: Bool { kind == .movie ? state.canRequest : !requestableSeasons.isEmpty }

    /// The quality to offer a choice of; nil when there is only one way to request.
    var qualityChoices: [SeerrQualityOption]? { qualities.count > 1 ? qualities : nil }

    func load() async {
        guard let client = SeerrClient.configured else { return }
        async let options = SeerrCatalog.qualityOptions(kind)
        do {
            if kind == .movie {
                state = try await client.movieAvailability(tmdbID)
            } else {
                let show = try await client.show(tmdbID)
                seasons = show.seasons
                state = show.pillState
            }
        } catch {
            SeerrCatalog.log.error("Seerr status failed: \(error.localizedDescription, privacy: .public)")
        }
        qualities = await options
        isLoaded = true
    }

    /// Requests the movie, or `seasons` of the show (all that can be asked for when nil), in
    /// `quality` (Seerr's default when nil).
    func request(seasons numbers: [Int]? = nil, quality: SeerrQualityOption? = nil) async {
        guard !isRequesting, let client = SeerrClient.configured else { return }
        isRequesting = true
        defer { isRequesting = false }
        do {
            if kind == .movie {
                try await client.requestMovie(tmdbID, quality: quality)
                state = .requested
            } else {
                let asked = numbers ?? requestableSeasons
                try await client.requestShow(tmdbID, seasons: asked, quality: quality)
                state = SeerrSeasons.availability(after: asked, of: seasons, was: state)
                seasons = seasons.map { season in
                    asked.contains(season.number)
                        ? SeerrSeason(number: season.number, name: season.name,
                                      episodeCount: season.episodeCount, availability: .requested)
                        : season
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// A season's menu label: its name, with its state when it can't be requested.
    static func label(for season: SeerrSeason) -> String {
        let name = season.name.isEmpty ? String(localized: "Season \(season.number)") : season.name
        guard !season.availability.canRequest, let state = season.availability.badge else { return name }
        return "\(name) · \(state)"
    }
}
