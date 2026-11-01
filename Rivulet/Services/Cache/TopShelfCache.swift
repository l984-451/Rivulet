// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TopShelfCache.swift
//  Rivulet
//
//  Manages shared cache for Top Shelf extension via App Groups
//

import Foundation
import TVServices

/// Manages read/write access to Top Shelf data in the shared App Group container
/// Used by both the main app (write) and TV Services Extension (read)
final class TopShelfCache: Sendable {
    static let shared = TopShelfCache()

    private let appGroupIdentifier = "group.com.bain.Rivulet"
    private let cacheFileName = "top_shelf_items.json"

    private init() {}

    // MARK: - Container Access

    private var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    private var cacheFileURL: URL? {
        containerURL?.appendingPathComponent(cacheFileName)
    }

    // MARK: - UserDefaults Suite (more reliable than file access)

    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    private let userDefaultsKey = "topShelfItems"

    // MARK: - Write (Main App)

    /// Write Top Shelf items to the shared container
    /// Called by PlexDataStore when Continue Watching data is refreshed
    /// `recent` is the poster row's second group, Recently Added after Continue Watching.
    func writeItems(_ items: [TopShelfItem], sectionTitle: String, recent: [TopShelfItem]) {

        guard let defaults = sharedDefaults else {
            return
        }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(items)
            let recentData = try encoder.encode(recent)
            guard defaults.data(forKey: userDefaultsKey) != data
                    || defaults.data(forKey: "topShelfRecentItems") != recentData
                    || defaults.string(forKey: "topShelfSectionTitle") != sectionTitle else { return }
            defaults.set(data, forKey: userDefaultsKey)
            defaults.set(recentData, forKey: "topShelfRecentItems")
            defaults.set(sectionTitle, forKey: "topShelfSectionTitle")
            defaults.set(Date().timeIntervalSince1970, forKey: "topShelfWrittenAt")
            defaults.synchronize()
            // Without this tvOS keeps whatever the extension last returned, nil before first sign-in (#364).
            TVTopShelfContentProvider.topShelfContentDidChange()

            // Debug: print first item
        } catch {
        }
    }

    // MARK: - Read (Extension)

    /// Read Top Shelf items from the shared container
    /// Called by TV Services Extension to display items
    func readItems() -> [TopShelfItem] {
        guard let defaults = sharedDefaults else {
            return []
        }

        guard let data = defaults.data(forKey: userDefaultsKey) else {
            return []
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let items = try decoder.decode([TopShelfItem].self, from: data)
            return items
        } catch {
            return []
        }
    }

    // MARK: - Style

    /// Full screen carousel instead of the default poster row. The extension reads the same key.
    var fullScreen: Bool {
        get { sharedDefaults?.bool(forKey: "topShelfFullScreen") ?? false }
        set {
            sharedDefaults?.set(newValue, forKey: "topShelfFullScreen")
            TVTopShelfContentProvider.topShelfContentDidChange()
        }
    }

    // MARK: - Clear

    /// Remove all cached Top Shelf items
    func clear() {
        guard sharedDefaults?.data(forKey: userDefaultsKey) != nil else { return }
        sharedDefaults?.removeObject(forKey: userDefaultsKey)
        sharedDefaults?.removeObject(forKey: "topShelfRecentItems")
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "topShelfClearedAt")
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    /// Diagnostics: the last write and clear, and the extension's last read (see its `noteRead`).
    func diagnostics() -> [String: Any] {
        guard let defaults = sharedDefaults else { return ["app_group": false] }
        let items = readItems()
        let composites = items.compactMap(\.compositeFileName)
        func age(_ key: String) -> Any {
            let t = defaults.double(forKey: key)
            return t > 0 ? Int(Date().timeIntervalSince1970 - t) : "never"
        }
        return [
            "app_group": containerURL != nil,
            "cached_items": items.count,
            "item_types": items.map(\.type),
            "items_from_selected_plex": items.filter { $0.serverIdentifier.hasPrefix("http") }.count,
            "composites_named": composites.count,
            "composites_on_disk": composites.filter { name in
                compositeFileURL(fileName: name).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            }.count,
            "written_seconds_ago": age("topShelfWrittenAt"),
            "cleared_seconds_ago": age("topShelfClearedAt"),
            "extension_read_seconds_ago": age("topShelfExtensionReadAt"),
            "extension_read_cached": defaults.object(forKey: "topShelfExtensionReadCached") ?? "never",
            "extension_read_returned": defaults.object(forKey: "topShelfExtensionReadReturned") ?? "never",
        ]
    }

    // MARK: - Composite image files (AppGroup/Library/Caches/TopShelf/*.jpg)

    // On tvOS only `Library/Caches` in the App Group container is writable, not its root.
    // Keep this path in sync with the extension's copy of this file.
    private var compositeDirName: String { "TopShelf" }

    /// The TopShelf composites directory, created if needed. nil if no container.
    func compositeDirectoryURL() -> URL? {
        guard let base = containerURL else { return nil }
        let dir = base
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent(compositeDirName, isDirectory: true)
        do {
            // `withIntermediateDirectories: true` is a no-op when it already
            // exists, so the fileExists pre-check bought nothing. Do NOT swallow
            // the error here: a silent mkdir failure is what hid this bug.
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("TopShelfCache: failed to create composites dir at \(dir.path): \(error)")
            return nil
        }
        return dir
    }

    func compositeFileURL(fileName: String) -> URL? {
        compositeDirectoryURL()?.appendingPathComponent(fileName)
    }

    @discardableResult
    func writeComposite(_ data: Data, fileName: String) -> Bool {
        guard let url = compositeFileURL(fileName: fileName) else { return false }
        do { try data.write(to: url, options: .atomic); return true }
        catch { print("TopShelfCache: failed to write composite \(fileName): \(error)"); return false }
    }

    /// Delete any *.jpg in the composites dir whose name is not in `fileNames`.
    func pruneComposites(keeping fileNames: Set<String>) {
        guard let dir = compositeDirectoryURL(),
              let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for url in contents where url.pathExtension.lowercased() == "jpg" {
            if !fileNames.contains(url.lastPathComponent) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
