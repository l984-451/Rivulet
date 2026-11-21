// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  OtherServerKind.swift
//  Rivulet
//
//  What each server kind beside the selected Plex one supplies to the
//  registries and `ServerDataStore`: one account per kind. A new kind adds one
//  entry to `all`, in `MediaProviderKind` order.
//

import Foundation

struct OtherServerKind {
    let kind: MediaProviderKind
    /// The signed-in account, read without building a provider (the sidebar's first render).
    let account: () -> (providerID: String, name: String)?
    /// The video provider rebuilt from the stored account; nil when signed out.
    let storedProvider: () -> (any MediaProvider)?
    let storedMusicProvider: () -> (any MusicProvider)?
    /// Whether two music providers are one account, so its caches stay.
    let isSameMusicAccount: (any MusicProvider, any MusicProvider) -> Bool
    /// Puts the server's Live TV in or out of Live TV, given the signed-in provider or nil.
    let syncLiveTV: ((any MediaProvider)?) -> Void
    /// The signed-in user's name, for an account page.
    let userName: () -> String?
    /// Address, username, password. Registers the provider on success.
    let signIn: (URL, String, String) async throws -> Void
    /// Sign-in by a code approved on another device; nil where the server has none. Hands the code to the closure.
    let quickConnect: ((URL, (String) -> Void) async throws -> Void)?
    /// Nil scope is a sign-out nobody was asked about: this device only.
    let signOut: (SignOutScope?) async -> Void
    /// What a failed sign-in tells the user.
    let failureMessage: (Error) -> String
    let quickConnectFailureMessage: (Error) -> String
    /// Every signed-in user of the server, the active one first (`EmbySession.users`, `JellyfinSession.users`).
    let users: () -> [ServerUser]
    /// Username, password: another user of the signed-in server, kept beside the active one.
    let addUser: (String, String) async throws -> Void
    /// `addUser` by a code approved on a device signed in as that user; nil where the server has none.
    let addUserWithQuickConnect: (((String) -> Void) async throws -> Void)?
    /// Makes a kept user the active one. False when nothing changed.
    let switchUser: (String) async -> Bool
    let removeUser: (String) async -> Void

    struct ServerUser: Identifiable, Equatable {
        let id: String
        let name: String
        let isActive: Bool
    }

    static let all: [OtherServerKind] = [.jellyfin, .emby]

    static func entry(for kind: MediaProviderKind) -> OtherServerKind? {
        all.first { $0.kind == kind }
    }

    static let jellyfin = OtherServerKind(
        kind: .jellyfin,
        account: { JellyfinSession.account.map { ($0.providerID, $0.serverName) } },
        storedProvider: { JellyfinSession.storedProvider() },
        storedMusicProvider: { JellyfinSession.storedProvider().map(JellyfinMusicProvider.init) },
        isSameMusicAccount: { ($0 as? JellyfinMusicProvider)?.client.token == ($1 as? JellyfinMusicProvider)?.client.token },
        syncLiveTV: { JellyfinLiveTVProvider.sync($0 as? JellyfinProvider) },
        userName: { JellyfinSession.account?.userName },
        signIn: { _ = try await JellyfinSession.signIn(serverURL: $0, username: $1, password: $2) },
        quickConnect: { url, showCode in _ = try await JellyfinSession.signInWithQuickConnect(serverURL: url, showCode: showCode) },
        signOut: { await JellyfinSession.signOut(scope: $0) },
        failureMessage: JellyfinSession.failureMessage,
        quickConnectFailureMessage: JellyfinSession.quickConnectFailureMessage,
        users: { JellyfinSession.users.map { ServerUser(id: $0.userID, name: $0.userName, isActive: $0.userID == JellyfinSession.account?.userID) } },
        addUser: { _ = try await JellyfinSession.addUser(username: $0, password: $1) },
        addUserWithQuickConnect: { showCode in _ = try await JellyfinSession.addUserWithQuickConnect(showCode: showCode) },
        switchUser: { await JellyfinSession.switchUser(to: $0) },
        removeUser: { await JellyfinSession.removeUser($0) }
    )

    static let emby = OtherServerKind(
        kind: .emby,
        account: { EmbySession.account.map { ($0.providerID, $0.serverName) } },
        storedProvider: { EmbySession.storedProvider() },
        storedMusicProvider: { EmbySession.storedProvider().map(EmbyMusicProvider.init) },
        isSameMusicAccount: { ($0 as? EmbyMusicProvider)?.client.token == ($1 as? EmbyMusicProvider)?.client.token },
        syncLiveTV: { EmbyLiveTVProvider.sync($0 as? EmbyProvider) },
        userName: { EmbySession.account?.userName },
        signIn: { _ = try await EmbySession.signIn(serverURL: $0, username: $1, password: $2) },
        quickConnect: nil,
        signOut: { await EmbySession.signOut(scope: $0) },
        failureMessage: EmbySession.failureMessage,
        quickConnectFailureMessage: EmbySession.failureMessage,
        users: { EmbySession.users.map { ServerUser(id: $0.userID, name: $0.userName, isActive: $0.userID == EmbySession.account?.userID) } },
        addUser: { _ = try await EmbySession.addUser(username: $0, password: $1) },
        addUserWithQuickConnect: nil,
        switchUser: { await EmbySession.switchUser(to: $0) },
        removeUser: { await EmbySession.removeUser($0) }
    )
}
