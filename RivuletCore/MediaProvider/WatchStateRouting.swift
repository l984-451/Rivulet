// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  WatchStateRouting.swift
//  Rivulet
//
//  Marks an item watched or unwatched on its own server. A merged Continue Watching card also
//  stands for the same title on other servers; marking it watched reaches those copies too, or
//  the one left behind brings the card back.
//

import Foundation

nonisolated enum WatchStateRouting {
    /// The card's own server must take it; a copy on another server is best effort.
    /// Only watched reaches the copies: unwatching one server's copy is that server's business.
    static func setPlayed(_ played: Bool, item: MediaItem, copies: [MediaItem],
                          provider: (String) -> (any MediaProvider)?) async throws {
        guard let own = provider(item.ref.providerID) else { throw MediaProviderError.unreachable }
        if played {
            try await own.markPlayed(item.ref)
            for copy in copies {
                try? await provider(copy.ref.providerID)?.markPlayed(copy.ref)
            }
        } else {
            try await own.markUnplayed(item.ref)
        }
    }
}
