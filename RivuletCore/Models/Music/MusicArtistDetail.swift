// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicArtistDetail.swift
//  Rivulet
//
//  Superset returned from MusicProvider.artistDetail(for:).
//

import Foundation

struct MusicArtistDetail: Sendable {
    let artist: MusicArtist
    let bio: String?
    let genres: [String]
    let albums: [MusicAlbum]
    let similarArtists: [MusicArtist]
}
