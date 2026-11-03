// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ContinueWatchingRow.swift
//  Rivulet
//
//  The one Continue Watching row, both apps: each server's row merged by
//  `ContinueWatchingMerge`, over whatever item type the app uses.
//  Show identities (the keys an episode merges on) are fetched once per show,
//  in one batched request per server, and kept: a show's ids never change.
//

import Combine
import Combine
import Foundation

@MainActor
final class ContinueWatchingRow: ObservableObject {
    static let shared = ContinueWatchingRow()

    /// Bumped when show identities arrive, so the row re-merges.
    @Published private(set) var version = 0

    /// Set by the host: a server's show ids to their keys, in as few requests
    /// as it allows ([:] when the lookup failed). Unset, episodes merge only on
    /// the keys they carry.
    var fetchShowKeys: ((_ providerID: String, _ showIDs: [String]) async -> [String: [String]])?
    /// Set by the host: run after identities arrive (tvOS refreshes Top Shelf).
    var onResolved: (@MainActor () async -> Void)?

    private let defaultsKey = "showIdentityKeys"
    /// "<providerID>|<show id>" to the show's keys; [] once a lookup came back without any.
    // ponytail: grows by one small entry per show ever in Continue Watching; prune if it ever matters.
    private var showKeys: [String: [String]]
    private var inFlight: Set<String> = []
    /// Shows whose lookup failed this session: shown unmerged, asked again next launch.
    private var failed: Set<String> = []

    private init() {
        showKeys = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String]] ?? [:]
    }

    /// The merged row from each server's row, in server order (the selected
    /// Plex server first). One contributing row merges only on the keys its items
    /// carry, with no lookup and in its own order. Episodes
    /// whose show is not identified yet wait out of the row, so no duplicate
    /// flashes before the lookup lands; a lookup that fails lets them in unmerged.
    /// `showKey` is "<providerID>|<show id>" for an episode or season, else nil.
    func cards<Item>(_ serverRows: [[Item]], identity: (Item) -> [String], showKey: (Item) -> String?,
                     watched: (Item) -> Date?) -> [ContinueWatchingMerge.Card<Item>] {
        let rows = serverRows.filter { !$0.isEmpty }
        guard rows.count > 1 else { return ContinueWatchingMerge.merge(rows, keys: identity, watched: watched) }
        let missing = Set(rows.flatMap { $0 }.compactMap(showKey).filter { showKeys[$0] == nil && !failed.contains($0) })
        if !missing.isEmpty { resolve(missing) }
        let ready = rows.map { $0.filter { showKey($0).map { !missing.contains($0) } ?? true } }
        return ContinueWatchingMerge.merge(ready, keys: { item in
            identity(item) + (showKey(item).flatMap { self.showKeys[$0] } ?? [])
        }, watched: watched)
    }

    private func resolve(_ keys: Set<String>) {
        guard let fetchShowKeys else {
            failed.formUnion(keys)
            return
        }
        let byProvider = Dictionary(grouping: keys.subtracting(inFlight)) { String($0.prefix { $0 != "|" }) }
        for (providerID, unique) in byProvider {
            inFlight.formUnion(unique)
            Task {
                let found = await fetchShowKeys(providerID, unique.map { String($0.dropFirst(providerID.count + 1)) })
                inFlight.subtract(unique)
                if found.isEmpty {
                    failed.formUnion(unique)
                } else {
                    for key in unique {
                        showKeys[key] = found[String(key.dropFirst(providerID.count + 1))] ?? []
                    }
                    UserDefaults.standard.set(showKeys, forKey: defaultsKey)
                }
                version += 1
                await onResolved?()
            }
        }
    }
}
