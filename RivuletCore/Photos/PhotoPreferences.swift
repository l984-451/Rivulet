// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PhotoPreferences.swift
//  Rivulet
//
//  Slideshow settings, and the Sort and Show each photo library was last left on.
//

import Foundation

nonisolated enum PhotoPreferences {
    enum Transition: String, CaseIterable, Sendable { case dissolve, panAndZoom }

    static let intervals: [TimeInterval] = [3, 5, 10, 20]
    static let intervalKey = "photoSlideInterval"
    static let transitionKey = "photoSlideTransition"
    static let playsClipsKey = "photoSlidePlaysClips"
    static let queryKeyPrefix = "photoLibraryQuery."

    private static var defaults: UserDefaults { .standard }

    /// Seconds per slide, snapped to the nearest of `intervals`.
    static var slideInterval: TimeInterval {
        get {
            guard let stored = defaults.object(forKey: intervalKey) as? Double else { return 5 }
            return intervals.min { abs($0 - stored) < abs($1 - stored) } ?? 5
        }
        set { defaults.set(newValue, forKey: intervalKey) }
    }

    static var transition: Transition {
        get { defaults.string(forKey: transitionKey).flatMap(Transition.init) ?? .dissolve }
        set { defaults.set(newValue.rawValue, forKey: transitionKey) }
    }

    static var playsClips: Bool {
        get { defaults.object(forKey: playsClipsKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: playsClipsKey) }
    }

    static func queryKey(for library: MediaLibrary) -> String {
        queryKeyPrefix + library.providerID + "." + library.id
    }

    /// Sort, direction and Show only: favorites, shuffle and dates are never kept.
    static func query(for library: MediaLibrary) -> PhotoQuery {
        guard let json = defaults.string(forKey: queryKey(for: library)),
              let stored = try? JSONDecoder().decode(PhotoQuery.self, from: Data(json.utf8)) else { return .default }
        return kept(stored)
    }

    /// The saved Sort and Show over `narrowing`'s favorites and dates.
    static func query(for library: MediaLibrary, narrowedBy narrowing: PhotoQuery) -> PhotoQuery {
        var query = query(for: library)
        query.favoritesOnly = narrowing.favoritesOnly
        query.takenBetween = narrowing.takenBetween
        return query
    }

    static func setQuery(_ query: PhotoQuery, for library: MediaLibrary) {
        guard let data = try? JSONEncoder().encode(kept(query)) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: queryKey(for: library))
    }

    private static func kept(_ query: PhotoQuery) -> PhotoQuery {
        var kept = PhotoQuery.default
        kept.sort = query.sort
        kept.ascending = query.ascending
        kept.show = query.show
        return kept
    }
}
