// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexUserRating.swift
//  Rivulet
//
//  Plex's per-user star rating, and what counts as a favorite.
//

import Foundation

enum PlexUserRating {
    /// Plex stores the user's stars as 0-10, where 10 is five stars.
    static let starScale: Double = 2

    /// Stars above this count as a favorite.
    static let favoriteStarThreshold: Double = 3

    /// The rating in stars (0-5), or nil when unrated.
    static func stars(_ userRating: Double?) -> Double? {
        guard let userRating, userRating > 0 else { return nil }
        return userRating / starScale
    }

    /// A favorite is a rating above three stars. It used to be any rating at
    /// all, which marked a one-star pan as a favorite.
    static func isFavorite(_ userRating: Double?) -> Bool {
        (stars(userRating) ?? 0) > favoriteStarThreshold
    }
}
