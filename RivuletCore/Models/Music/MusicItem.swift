// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicItem.swift
//  Rivulet
//
//  Mixed-kind wrapper for surfaces that can hold any music entity
//  (search, recently-played hubs). Each case wraps a typed struct; kind-
//  specific views target the struct directly.
//

import Foundation

enum MusicItem: Identifiable, Hashable, Sendable {
    case artist(MusicArtist)
    case album(MusicAlbum)
    case track(MusicTrack)

    var id: MediaItemRef { ref }

    var ref: MediaItemRef {
        switch self {
        case .artist(let a): return a.ref
        case .album(let a): return a.ref
        case .track(let t): return t.ref
        }
    }

    var kind: MusicKind {
        switch self {
        case .artist: return .artist
        case .album: return .album
        case .track: return .track
        }
    }

    var title: String {
        switch self {
        case .artist(let a): return a.name
        case .album(let a): return a.title
        case .track(let t): return t.title
        }
    }

    var artwork: MediaArtwork {
        switch self {
        case .artist(let a): return a.artwork
        case .album(let a): return a.artwork
        case .track(let t): return t.artwork
        }
    }
}
