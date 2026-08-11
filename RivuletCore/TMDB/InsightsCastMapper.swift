// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InsightsCastMapper.swift
//  Rivulet
//
//  Maps TMDB credits / Plex roles into MediaPerson values for the
//  player's Insights cast panel (P1 of Insights feature).
//

import Foundation

enum InsightsCastMapper {

    private static let tmdbProfileBase = "https://image.tmdb.org/t/p/w342"

    static func mediaPeople(fromTMDB credits: [TMDBCredit], titleTmdbId: Int, titleIsMovie: Bool) -> [MediaPerson] {
        credits.compactMap { credit in
            guard let name = credit.name, !name.isEmpty else { return nil }
            return MediaPerson(
                id: credit.id.map { "tmdb-person-\($0)" } ?? "tmdb-person-\(name)",
                name: name,
                role: credit.character,
                imageURL: credit.profilePath.flatMap { URL(string: tmdbProfileBase + $0) },
                titleTmdbId: titleTmdbId,
                titleIsMovie: titleIsMovie
            )
        }
    }

    static func mediaPeople(fromPlexRoles roles: [PlexRole], serverURL: String, authToken: String,
                            titleTmdbId: Int?, titleIsMovie: Bool) -> [MediaPerson] {
        roles.compactMap { role in
            guard let name = role.tag, !name.isEmpty else { return nil }
            return MediaPerson(
                id: role.id,
                name: name,
                role: role.role,
                imageURL: personThumbURL(role.thumb, serverURL: serverURL, authToken: authToken),
                tagKey: role.tagKey,
                originActorId: role.originActorId,
                titleTmdbId: titleTmdbId,
                titleIsMovie: titleIsMovie
            )
        }
    }

    /// Plex people thumbs are either absolute (metadata CDN) or relative server
    /// paths; concatenating serverURL onto an absolute URL would break it.
    static func personThumbURL(_ thumb: String?, serverURL: String, authToken: String) -> URL? {
        guard let thumb, !thumb.isEmpty else { return nil }
        if thumb.hasPrefix("http://") || thumb.hasPrefix("https://") {
            return URL(string: thumb)
        }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(authToken)")
    }
}
