// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Account plumbing the shell needs: profile hooks, connection health, server list.
extension PlexSession {
    /// iOS side of the profile handoff (tvOS sets the same hooks in RivuletApp.init).
    func installProfileHooks() {
        PlexUserProfileManager.onProfileChanged = { [weak self] in
            guard let self else { return }
            contentSessionChanged()
            // Locked: nothing loads, and the last profile's rows must not stay up.
            if !isConfigured { clearContent() }
            await authChanged()
        }
        // The first selection confirms the profile's server token; reload under it.
        PlexUserProfileManager.onInitialProfileSelected = { [weak self] in
            Task { await self?.authChanged() }
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
            await authChanged()
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
        guard let token = PlexAuthManager.shared.authToken else { throw PlexSessionError.notConfigured }
        return try await PlexNetworkManager.shared.getServers(authToken: token)
    }

    func isCurrentServer(_ server: PlexDevice) -> Bool {
        PlexAuthManager.shared.isCurrentServer(server)
    }

    /// The selected server's name, with a count of the other servers that are on.
    var serversSummary: String? {
        guard let name = selectedServerName else { return nil }
        let others = PlexExtraServers.shared.current.count
        return others == 0 ? name : String(localized: "\(name) + \(others) more")
    }

    /// Whether a server's content shows. Several can be on at once (#87).
    func isServerEnabled(_ server: PlexDevice) -> Bool {
        server.machineIdentifier.map { PlexExtraServers.shared.isEnabled(machineID: $0) } ?? true
    }

    enum ServerToggleResult { case changed, onlyServer, unreachable }

    /// Turns a server on or off. Turning off the selected server first moves the selected
    /// role to another server that is on; the last server in use can only be signed out.
    func toggleServer(_ server: PlexDevice, among servers: [PlexDevice]) async -> ServerToggleResult {
        guard let id = server.machineIdentifier else { return .unreachable }
        let turningOff = isServerEnabled(server)
        if turningOff, isCurrentServer(server) {
            let others = servers.filter { $0.clientIdentifier != server.clientIdentifier && isServerEnabled($0) }
            guard !others.isEmpty else { return .onlyServer }
            var moved = false
            for other in others where await switchServer(to: other) {
                moved = true
                break
            }
            guard moved else { return .unreachable }
        }
        PlexExtraServers.shared.setEnabled(!turningOff, machineID: id)
        return .changed
    }

    /// Switches servers. If the app cannot connect, this returns false and the old server stays in use.
    func switchServer(to server: PlexDevice) async -> Bool {
        guard await PlexAuthManager.shared.selectServer(server) else { return false }
        contentSessionChanged()
        await authChanged()
        return true
    }
}

/// Why a server toggle did not take.
enum ServerNotice: Equatable {
    case onlyServer
    case unreachable(String)

    var title: String {
        switch self {
        case .onlyServer: String(localized: "Only Server in Use")
        case .unreachable: String(localized: "Couldn’t Turn Off")
        }
    }

    var message: String {
        switch self {
        case .onlyServer: String(localized: "Turn on another server first, or sign out of Plex.")
        case .unreachable(let name): String(localized: "No other server is reachable right now, so \(name) stays on.")
        }
    }
}
