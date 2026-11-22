// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Foundation
import Observation

/// Which Discover titles the signed-in servers own, and the copy a tap opens instead of the TMDB
/// page. Tiles don't change: on tvOS too, owning a title only changes what it opens.
@Observable @MainActor
final class DiscoverOwnership {
    /// Each owned title's copy, by the title's ref: the first server in the order given that has it
    /// in a library shown on Home. A title not here isn't owned, or hasn't been asked about yet.
    private(set) var copies: [MediaItemRef: MediaItem] = [:]
    /// The servers `copies` came from.
    @ObservationIgnored private var servers: [String] = []

    /// Asks about one row at a time, in page order, every server at once, and publishes each row's
    /// answers when it finishes. A different server list (or order) from last time drops every answer first.
    func check(_ rows: [[MediaItem]], providers: [any MediaProvider], isShown: (MediaItem) -> Bool) async {
        let ids = providers.map(\.id)
        if ids != servers {
            copies = [:]
            servers = ids
        }
        // Rows share titles (Popular and Now Playing): each is asked once, so a later row can't undo its answer.
        var asked = Set<MediaItemRef>()
        for row in rows {
            let titles = row.compactMap { item in Self.title(item).map { (ref: item.ref, match: $0) } }
                .filter { asked.insert($0.ref).inserted }
            guard !titles.isEmpty else { continue }
            let asked = titles.map(\.match)
            let found = await withTaskGroup(of: (Int, [MediaItem]).self) { group in
                for (index, provider) in providers.enumerated() {
                    // A server that fails owns nothing this time; the others still answer.
                    group.addTask { (index, (try? await provider.ownedItems(matching: asked, limit: asked.count)) ?? []) }
                }
                return await group.reduce(into: [Int: [MediaItem]]()) { $0[$1.0] = $1.1 }
            }
            // Cancelled, or a newer check moved to other servers: these answers are no one's.
            guard !Task.isCancelled, servers == ids else { return }
            let candidates = providers.indices.flatMap { found[$0] ?? [] }
            var next = copies
            for title in titles {
                next[title.ref] = candidates.first { copy in
                    title.match.matches(kind: copy.kind, ids: copy.externalIDs ?? [:]) && isShown(copy)
                }
            }
            if next != copies { copies = next }
        }
    }

    /// A Discover title as a server is asked about it: its kind and TMDB id. Servers' copies carry
    /// that id among their external ids (Plex's through `includeGuids` on `findByGuids`).
    private static func title(_ item: MediaItem) -> TitleMatch? {
        guard let tmdb = item.tmdbID else { return nil }
        return TitleMatch(kind: item.kind, externalIDs: ["tmdb": String(tmdb)], plexGUID: nil)
    }
}
