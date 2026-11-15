// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AccountName.swift
//  Rivulet
//
//  The name the signed-in person goes by: the tvOS sidebar's profile row and
//  the iOS account button. Plex first, then the other servers, so a Jellyfin
//  or Emby sign-in without Plex still has a name.
//

import Foundation

enum AccountName {
    /// The first non-empty of: the Plex profile, the Plex account, then each other server's
    /// user in `OtherServerKind.all` order. Nil when none is signed in; each app picks its fallback.
    static func resolve(plexProfile: String?, plexUser: String?, otherServerUsers: [String?]) -> String? {
        ([plexProfile, plexUser] + otherServerUsers).lazy.compactMap { $0 }.first { !$0.isEmpty }
    }

    /// The signed-in user of each other server kind (Jellyfin, Emby), nil where signed out.
    @MainActor static var otherServerUsers: [String?] {
        OtherServerKind.all.map { $0.userName() }
    }
}
