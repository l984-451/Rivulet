// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

#if DEBUG
import Foundation

/// App Store screenshot mode (`tools/screenshots/shoot.sh`), DEBUG only. Launch args:
/// `-screenshotToken T -screenshotServer URL` sign in and show only libraries titled
/// "…-demo" (suffix stripped); `-screenshotTab` and `-screenshotOpen <library or title>`
/// pick the state to shoot.
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
    }

    static func demoLibraries(_ libraries: [PlexLibrary]) -> [PlexLibrary] {
        guard isOn else { return libraries }
        return libraries.compactMap { library in
            guard library.title.hasSuffix(demoSuffix) else { return nil }
            var copy = library
            copy.title = String(library.title.dropLast(demoSuffix.count))
            return copy
        }
    }

    static func demoHubs(_ hubs: [PlexHub]) -> [PlexHub] {
        hubs.map { hub in
            var copy = hub
            copy.title = hub.title?.replacingOccurrences(of: demoSuffix, with: "")
            return copy
        }
    }

    static func demoItems(_ items: [PlexMetadata], libraries: [PlexLibrary]) -> [PlexMetadata] {
        guard isOn else { return items }
        let keys = Set(libraries.map(\.key))
        return items.filter { $0.librarySectionID.map { keys.contains(String($0)) } ?? false }
    }
}
#endif
