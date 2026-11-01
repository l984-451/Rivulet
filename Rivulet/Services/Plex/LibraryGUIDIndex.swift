// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LibraryGUIDIndex.swift
//  Rivulet
//
//  In-memory index of library items keyed by external GUIDs (TMDB/IMDB/TVDB).
//  Used by Discover and Watchlist surfaces to answer "do I own this?" in O(1).
//

import Foundation
import os.log

private let guidIndexLog = Logger(subsystem: "com.rivulet.app", category: "LibraryGUIDIndex")

extension Notification.Name {
    /// Posted on the main thread after `LibraryGUIDIndex.shared.replace(with:completeness:)`
    /// completes. Views observing this can re-run library-match queries.
    static let libraryGUIDIndexDidUpdate = Notification.Name("LibraryGUIDIndexDidUpdate")
}

actor LibraryGUIDIndex {
    static let shared = LibraryGUIDIndex()

    private struct TypedKey: Hashable {
        let type: PlexItemType
        let key: String
    }

    enum PlexItemType: String, Hashable, Codable, Sendable {
        case movie
        case show
    }

    /// What the index keeps per item: enough to answer "do I own this?" and to fetch the item.
    /// Full metadata for 56k items held 308 MB and its persist encode added 371 MB (#409).
    nonisolated struct Entry: Codable, Sendable, Equatable {
        let ratingKey: String
        let sectionID: String
        let type: PlexItemType
        let guids: [String]

        /// Nil for anything the index ignores: not a movie or show, or no external guid.
        init?(_ item: PlexMetadata, sectionID: String) {
            guard let ratingKey = item.ratingKey,
                  let type = PlexItemType(rawValue: item.type ?? "") else { return nil }
            let guids = (item.Guid ?? []).compactMap(\.id)
            guard !guids.isEmpty else { return nil }
            self.ratingKey = ratingKey
            self.sectionID = sectionID
            self.type = type
            self.guids = guids
        }
    }

    private var byTypedTmdbId: [TypedKey: Entry] = [:]
    private var byGuid: [String: Entry] = [:]

    /// Per section, what the server looked like when this snapshot was built (`sectionStamp`).
    private var stamps: [String: String] = [:]
    private var snapshotSavedAt: Date?
    private var isRebuilding = false

    /// Live network data always supersedes a disk-hydrated snapshot. Once a real
    /// `replace(with:completeness:)` has run this launch, a late `hydrateFromDisk()`
    /// is a no-op so stale disk contents can't clobber fresh server data. This is
    /// set for partial builds too, since a partial live snapshot is still more
    /// current than the disk copy.
    private var hasFreshData = false

    /// Bumped on every rebuild. Consumers (e.g. the trending hero) read this to
    /// skip recomputation when the index hasn't actually changed since their last
    /// run, so overlapping triggers don't repeat identical work.
    private(set) var generation = 0

    /// Whether a rebuild saw every section and page. Only a complete build may write the disk
    /// cache: a truncated snapshot loads next launch as authoritative and the gap persists.
    /// A partial build still updates memory. Keep this a required parameter, not a default.
    enum Completeness: Sendable {
        /// Every visible section returned every page without error. Safe to persist.
        case complete
        /// At least one section failed or was cut short. In-memory only.
        case partial
    }

    /// Rebuild the index from a freshly-fetched library snapshot and notify
    /// observers. This is the authoritative path — it always wins over
    /// `hydrateFromDisk()`, complete or not, because even a partial live snapshot
    /// is more current than last launch's disk contents.
    ///
    /// Persists to disk only when `completeness` is `.complete`. See the
    /// `Completeness` doc comment for why a partial build must not be written.
    func replace(with items: [Entry], completeness: Completeness, stamps: [String: String] = [:]) {
        rebuild(from: items, source: "replace")
        self.stamps = stamps
        snapshotSavedAt = Date()

        // Set regardless of completeness. `hasFreshData` guards against a late
        // `hydrateFromDisk()` overwriting live server data with the older disk
        // snapshot, and that ordering hazard is identical whether this build was
        // complete or not. Leaving it false on a partial build would let a
        // straggling hydrate replace a partial-but-current index with a
        // possibly-worse one from disk.
        hasFreshData = true

        // Deliberately no log line on the partial branch: the caller already
        // reports the incomplete-section count when it finishes the build, and
        // guidIndexLog carries pre-existing actor-isolation warnings we are not
        // adding to.
        if case .complete = completeness {
            persist(items, stamps: stamps)
        }
    }

    /// One rebuild at a time: a second caller gets false and leaves it to the first.
    func claimRebuild() -> Bool {
        guard !isRebuilding else { return false }
        isRebuilding = true
        return true
    }

    func finishRebuild() {
        isRebuilding = false
    }

    /// Whether the loaded snapshot already reflects these sections, so a rebuild would refetch
    /// the same library. Rebuilt weekly regardless, for changes the stamp can't see.
    func isCurrent(for stamps: [String: String]) -> Bool {
        guard !byGuid.isEmpty, !stamps.isEmpty, stamps == self.stamps,
              let savedAt = snapshotSavedAt else { return false }
        return Date().timeIntervalSince(savedAt) < 7 * 24 * 3600
    }

    /// A section's item count plus its most recently updated item. Additions and removals move
    /// the count; edits and re-matches move `updatedAt` (measured, PMS 1.43.4). Watching doesn't.
    static func sectionStamp(totalSize: Int?, newest: PlexMetadata?) -> String? {
        guard let totalSize else { return nil }
        return "\(totalSize)/\(newest?.ratingKey ?? "-")/\(newest?.updatedAt ?? 0)"
    }

    /// Populate the index from the last persisted snapshot. Cheap (local decode),
    /// so it runs at launch to make "do I own this?" answers available before the
    /// ~20MB network refresh lands. Skips if fresh network data already arrived.
    /// Returns the number of items hydrated (0 = miss / skipped / decode failure).
    func hydrateFromDisk() -> Int {
        guard !hasFreshData else {
            guidIndexLog.info("[GUIDIndex] hydrateFromDisk skipped: fresh network data already present")
            return 0
        }
        guard let cache = Self.loadFromDisk() else {
            guidIndexLog.info("[GUIDIndex] hydrateFromDisk miss: no valid cache on disk")
            return 0
        }
        adopt(cache, source: "hydrateFromDisk")
        return cache.items.count
    }

    /// Shared ingest + notify used by both `replace` and `hydrateFromDisk`.
    private func rebuild(from items: [Entry], source: String) {
        byTypedTmdbId.removeAll(keepingCapacity: true)
        byGuid.removeAll(keepingCapacity: true)

        for item in items {
            ingest(item)
        }
        generation += 1

        let typedCount = byTypedTmdbId.count
        let guidCount = byGuid.count
        guidIndexLog.info("[Hero] LibraryGUIDIndex.\(source, privacy: .public): ingested \(items.count, privacy: .public) items -> typedTmdbCount=\(typedCount, privacy: .public), guidCount=\(guidCount, privacy: .public)")
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .libraryGUIDIndexDidUpdate,
                object: nil,
                userInfo: ["typedTmdbCount": typedCount, "guidCount": guidCount]
            )
        }
    }

    var isEmpty: Bool {
        byGuid.isEmpty
    }

    func lookup(tmdbId: Int, type: TMDBMediaType) -> Entry? {
        let plexType: PlexItemType = (type == .movie) ? .movie : .show
        return byTypedTmdbId[TypedKey(type: plexType, key: "\(tmdbId)")]
    }

    func lookup(guid: String) -> Entry? {
        byGuid[guid]
    }

    func contains(guid: String) -> Bool {
        byGuid[guid] != nil
    }

    // MARK: - Ingestion

    private func ingest(_ item: Entry) {
        for raw in item.guids {
            byGuid[raw] = item

            if let tmdbId = Self.tmdbId(from: raw) {
                byTypedTmdbId[TypedKey(type: item.type, key: "\(tmdbId)")] = item
            }
        }
    }

    /// The library items behind `entries`, keyed by rating key: one request per section per
    /// 100 keys. A section that fails is missing from the result, as if it were not owned.
    static func items(
        for entries: [Entry],
        serverURL: String,
        authToken: String
    ) async -> [String: PlexMetadata] {
        var out: [String: PlexMetadata] = [:]
        for (section, group) in Dictionary(grouping: entries, by: \.sectionID) {
            let keys = Array(Set(group.map(\.ratingKey)))
            guard let items = try? await PlexNetworkManager.shared.getLibraryItems(
                serverURL: serverURL, authToken: authToken, sectionId: section, ratingKeys: keys
            ) else { continue }
            for item in items {
                if let key = item.ratingKey { out[key] = item }
            }
        }
        guidIndexLog.info("[GUIDIndex] fetched \(out.count, privacy: .public) of \(entries.count, privacy: .public) owned items")
        return out
    }

    private static func tmdbId(from guid: String) -> Int? {
        guard guid.hasPrefix("tmdb://") else { return nil }
        let raw = guid.dropFirst("tmdb://".count)
        return Int(raw)
    }

    // MARK: - Disk persistence

    /// Bump when the persisted shape changes so old caches are ignored, not
    /// mis-decoded, on the next launch after an app update.
    private static let cacheVersion = 2

    private nonisolated struct DiskCache: Codable {
        let version: Int
        let savedAt: Date
        let items: [Entry]
        let stamps: [String: String]
    }

    private static var cacheURL: URL? {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        // One snapshot per Home profile: what is "in your library" depends on who looks.
        let owner = UserDefaults.standard.integer(forKey: PlexProfileSession.contentUserIDKey)
        return dir.appendingPathComponent(owner == 0 ? "library-guid-index-v2.json" : "library-guid-index-v2-\(owner).json")
    }

    /// Version 1 held full metadata: 113 MB at 56k items, and it never decodes as v2.
    private static var legacyCacheURL: URL? {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let owner = UserDefaults.standard.integer(forKey: PlexProfileSession.contentUserIDKey)
        return dir.appendingPathComponent(owner == 0 ? "library-guid-index.json" : "library-guid-index-\(owner).json")
    }

    /// Another profile owns the content now: drop the previous one's answers
    /// and take this profile's last snapshot.
    func profileChanged() {
        hasFreshData = false
        if let cache = Self.loadFromDisk() {
            adopt(cache, source: "profileChanged")
        } else {
            rebuild(from: [], source: "profileChanged")
            stamps = [:]
            snapshotSavedAt = nil
        }
    }

    private func adopt(_ cache: DiskCache, source: String) {
        rebuild(from: cache.items, source: source)
        stamps = cache.stamps
        snapshotSavedAt = cache.savedAt
    }

    /// Persist the ingested snapshot for the next launch. Fire-and-forget on a
    /// background task so the encode + write never serializes behind other
    /// actor work or the caller's critical path.
    private func persist(_ items: [Entry], stamps: [String: String]) {
        guard let url = Self.cacheURL else { return }
        let legacy = Self.legacyCacheURL
        Task.detached(priority: .utility) {
            if let legacy { try? FileManager.default.removeItem(at: legacy) }
            let cache = DiskCache(version: Self.cacheVersion, savedAt: Date(), items: items, stamps: stamps)
            do {
                let data = try JSONEncoder().encode(cache)
                try data.write(to: url, options: .atomic)
                guidIndexLog.info("[GUIDIndex] persisted \(items.count, privacy: .public) items (\(data.count / 1024, privacy: .public) KB) to disk")
            } catch {
                guidIndexLog.error("[GUIDIndex] persist failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Load and validate the persisted snapshot. Returns nil on miss, version
    /// mismatch, or decode failure (caller falls back to the network build).
    private static func loadFromDisk() -> DiskCache? {
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        guard let cache = try? JSONDecoder().decode(DiskCache.self, from: data) else {
            guidIndexLog.error("[GUIDIndex] disk cache decode failed; ignoring")
            return nil
        }
        guard cache.version == cacheVersion else {
            guidIndexLog.info("[GUIDIndex] disk cache version \(cache.version, privacy: .public) != \(cacheVersion, privacy: .public); ignoring")
            return nil
        }
        return cache
    }
}
