// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Account plumbing the shell needs: profile hooks, connection health, server list.
extension IOSPlexSession {
    /// iOS side of the profile handoff (tvOS sets the same hooks in RivuletApp.init).
    func installProfileHooks() {
        PlexUserProfileManager.onProfileChanged = { [weak self] in
            guard let self else { return }
            contentSessionChanged()
            // Locked: nothing loads, and the last profile's rows must not stay up.
            if !isConfigured { clearContent() }
            await refresh()
        }
        // The first selection confirms the profile's server token; reload under it.
        PlexUserProfileManager.onInitialProfileSelected = { [weak self] in
            Task { await self?.refresh() }
        }
    }

    /// Re-tests the saved connection, failing over when it died, and reloads content when it moved.
    func verifyConnection() async {
        guard auth.authToken != nil else { return }
        // Content waits on the saved Home profile: enter it first, server reachable
        // or not. The profile hooks reload once it is in.
        if auth.isContentWithheld {
            await PlexUserProfileManager.shared.fetchHomeUsers()
        }
        let before = auth.selectedServerURL
        await auth.verifyAndFixConnection()
        let moved = auth.selectedServerURL != before
        if moved {
            await refresh()
        } else if auth.isConnected, await flushOfflineProgress() {
            await watchStateDidChange()
        }
    }

    /// Resumes sign-in where it stopped: server choice when a token exists, otherwise a new PIN.
    func retrySignIn() async {
        await PlexAuthManager.shared.retryAfterError()
    }

    /// Every server on the account, for the Account sheet's server picker.
    func accountServers() async throws -> [PlexDevice] {
        guard let token = PlexAuthManager.shared.authToken else { throw IOSPlexSessionError.notConfigured }
        return try await PlexNetworkManager.shared.getServers(authToken: token)
    }

    func isCurrentServer(_ server: PlexDevice) -> Bool {
        PlexAuthManager.shared.isCurrentServer(server)
    }

    /// Switches servers. If the app cannot connect, this returns false and the old server stays in use.
    func switchServer(to server: PlexDevice) async -> Bool {
        guard await PlexAuthManager.shared.selectServer(server) else { return false }
        contentSessionChanged()
        await refresh()
        return true
    }
}
