// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  JellyfinSettingsContent.swift
//  Rivulet
//
//  Settings > Servers > Jellyfin Server. Signed out: a form built from the
//  same rows as the Live TV "My Own Server" page, sharing its draft and its
//  failure popup. Signed in: the server, the user, and Sign Out.
//

import Foundation
import UIKit

extension SettingsContent {

    static var jellyfin: [SettingsRowItem] {
        if let account = JellyfinSession.account {
            return [
                SettingsRowItem(id: "jellyfinServerInfo", title: "Server",
                                kind: .info(value: { account.serverName })),
                SettingsRowItem(id: "jellyfinUserInfo", title: "User",
                                kind: .info(value: { account.userName })),
                SettingsRowItem(id: "jellyfinSignOut", title: "Sign Out",
                                kind: .action(destructive: true, handler: { vc in
                    Task { @MainActor in
                        await JellyfinSession.signOut()
                        addSourceDraft = AddSourceDraft()
                        (vc as? SettingsPageViewController)?.reloadRows()
                    }
                }))
            ]
        }

        guard let draft = addSourceDraft else { return [] }
        let rows: [SettingsRowItem] = [
            SettingsRowItem(id: "jellyfinURL", title: "Server URL",
                            kind: .textEntry(value: { draft.serverURL },
                                             placeholder: "http://192.168.1.100:8096",
                                             hint: nil, suggestions: [], keyboardType: .URL,
                                             set: { draft.serverURL = $0; draft.status = .idle })),
            SettingsRowItem(id: "jellyfinUsername", title: "Username",
                            kind: .textEntry(value: { draft.username }, placeholder: "",
                                             hint: nil, suggestions: [], keyboardType: .asciiCapable,
                                             set: { draft.username = $0; draft.status = .idle })),
            SettingsRowItem(id: "jellyfinPassword", title: "Password",
                            kind: .textEntry(value: { draft.password }, placeholder: "",
                                             hint: nil, suggestions: [], keyboardType: .asciiCapable,
                                             isSecure: true,
                                             set: { draft.password = $0; draft.status = .idle })),
            SettingsRowItem(id: "jellyfinSignIn",
                            title: draft.status == .checking ? "Signing In…" : "Sign In",
                            kind: .action(destructive: false, handler: { vc in
                                signInJellyfin(draft, on: vc)
                            }))
        ]
        return rows
    }

    /// An empty password is allowed: Jellyfin users can have none.
    private static func signInJellyfin(_ draft: AddSourceDraft, on vc: UIViewController) {
        guard draft.status != .checking else { return }
        let page = vc as? SettingsPageViewController
        let username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: sanitizeURL(draft.serverURL)), !username.isEmpty else {
            fail(draft, page: page, title: "Couldn't Sign In", message: "Enter your server's address and your username.")
            return
        }
        draft.status = .checking
        page?.reloadRows()

        Task { @MainActor in
            do {
                _ = try await JellyfinSession.signIn(serverURL: url, username: username, password: draft.password)
                finish(page, draft: draft)
            } catch {
                fail(draft, page: page, title: "Couldn't Sign In", message: jellyfinFailureCopy(for: error))
            }
        }
    }

    static func jellyfinFailureCopy(for error: Error) -> String {
        switch error {
        case JellyfinSignInError.notJellyfin:
            "That address isn't a Jellyfin server. Check the port."
        case JellyfinSignInError.serverTooOld(let version):
            "This server runs Jellyfin \(version). Rivulet needs "
                + "\(JellyfinSession.minimumVersion.major).\(JellyfinSession.minimumVersion.minor) or newer."
        case JellyfinSignInError.untrustedCertificate:
            "This server's HTTPS certificate isn't trusted. Try its http:// address."
        case MediaProviderError.unauthorized:
            "Jellyfin didn't accept that username and password."
        default:
            "Couldn't reach that server. Check the address and port."
        }
    }
}
