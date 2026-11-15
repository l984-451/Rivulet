// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HeroTextlessBackdrop.swift
//  Rivulet
//
//  A Home hero backdrop with the title baked in shows it twice, next to the hero's
//  logo (#450). The logo always stays: when `ArtworkTitleCheck` finds the title on
//  the backdrop, this swaps in TMDB's best textless one. No id or no textless
//  image keeps the server's backdrop.
//

import CoreGraphics
import Foundation

nonisolated enum HeroTextlessBackdrop {

    /// Backdrop URL to the decision: the swap, or NSNull when the backdrop stays.
    private static let decided = NSCache<NSURL, AnyObject>()

    /// The textless backdrop already chosen for `backdrop`; nil when none or not yet decided.
    static func cached(_ backdrop: URL) -> URL? {
        decided.object(forKey: backdrop as NSURL) as? URL
    }

    static func clear() { decided.removeAllObjects() }

    /// The textless backdrop to show instead of `backdrop`, or nil to keep it. `load` fetches an image.
    static func resolve(backdrop: URL, logo: URL?, title: String, tmdb: (id: Int, type: TMDBMediaType)?,
                        size: String = "w1280", load: @escaping (URL) async -> CGImage?) async -> URL? {
        guard let tmdb else { return nil }
        if let known = decided.object(forKey: backdrop as NSURL) { return known as? URL }
        let key = ArtworkTitleCheck.key(still: backdrop, title: title)
        let shows = await ArtworkTitleCheck.answer(key, title: title) {
            guard let still = await load(backdrop) else { return nil }
            guard let logo else { return (still, nil) }
            guard let image = await load(logo) else { return nil }
            return (still, image)
        }
        // A failed image load is not an answer; the next display tries again.
        guard ArtworkTitleCheck.known(key) != nil else { return nil }
        guard shows else {
            decided.setObject(NSNull(), forKey: backdrop as NSURL)
            return nil
        }
        guard let swap = await TMDBLogoCache.shared.textlessBackdropURL(tmdbId: tmdb.id, type: tmdb.type, size: size) else {
            return nil
        }
        decided.setObject(swap as NSURL, forKey: backdrop as NSURL)
        return swap
    }
}

extension MediaItem {
    /// The TMDB id and type a hero can ask for a textless backdrop. Nil for episodes
    /// and seasons: their ids are not the show's.
    var heroTMDB: (id: Int, type: TMDBMediaType)? {
        guard kind == .movie || kind == .show, let id = externalIDs?["tmdb"].flatMap(Int.init) ?? tmdbID else { return nil }
        return (id, kind == .movie ? .movie : .tv)
    }
}

extension PlexMetadata {
    var heroTMDB: (id: Int, type: TMDBMediaType)? {
        guard type == "movie" || type == "show", let tmdbId else { return nil }
        return (tmdbId, tmdbMediaType)
    }
}
