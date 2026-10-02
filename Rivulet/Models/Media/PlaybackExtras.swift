// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlaybackExtras.swift
//  Rivulet
//
//  Provider-agnostic playback extras: skip markers today.
//

import Foundation

nonisolated struct PlaybackMarker: Hashable, Sendable {
    enum Kind: String, Sendable { case intro, credits, recap, commercial, preview }
    let kind: Kind
    let start: TimeInterval   // seconds
    let end: TimeInterval
}

nonisolated struct PlaybackExtras: Sendable {
    var markers: [PlaybackMarker] = []
}
