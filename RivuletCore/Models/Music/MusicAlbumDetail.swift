// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicAlbumDetail.swift
//  Rivulet
//
//  Superset returned from MusicProvider.albumDetail(for:).
//

import Foundation

struct MusicAlbumDetail: Sendable {
    let album: MusicAlbum
    let tracks: [MusicTrack]
    let genres: [String]
    let contributors: [MediaPerson]
}
