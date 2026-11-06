// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicArtist.swift
//  Rivulet
//
//  Agnostic artist shape for browse/grid/detail.
//

import Foundation

struct MusicArtist: Identifiable, Hashable, Sendable {
    var id: MediaItemRef { ref }
    let ref: MediaItemRef
    let name: String
    let sortName: String?
    let artwork: MediaArtwork
    let genres: [String]
    let yearRange: ClosedRange<Int>?    // e.g. 1985...2014
    let userState: MusicUserState
}
