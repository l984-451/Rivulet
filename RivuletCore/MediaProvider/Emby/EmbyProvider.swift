// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyProvider.swift
//  Rivulet
//
//  Emby implementation of MediaProvider: one instance per signed-in server.
//  Browse, home rails, watch state and playback live in EmbyProvider+*.swift.
//

import Foundation
import os

final class EmbyProvider: MediaProvider, @unchecked Sendable {
    nonisolated let id: String
    nonisolated let kind: MediaProviderKind = .emby
    nonisolated let displayName: String
    let connectionState: ConnectionState = .connected
    let supportsWatchlist = false

    let userID: String
    /// The rights read at sign-in; `currentPolicy()` re-reads them once per launch.
    let policy: EmbySession.Policy
    let client: EmbyClient

    /// The user's `Policy` as the server reports it now, cached after the first good read.
    let livePolicy = OSAllocatedUnfairLock<EmbySession.Policy?>(initialState: nil)

    /// PlaySessionId to the device id of each hls transcode handed out, so the reporter (built
    /// from the protocol, which cannot see the stream kind) can say Transcode and stop the encode.
    let transcodeSessions = OSAllocatedUnfairLock(initialState: [String: String]())

    init(serverID: String, displayName: String, userID: String, policy: EmbySession.Policy, client: EmbyClient) {
        self.id = "emby:\(serverID)"
        self.displayName = displayName
        self.userID = userID
        self.policy = policy
        self.client = client
    }

    var accountID: String? { userID }

    var baseURL: URL { client.baseURL }

    func map(_ dtos: [EmbyItem]?) -> [MediaItem] {
        (dtos ?? []).map { EmbyMediaMapper.item($0, providerID: id, baseURL: baseURL) }
    }

    /// The signed-in user's rights. A failed read keeps the sign-in policy and is not cached,
    /// so the next question asks again.
    func currentPolicy() async -> EmbySession.Policy {
        if let known = livePolicy.withLock({ $0 }) { return known }
        guard let user: EmbyUser = try? await client.get("Users/\(userID)") else { return policy }
        let fresh = EmbySession.Policy(user.policy)
        livePolicy.withLock { $0 = fresh }
        return fresh
    }
}

// MARK: - Watchlist

extension EmbyProvider {
    private static var noWatchlist: MediaProviderError { .backendSpecific(underlying: "Emby has no watchlist") }

    func isOnWatchlist(_ ref: MediaItemRef) async -> Bool { false }
    func addToWatchlist(_ ref: MediaItemRef) async throws { throw Self.noWatchlist }
    func removeFromWatchlist(_ ref: MediaItemRef) async throws { throw Self.noWatchlist }
}
