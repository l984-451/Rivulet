// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

#if DEBUG
import Foundation

/// DEBUG QA seed: `-screenshotToken T -screenshotServer URL` signs the Plex session in. Runs before `PlexAuthManager.shared` reads the Keychain.
enum MacDebugSeed {
    static func seedSession() {
        let defaults = UserDefaults.standard
        guard let token = defaults.string(forKey: "screenshotToken"),
              let server = defaults.string(forKey: "screenshotServer") else { return }
        KeychainHelper.set(token, forKey: "plexAuthToken")
        KeychainHelper.set(token, forKey: "selectedServerToken")
        defaults.set(server, forKey: "selectedServerURL")
        defaults.set(true, forKey: "plexHasPersistedSession")
        defaults.set(MacChangelog.currentVersion, forKey: "lastSeenBuild")
    }
}
#endif
