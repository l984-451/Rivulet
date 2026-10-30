// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ContinueWatchingRow.swift
//  Rivulet
//
//  The one Continue Watching row, both apps: each server's row merged by
//  `ContinueWatchingMerge`, over whatever item type the app uses.
//  Missing movie and show identities are fetched on demand, in as few requests
//  per server as possible, only when several servers contribute to the row.
//

import Combine
import Combine
import Foundation

@MainActor
final class ContinueWatchingRow: ObservableObject {
    static let shared = ContinueWatchingRow()

    /// Bumped when identities arrive, so the row re-merges.
    @Published private(set) var version = 0

    /// Set by the host: catalog ids to canonical movie/show identity keys.
    /// Unset, cards merge only on the identities they already carry.
    var fetchIdentityKeys: ((_ providerID: String, _ itemIDs: [String]) async -> [String: [String]])?
    /// Set by the host: run after identities arrive (tvOS refreshes Top Shelf).
    var onResolved: (@MainActor () async -> Void)?

    private let defaultsKey = "showIdentityKeys"
    private let defaults: UserDefaults
    /// "<providerID>|<catalog id>" to canonical keys; [] when none were found.
    private var identityKeys: [String: [String]]
    private var inFlight: [String: Task<Void, Never>] = [:]
    /// Failed lookups remain unmerged and may be asked again next launch.
    private var failed: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        identityKeys = defaults.dictionary(forKey: defaultsKey) as? [String: [String]] ?? [:]
    }

    /// The merged row from each server's row, in server order (the selected
    /// Plex server first). One contributing row comes back as it is. Cards
    /// needing identity resolution wait out of the row to avoid duplicate flashes;
    /// a failed lookup lets them in unmerged.
    /// `lookupKey` identifies a movie or the owning show of a series card.
    func cards<Item>(_ serverRows: [[Item]], identity: (Item) -> [String], lookupKey: (Item) -> String?,
                     watched: (Item) -> Date?) -> [ContinueWatchingMerge.Card<Item>] {
        let rows = serverRows.filter { !$0.isEmpty }
        guard rows.count > 1 else { return (rows.first ?? []).map { .init(item: $0, others: []) } }
        let missing = missingIdentities(in: rows, lookupKey: lookupKey)
        if !missing.isEmpty { resolve(missing) }
        let waiting = missing.subtracting(failed)
        let ready = rows.map { $0.filter { lookupKey($0).map { !waiting.contains($0) } ?? true } }
        return ContinueWatchingMerge.merge(ready, keys: { item in
            identity(item) + (lookupKey(item).flatMap { self.identityKeys[$0] } ?? [])
        }, watched: watched)
    }

    /// Static grids must wait for the same resolution the live Home row observes.
    func resolveIdentities<Item>(in rows: [[Item]], lookupKey: (Item) -> String?) async {
        var contributing = 0
        for row in rows where !row.isEmpty { contributing += 1 }
        guard contributing > 1 else { return }
        let missing = missingIdentities(in: rows, lookupKey: lookupKey)
        if !missing.isEmpty { resolve(missing) }
        for key in missing {
            if let task = inFlight[key] { await task.value }
        }
    }

    private func missingIdentities<Item>(in rows: [[Item]], lookupKey: (Item) -> String?) -> Set<String> {
        var missing = Set<String>()
        for row in rows {
            for item in row {
                if let key = lookupKey(item), identityKeys[key] == nil, !failed.contains(key) {
                    missing.insert(key)
                }
            }
        }
        return missing
    }

    private func resolve(_ keys: Set<String>) {
        guard let fetchIdentityKeys else {
            failed.formUnion(keys)
            return
        }
        let byProvider = Dictionary(grouping: keys.filter { inFlight[$0] == nil }) { String($0.prefix { $0 != "|" }) }
        for (providerID, unique) in byProvider {
            let task = Task {
                let found = await fetchIdentityKeys(providerID, unique.map { String($0.dropFirst(providerID.count + 1)) })
                for key in unique { inFlight.removeValue(forKey: key) }
                if found.isEmpty {
                    failed.formUnion(unique)
                } else {
                    for key in unique {
                        identityKeys[key] = found[String(key.dropFirst(providerID.count + 1))] ?? []
                    }
                    defaults.set(identityKeys, forKey: defaultsKey)
                }
                version += 1
                await onResolved?()
            }
            for key in unique { inFlight[key] = task }
        }
    }
}
