// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

extension OtherServerKind {
    /// The extra Plex servers, and each other kind's server only while it is that kind's signed-in account
    /// (`accountIDs`, empty for a restricted profile); a registry entry left over from a sign-out is dropped.
    static func shown(_ providers: [any MediaProvider], accountIDs: [MediaProviderKind: String]) -> [any MediaProvider] {
        providers.filter { $0.kind == .plex || accountIDs[$0.kind] == $0.id }
    }

    /// Live streams from a Jellyfin or Emby server need their teardown: the closers release a stream
    /// the server holds open once its player is done with it.
    @MainActor
    static func installLiveSessionClosers() {
        PlexLiveTimelineKeepalive.otherSessionClosers[MediaProviderKind.jellyfin.rawValue] = { JellyfinLiveTVProvider.closeLiveStream($0) }
        PlexLiveTimelineKeepalive.otherSessionClosers[MediaProviderKind.emby.rawValue] = { EmbyLiveTVProvider.closeLiveStream($0) }
    }

    /// Both apps call this at launch and after every sign-in, sign-out and profile change. It installs the
    /// stream closers and puts each signed-in server's Live TV in or out of Live TV; a restricted profile
    /// sees none. `secondary` and `accounts` default to the registry and the stored accounts.
    @MainActor
    static func configureLiveTV(
        secondary: [any MediaProvider]? = nil,
        accounts: [MediaProviderKind: String]? = nil,
        restricted: Bool,
        sync: (OtherServerKind, (any MediaProvider)?) -> Void = { $0.syncLiveTV($1) }
    ) {
        installLiveSessionClosers()
        let accountIDs: [MediaProviderKind: String] = restricted ? [:] : accounts ?? Dictionary(
            uniqueKeysWithValues: all.compactMap { other in other.account().map { (other.kind, $0.providerID) } })
        let shown = shown(secondary ?? MediaProviderRegistry.shared.secondaryProviders, accountIDs: accountIDs)
        for other in all { sync(other, shown.first { $0.kind == other.kind }) }
    }
}
