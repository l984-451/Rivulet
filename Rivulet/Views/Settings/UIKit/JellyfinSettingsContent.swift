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
            let hasLiveTV = JellyfinLiveTVProvider.hiddenSource != nil
                || LiveTVDataStore.shared.sources.contains { $0.sourceType == .jellyfin }
            return [
                SettingsRowItem(id: "jellyfinServerInfo", title: "Server",
                                kind: .info(value: { account.serverName })),
            ] + (hasLiveTV ? [jellyfinLiveTVToggle(id: "jellyfinLiveTV")] : []) + [
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
        return jellyfinSteps(draft).map(\.row) + [
            SettingsRowItem(id: "jellyfinSignIn",
                            title: draft.status == .checking ? "Signing In…" : "Sign In",
                            kind: .action(destructive: false, handler: { vc in
                                signInJellyfin(draft, on: vc)
                            }))
        ]
    }

    /// The sign-in form's fields. Each row opens its own entry page.
    static func jellyfinSteps(_ draft: AddSourceDraft) -> [EntryStep] {
        [
            EntryStep(id: "jellyfinURL", title: "Server Address",
                      message: "Enter your Jellyfin server's address, with its port, "
                          + "for example http://192.168.1.100:8096.",
                      placeholder: "Required", keyboard: .URL, contentType: .URL,
                      value: { draft.serverURL }, set: { draft.serverURL = $0; draft.status = .idle }),
            EntryStep(id: "jellyfinUsername", title: "Username",
                      message: "Enter your Jellyfin username.",
                      placeholder: "Required", keyboard: .asciiCapable, contentType: .username,
                      value: { draft.username }, set: { draft.username = $0; draft.status = .idle }),
            // Not required: a Jellyfin user can have no password.
            EntryStep(id: "jellyfinPassword", title: "Password",
                      message: "Enter the password for this Jellyfin user. Leave it empty if the user has none.",
                      placeholder: "None", keyboard: .asciiCapable, contentType: .password, isSecure: true,
                      value: { draft.password }, set: { draft.password = $0; draft.status = .idle })
        ]
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
