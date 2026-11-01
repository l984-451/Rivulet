// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  DeepLinkHandler.swift
//  Rivulet
//
//  Handles deep links from Top Shelf, Siri intents, and other URL schemes
//

import Foundation
import Combine

@MainActor
final class DeepLinkHandler: ObservableObject {
    static let shared = DeepLinkHandler()

    @Published var pendingPlayback: PlexMetadata?
    @Published var pendingDetail: PlexMetadata?
    /// A link to another server's item (Jellyfin, another Plex server), resolved through its provider.
    @Published var pendingProviderLink: ProviderLink?

    struct ProviderLink: Equatable {
        let action: RivuletLink.Action
        let item: MediaItem
    }

    /// The link waiting for the app to be ready. A newer link replaces it.
    private(set) var heldLink: RivuletLink?

    /// Set by the shell: true once the launch profile gate has passed, false
    /// while a profile picker or PIN prompt withholds content.
    var isShellReady = false {
        didSet { if isShellReady { deliverHeldLink() } }
    }

    // Seams for tests.
    var credentials: () -> (serverURL: String, token: String)? = {
        guard let serverURL = PlexAuthManager.shared.selectedServerURL,
              let token = PlexAuthManager.shared.selectedServerToken else { return nil }
        return (serverURL, token)
    }
    var fetch: (_ ratingKey: String, _ serverURL: String, _ token: String) async throws -> PlexMetadata = {
        try await PlexNetworkManager.shared.getMetadata(serverURL: $1, authToken: $2, ratingKey: $0)
    }
    var reconnect: () async -> Void = { await PlexAuthManager.shared.verifyAndFixConnection() }
    var isSignedIn: () -> Bool = { PlexAuthManager.shared.hasCredentials }
    var provider: (_ id: String) -> (any MediaProvider)? = { MediaProviderRegistry.shared.provider(for: $0) }

    init() {}

    // MARK: - Entry points

    func handle(url: URL) {
        guard let link = RivuletLink(url: url) else { return }
        handle(link)
    }

    func handlePlay(ratingKey: String) {
        handle(RivuletLink(.play, ratingKey: ratingKey))
    }

    func handleDetail(ratingKey: String) {
        handle(RivuletLink(.detail, ratingKey: ratingKey))
    }

    @discardableResult
    func handle(_ link: RivuletLink) -> Task<Void, Never>? {
        // Signed out there is nothing to wait for: holding it would fire at the next sign-in.
        guard isSignedIn() || providerID(of: link) != nil else { return nil }
        // Any app can open a link, and the key is interpolated into a server path.
        guard link.ratingKey.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        DiagLog.notice(.deepLink, "Link \(link.action) \(link.ratingKey) on \(providerID(of: link).map { String($0.prefix { $0 != ":" }) } ?? "selected plex"), shell ready=\(isShellReady)")
        heldLink = link
        return deliverHeldLink()
    }

    /// Sign-out: a link held behind the profile prompt must not fire for the next account.
    func dropHeldLink() { heldLink = nil }

    // MARK: - Delivery

    /// Resolves the held link once the shell is ready and a content token
    /// exists. Until then it stays held; the shell calls this again.
    @discardableResult
    func deliverHeldLink() -> Task<Void, Never>? {
        guard isShellReady, let link = heldLink, credentials() != nil || providerID(of: link) != nil else { return nil }
        heldLink = nil
        return Task { await resolve(link) }
    }

    private func resolve(_ link: RivuletLink) async {
        if let id = providerID(of: link) { return await resolve(link, providerID: id) }
        let token = credentials()?.token
        var metadata = await metadata(for: link)
        if metadata == nil {
            // A saved server address that stopped answering (cold launch): reconnect, retry once.
            await reconnect()
            metadata = await self.metadata(for: link)
        }
        // A profile prompt or switch happened while fetching: fetch again as the current profile.
        guard isShellReady, credentials()?.token == token else {
            if heldLink == nil { heldLink = link }
            deliverHeldLink()
            return
        }
        guard let metadata else {
            DiagLog.error(.deepLink, "Could not resolve \(link.ratingKey)")
            return
        }
        switch link.action {
        case .play: pendingPlayback = metadata
        case .detail: pendingDetail = metadata
        }
    }

    private func resolve(_ link: RivuletLink, providerID id: String) async {
        let ref = MediaItemRef(providerID: id, itemID: link.ratingKey)
        guard let provider = provider(id), let item = try? await provider.fullDetail(for: ref).item else {
            DiagLog.error(.deepLink, "Could not resolve \(link.ratingKey) on \(id.prefix { $0 != ":" })")
            return
        }
        // A profile prompt came up while fetching: hold it for the shell.
        guard isShellReady else {
            if heldLink == nil { heldLink = link }
            return
        }
        pendingProviderLink = ProviderLink(action: link.action, item: item)
    }

    /// The server a link names when it is not the selected Plex server (Jellyfin,
    /// another Plex server). The selected server's links carry its URL, informational.
    private func providerID(of link: RivuletLink) -> String? {
        guard let server = link.server, server.hasPrefix("plex:") || server.hasPrefix("jellyfin:"),
              !MediaItemRef(providerID: server, itemID: link.ratingKey).isPlex else { return nil }
        return server
    }

    private func metadata(for link: RivuletLink) async -> PlexMetadata? {
        guard let (serverURL, token) = credentials() else { return nil }
        return try? await fetch(link.ratingKey, serverURL, token)
    }
}
