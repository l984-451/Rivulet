// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicTrack.swift
//  Rivulet
//
//  Agnostic track shape — the unit of music playback.
//

import Foundation

struct MusicTrack: Identifiable, Hashable, Sendable {
    var id: MediaItemRef { ref }
    let ref: MediaItemRef
    let title: String
    let albumRef: MediaItemRef?
    let albumTitle: String?
    let artistRef: MediaItemRef?
    let artistName: String?
    let trackNumber: Int?
    let discNumber: Int?
    let duration: TimeInterval
    let audioCodec: String?
    let bitrate: Int?
    let sampleRate: Int?
    let artwork: MediaArtwork
    let userState: MusicUserState
}
