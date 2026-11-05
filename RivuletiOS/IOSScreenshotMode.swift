// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

#if DEBUG
import Foundation

/// App Store screenshot mode (`tools/screenshots/shoot.sh`), DEBUG only. Launch args:
/// `-screenshotToken T -screenshotServer URL` sign in and show only libraries titled
/// "…-demo" (suffix stripped); `-screenshotTab` and `-screenshotOpen <library or title>`
/// pick the state to shoot; `-screenshotLiveTV` adds the demo Live TV source.
enum IOSScreenshotMode {
    private static let defaults = UserDefaults.standard
    static let demoSuffix = "-demo"

    static var isOn: Bool { defaults.string(forKey: "screenshotToken") != nil }
    static var tab: String? { defaults.string(forKey: "screenshotTab") }
    static var openTitle: String? { defaults.string(forKey: "screenshotOpen") }

    /// Must run before `PlexAuthManager.shared` first reads the Keychain.
    static func seedSession() {
        guard let token = defaults.string(forKey: "screenshotToken"),
              let server = defaults.string(forKey: "screenshotServer") else { return }
        KeychainHelper.set(token, forKey: "plexAuthToken")
        KeychainHelper.set(token, forKey: "selectedServerToken")
        defaults.set(server, forKey: "selectedServerURL")
        defaults.set(true, forKey: "plexHasPersistedSession")
        defaults.set(IOSChangelog.currentVersion, forKey: "lastSeenBuild")
        // `-screenshotLiveTV <base url>`: the demo source `livetv.py` writes and `shoot.sh` serves.
        if let base = defaults.string(forKey: "screenshotLiveTV") {
            let source = LiveTVDataStore.SourceConfiguration(
                id: "screenshot-demo", type: "m3u", name: "Demo", baseURL: nil,
                m3uURL: "\(base)/demo.m3u", epgURL: "\(base)/guide.xml", apiToken: nil)
            defaults.set(try? JSONEncoder().encode([source]), forKey: "liveTVSourceConfigurations")
        }
    }

    /// Only the demo libraries, renamed without the suffix, with the rows and Continue Watching items that belong to them.
    static func demo(_ home: HomeFeed.Assembled) -> HomeFeed.Assembled {
        guard isOn else { return home }
        let libraries = home.libraries.compactMap { library -> MediaLibrary? in
            guard library.title.hasSuffix(demoSuffix) else { return nil }
            var copy = MediaLibrary(id: library.id, providerID: library.providerID,
                                    title: String(library.title.dropLast(demoSuffix.count)), kind: library.kind)
            copy.browsesByFolder = library.browsesByFolder
            copy.isPinnedToHome = library.isPinnedToHome
            return copy
        }
        let keys = Set(libraries.map(\.id))
        let shelves = home.shelves.compactMap { hub -> MediaHub? in
            let items = hub.items.filter { $0.libraryID.map(keys.contains) ?? false }
            guard !items.isEmpty else { return nil }
            return MediaHub(id: hub.id, providerID: hub.providerID, title: hub.title.replacingOccurrences(of: demoSuffix, with: ""),
                            style: hub.style, items: items, pagingKey: hub.pagingKey, isPromoted: hub.isPromoted)
        }
        let continueWatching = home.continueWatching.map { $0.filter { $0.libraryID.map(keys.contains) ?? false } }
        return HomeFeed.Assembled(libraries: libraries, continueWatching: continueWatching, shelves: shelves)
    }

    /// Search results from the demo libraries only.
    static func demoItems(_ items: [MediaItem], libraries: [MediaLibrary]) -> [MediaItem] {
        guard isOn else { return items }
        let keys = Set(libraries.map(\.id))
        return items.filter { $0.libraryID.map(keys.contains) ?? false }
    }
}
#endif
