// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Account plumbing the shell needs: profile hooks, connection health, server list.
extension IOSPlexSession {
    /// iOS side of the profile handoff (tvOS sets the same hooks in RivuletApp.init).
    func installProfileHooks() {
        PlexUserProfileManager.onProfileChanged = { [weak self] in
            self?.contentSessionChanged()
            await self?.refresh()
        }
        // The first selection swaps in the profile's server token, so content loaded with the admin token is stale.
        PlexUserProfileManager.onInitialProfileSelected = { [weak self] in
            Task { await self?.refresh() }
        }
    }

    /// Re-tests the saved connection, failing over when it died, and reloads content when it moved.
    func verifyConnection() async {
        guard auth.authToken != nil else { return }
        let before = auth.selectedServerURL
        await auth.verifyAndFixConnection()
        let moved = auth.selectedServerURL != before
        // Failover installs the owner's token; put the selected profile's back.
        if moved { await reapplySelectedProfile() }
        if moved { await refresh() }
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

    /// Whether `server` is the one in use. `selectedServer` is unset after relaunch, so fall back to URL and name.
    func isCurrentServer(_ server: PlexDevice) -> Bool {
        let auth = PlexAuthManager.shared
        if let current = auth.selectedServer { return current.clientIdentifier == server.clientIdentifier }
        if let url = auth.selectedServerURL, server.connections?.contains(where: { $0.uri == url }) == true {
            return true
        }
        return server.name == auth.savedServerName
    }

    /// Switches servers. Returns false when no connection to it worked.
    func switchServer(to server: PlexDevice) async -> Bool {
        guard await PlexAuthManager.shared.selectServer(server) else {
            // The old server is still selected; reload clears the failed state the attempt left behind.
            await refresh()
            return false
        }
        contentSessionChanged()
        await reapplySelectedProfile()
        await refresh()
        return true
    }

    /// Re-selects a non-admin profile after something installed the account token.
    private func reapplySelectedProfile() async {
        let profiles = PlexUserProfileManager.shared
        guard profiles.hasLoadedProfiles else { await profiles.fetchHomeUsers(); return }
        guard let user = profiles.selectedUser, !user.admin else { return }
        let restored = user.requiresPin
            ? await profiles.selectUserWithRememberedPin(user).success
            : await profiles.selectUser(user)
        if !restored { profiles.selectedUser = profiles.homeUsers.first(where: \.admin) }
    }
}
