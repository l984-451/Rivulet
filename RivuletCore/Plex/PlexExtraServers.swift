// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexExtraServers.swift
//  Rivulet
//
//  The account's Plex servers other than the selected one (#87), for both apps:
//  tvOS makes each a PlexProvider, iOS a server in IOSPlexSession. The list
//  belongs to the profile whose plex.tv token fetched it, because a Home
//  profile sees its own servers with its own tokens.
//

import Foundation

@MainActor
final class PlexExtraServers {
    static let shared = PlexExtraServers()

    struct Server: Codable, Equatable {
        let machineID: String
        let name: String
        let url: String
        var providerID: String { "plex:\(machineID)" }
    }

    private struct Stored: Codable {
        let ownerID: Int
        let servers: [Server]
    }

    /// Set by the host: the list or a token changed (tvOS rebuilds its providers
    /// and reloads Home, iOS refetches).
    static var onChanged: (@MainActor () -> Void)?

    private let defaultsKey = "plexExtraServers"
    private var stored: Stored?
    private var lastRefresh: (ownerID: Int, at: Date)?

    private init() {
        stored = UserDefaults.standard.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
    }

    /// The servers to show now: only the current profile's, and none while a
    /// profile waits for its PIN.
    var current: [Server] {
        let auth = PlexAuthManager.shared
        guard let stored, !auth.isContentWithheld, stored.ownerID == auth.contentOwnerID else { return [] }
        // The URL check covers a list saved before the selected server's id was known.
        return stored.servers.filter {
            $0.machineID != auth.selectedServerMachineID && $0.url != auth.selectedServerURL && isEnabled(machineID: $0.machineID)
        }
    }

    /// Servers turned off in Settings, by machine id. Survives refreshes and sign-out.
    private let disabledKey = "plexDisabledServers"

    func isEnabled(machineID: String) -> Bool {
        !(UserDefaults.standard.stringArray(forKey: disabledKey) ?? []).contains(machineID)
    }

    /// iCloud changed the list of servers turned off: apply it as a tap in Settings would.
    func syncedPreferencesChanged(_ keys: Set<String>) {
        guard keys.contains(disabledKey) else { return }
        Self.onChanged?()
        LiveTVDataStore.shared.plexContentTokenChanged()
        lastRefresh = nil
        refreshForAccount()
    }

    func setEnabled(_ enabled: Bool, machineID: String) {
        var disabled = Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? [])
        if enabled { disabled.remove(machineID) } else { disabled.insert(machineID) }
        UserDefaults.standard.set(disabled.sorted(), forKey: disabledKey)
        Self.onChanged?()
        LiveTVDataStore.shared.plexContentTokenChanged()
        // A server that was the selected one is not in the stored list yet.
        if enabled {
            lastRefresh = nil
            refreshForAccount()
        }
    }

    func token(for server: Server) -> String? {
        KeychainHelper.get(Self.tokenKey(server))
    }

    /// The tvOS `CredentialScope.server` key, so tokens saved before the move still read.
    private static func tokenKey(_ server: Server) -> String { "server.token.\(server.providerID)" }

    /// Launch without a Home profile switch: the account's own token reaches its servers.
    func refreshForAccount() {
        let auth = PlexAuthManager.shared
        guard let token = auth.authToken, auth.contentOwnerID == 0, !auth.isContentWithheld else { return }
        Task { await refresh(plexToken: token) }
    }

    /// Fetches the profile's servers from plex.tv and probes each for a working
    /// connection, in parallel. A server plex.tv lists but that does not answer
    /// keeps its last URL, so a blip does not empty its sidebar section.
    func refresh(plexToken: String) async {
        let auth = PlexAuthManager.shared
        let owner = auth.contentOwnerID
        if let lastRefresh, lastRefresh.ownerID == owner, Date().timeIntervalSince(lastRefresh.at) < 60 { return }
        lastRefresh = (owner, Date())
        guard let devices = try? await PlexNetworkManager.shared.getServers(authToken: plexToken) else {
            lastRefresh = nil
            return
        }
        // Not `selectedServerMachineID` alone: installs from before it was saved have none.
        let primary = auth.selectedServer(in: devices)?.machineIdentifier ?? auth.selectedServerMachineID
        let candidates = devices.filter { $0.machineIdentifier != nil && $0.machineIdentifier != primary && $0.accessToken != nil }
        let previous = stored?.ownerID == owner ? stored?.servers ?? [] : []
        let probed = await withTaskGroup(of: (PlexDevice, String?).self) { group in
            for device in candidates {
                group.addTask { await (device, auth.findBestConnection(for: device, reuseLastGood: false)) }
            }
            return await group.reduce(into: [:]) { $0[$1.0.machineIdentifier ?? ""] = $1.1 }
        }
        // The profile changed while probing: these servers are not its.
        guard owner == auth.contentOwnerID else { return }
        var servers: [Server] = []
        var tokenChanged = false
        for device in candidates {
            guard let id = device.machineIdentifier, let token = device.accessToken,
                  let url = probed[id] ?? previous.first(where: { $0.machineID == id })?.url else { continue }
            let server = Server(machineID: id, name: device.name, url: url)
            if self.token(for: server) != token {
                tokenChanged = true
                _ = KeychainHelper.set(token, forKey: Self.tokenKey(server))
            }
            servers.append(server)
        }
        servers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        save(Stored(ownerID: owner, servers: servers), force: tokenChanged)
    }

    /// Sign-out: forget the servers and their tokens.
    func clear() {
        for server in stored?.servers ?? [] {
            _ = KeychainHelper.delete(Self.tokenKey(server))
        }
        save(nil, force: false)
        lastRefresh = nil
    }

    private func save(_ new: Stored?, force: Bool) {
        let changed = force || new?.servers != stored?.servers || new?.ownerID != stored?.ownerID
        stored = new
        if let new, let data = try? JSONEncoder().encode(new) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
        guard changed else { return }
        Self.onChanged?()
        LiveTVDataStore.shared.plexContentTokenChanged()
    }
}
