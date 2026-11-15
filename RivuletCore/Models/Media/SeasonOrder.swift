// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SeasonOrder.swift
//  Rivulet
//
//  Where Specials sit among a show's seasons. One rule for every provider and
//  both apps, so the season pills and the episode rail always agree.
//

import Foundation

enum SeasonOrder {
    /// Specials (season 0) moved after the last season, as the Plex and Infuse
    /// clients list them (#534). Servers return them first, but OVAs, holiday
    /// episodes and the like come out after the seasons they tie into, so they
    /// read as an epilogue, not a prologue. Everything else keeps the server's
    /// order, the specials among themselves included.
    static func specialsLast<T>(_ items: [T], seasonNumber: (T) -> Int?) -> [T] {
        let specials = items.filter { seasonNumber($0) == 0 }
        guard !specials.isEmpty else { return items }
        return items.filter { seasonNumber($0) != 0 } + specials
    }
}
