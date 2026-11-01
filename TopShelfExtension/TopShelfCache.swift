// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TopShelfCache.swift
//  Rivulet
//
//  Manages shared cache for Top Shelf extension via App Groups
//

import Foundation

/// Manages read/write access to Top Shelf data in the shared App Group container
/// Used by both the main app (write) and TV Services Extension (read)
final class TopShelfCache: Sendable {
    static let shared = TopShelfCache()

    private let appGroupIdentifier = "group.com.bain.Rivulet"

    private init() {}

    // MARK: - Container Access

    private var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    // MARK: - UserDefaults Suite (more reliable than file access)

    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    private let userDefaultsKey = "topShelfItems"

    // MARK: - Write (Main App)

    /// Write Top Shelf items to the shared container
    /// Called by PlexDataStore when Continue Watching data is refreshed
    func writeItems(_ items: [TopShelfItem]) {
        print("TopShelfCache: Attempting to write \(items.count) items")

        guard let defaults = sharedDefaults else {
            print("TopShelfCache: Unable to access App Group UserDefaults - is the entitlement configured?")
            return
        }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            defaults.set(data, forKey: userDefaultsKey)
            defaults.synchronize()
            print("TopShelfCache: Successfully wrote \(items.count) items to UserDefaults")

            // Debug: print first item
            if let first = items.first {
                print("TopShelfCache: First item - \(first.title) (ratingKey: \(first.ratingKey))")
            }
        } catch {
            print("TopShelfCache: Failed to encode items: \(error)")
        }
    }

    // MARK: - Read (Extension)

    /// Read Top Shelf items from the shared container
    /// Called by TV Services Extension to display items
    func readItems(key: String? = nil) -> [TopShelfItem] {
        guard let defaults = sharedDefaults else {
            print("TopShelfCache: Unable to access App Group UserDefaults")
            return []
        }

        guard let data = defaults.data(forKey: key ?? userDefaultsKey) else {
            print("TopShelfCache: No cached items found")
            return []
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let items = try decoder.decode([TopShelfItem].self, from: data)
            print("TopShelfCache: Successfully read \(items.count) items")
            return items
        } catch {
            print("TopShelfCache: Failed to decode items: \(error)")
            return []
        }
    }

    /// Full screen carousel instead of the default poster row; set in the app's Settings.
    var fullScreen: Bool { sharedDefaults?.bool(forKey: "topShelfFullScreen") ?? false }

    /// The poster row's Recently Added group, shown after Continue Watching.
    func readRecentItems() -> [TopShelfItem] { readItems(key: "topShelfRecentItems") }

    /// "Continue Watching" or "Recently Added", written with the items.
    var sectionTitle: String? { sharedDefaults?.string(forKey: "topShelfSectionTitle") }

    /// Records each time tvOS asks for content, so app diagnostics can tell whether the extension runs at all.
    func noteRead(cached: Int, returned: Int) {
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "topShelfExtensionReadAt")
        sharedDefaults?.set(cached, forKey: "topShelfExtensionReadCached")
        sharedDefaults?.set(returned, forKey: "topShelfExtensionReadReturned")
    }

    // MARK: - Clear

    /// Remove all cached Top Shelf items
    func clear() {
        sharedDefaults?.removeObject(forKey: userDefaultsKey)
    }

    // MARK: - Composite image files (AppGroup/Library/Caches/TopShelf/*.jpg)

    // Read-side twin of the app's `TopShelfCache.compositeDirectoryURL()`. The
    // container root is not writable on tvOS, so the app writes composites under
    // `Library/Caches`; this path MUST match it or the extension finds nothing.
    private var compositeDirName: String { "TopShelf" }

    func compositeFileURL(fileName: String) -> URL? {
        containerURL?
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent(compositeDirName, isDirectory: true)
            .appendingPathComponent(fileName)
    }
}
