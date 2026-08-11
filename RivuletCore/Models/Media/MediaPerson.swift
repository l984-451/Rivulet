// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaPerson.swift
//  Rivulet
//
//  Cast / crew member.
//

import Foundation

struct MediaPerson: Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let role: String?
    let imageURL: URL?
    var tagKey: String? = nil           // Discover person key (cast only)
    var originActorId: String? = nil    // origin-library actor id (fallback path)
    var originSectionKey: String? = nil // origin library section key (fallback path)
    var titleTmdbId: Int? = nil       // originating title's TMDB id (for actor->TMDB resolution)
    var titleIsMovie: Bool = true     // originating title type (movie vs show)
    var backdropURL: URL? = nil       // backdrop of the originating title (for person detail page background)
}
