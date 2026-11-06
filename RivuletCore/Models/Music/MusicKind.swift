// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicKind.swift
//  Rivulet
//
//  Type discriminator for MusicItem enum cases.
//

import Foundation

enum MusicKind: String, Sendable, Hashable, Codable {
    case artist
    case album
    case track
}
