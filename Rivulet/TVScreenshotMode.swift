// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

#if DEBUG
import UIKit

/// README and App Store screenshot mode (`tools/screenshots/shoot-tv.sh`), DEBUG only. Launch args:
/// `-screenshotToken T -screenshotServer URL` sign in and show only libraries titled
/// "…-demo" (suffix stripped) and their items; `-screenshotLiveTV <base url>` adds the
/// demo Live TV source.
enum TVScreenshotMode {
    private static let defaults = UserDefaults.standard
    static let demoSuffix = "-demo"

    static var isOn: Bool { defaults.string(forKey: "screenshotToken") != nil }

    /// Must run before `PlexAuthManager.shared` first reads the Keychain.
    static func seedSession() {
        guard let token = defaults.string(forKey: "screenshotToken"),
              let server = defaults.string(forKey: "screenshotServer") else { return }
        KeychainHelper.set(token, forKey: "plexAuthToken")
        KeychainHelper.set(token, forKey: "selectedServerToken")
        defaults.set(server, forKey: "selectedServerURL")
        defaults.set(true, forKey: "plexHasPersistedSession")
        defaults.set(true, forKey: "setupComplete")
        let info = Bundle.main.infoDictionary
        defaults.set("\(info?["CFBundleShortVersionString"] as? String ?? "1.0") (\(info?["CFBundleVersion"] as? String ?? "1"))",
                     forKey: "lastSeenBuild")
        if let base = defaults.string(forKey: "screenshotLiveTV") {
            let source = LiveTVDataStore.SourceConfiguration(
                id: "screenshot-demo", type: "m3u", name: "Demo", baseURL: nil,
                m3uURL: "\(base)/demo.m3u", epgURL: "\(base)/guide.xml", apiToken: nil)
            defaults.set(try? JSONEncoder().encode([source]), forKey: "liveTVSourceConfigurations")
        }
    }

    /// `RIVULET_FOCUS_MOVES=down,down,…` after `RIVULET_FOCUS_DELAY` seconds (default 15): drives
    /// focus without a remote, for shots below the fold.
    static func runFocusMovesIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let moves = env["RIVULET_FOCUS_MOVES"] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Double(env["RIVULET_FOCUS_DELAY"] ?? "") ?? 15))
            guard let window = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow else { return }
            await DebugFocusDriver.run(moves, in: window)
        }
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

    /// Keeps only items from demo libraries, and drops rows left empty.
    static func demoHubs(_ hubs: [PlexHub]) -> [PlexHub] {
        guard isOn else { return hubs }
        return hubs.compactMap(demoHub)
    }

    /// A library's own rows: Plex names them after the library ("Recently Added in Movies-demo").
    static func demoTitles(_ hubs: [PlexHub]) -> [PlexHub] {
        guard isOn else { return hubs }
        return hubs.map { hub in
            var copy = hub
            copy.title = hub.title?.replacingOccurrences(of: demoSuffix, with: "")
            return copy
        }
    }

    static func demoHub(_ hub: PlexHub?) -> PlexHub? {
        guard isOn else { return hub }
        guard var copy = hub else { return nil }
        let items = (copy.Metadata ?? []).filter { $0.librarySectionTitle?.hasSuffix(demoSuffix) ?? false }
        guard !items.isEmpty else { return nil }
        copy.Metadata = items.map { item in
            var item = item
            item.librarySectionTitle = item.librarySectionTitle.map { String($0.dropLast(demoSuffix.count)) }
            return item
        }
        copy.title = copy.title?.replacingOccurrences(of: demoSuffix, with: "")
        return copy
    }
}
#endif
