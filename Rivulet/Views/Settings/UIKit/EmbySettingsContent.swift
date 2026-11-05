// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbySettingsContent.swift
//  Rivulet
//
//  Settings > Servers > Emby Server. The Jellyfin page's shape: signed out, a
//  form of EntryStep rows sharing the add-source draft and failure popup;
//  signed in, the server, the user, Refresh and Sign Out. No Quick Connect.
//

import Foundation
import UIKit

extension SettingsContent {

    static var emby: [SettingsRowItem] {
        if let account = EmbySession.account {
            return [
                SettingsRowItem(id: "embyServerInfo", title: "Server",
                                kind: .info(value: { account.serverName })),
                SettingsRowItem(id: "embyUserInfo", title: "User",
                                kind: .info(value: { account.userName })),
                SettingsRowItem(id: "embyRefresh", title: "Refresh",
                                kind: .action(destructive: false, handler: { vc in
                    let page = vc as? SettingsPageViewController
                    ServerDataStore.shared.reload()
                    page?.reloadRows()
                    Task { @MainActor [weak page] in
                        for await loading in ServerDataStore.shared.$isLoading.values where !loading { break }
                        page?.reloadRows()
                    }
                }), isBusy: { ServerDataStore.shared.isLoading }),
                SettingsRowItem(id: "embySignOut", title: "Sign Out",
                                kind: .action(destructive: true, handler: { vc in
                    Task { @MainActor in
                        await EmbySession.signOut()
                        addSourceDraft = AddSourceDraft()
                        (vc as? SettingsPageViewController)?.reloadRows()
                    }
                }))
            ]
        }

        guard let draft = addSourceDraft else { return [] }
        return embySteps(draft).map(\.row) + [
            SettingsRowItem(id: "embySignIn",
                            title: draft.status == .checking ? "Signing In…" : "Sign In",
                            kind: .action(destructive: false, handler: { vc in
                                signInEmby(draft, on: vc)
                            }))
        ]
    }

    static func embySteps(_ draft: AddSourceDraft) -> [EntryStep] {
        [
            EntryStep(id: "embyURL", title: "Server Address",
                      message: "Enter your Emby server's address, with its port, for example http://192.168.1.100:8096.",
                      placeholder: "Required", keyboard: .URL, contentType: .URL,
                      value: { draft.serverURL }, set: { draft.serverURL = $0; draft.status = .idle }),
            EntryStep(id: "embyUsername", title: "Username",
                      message: "Enter your Emby username.",
                      placeholder: "Required", keyboard: .asciiCapable, contentType: .username,
                      value: { draft.username }, set: { draft.username = $0; draft.status = .idle }),
            // Not required: an Emby user can have no password.
            EntryStep(id: "embyPassword", title: "Password",
                      message: "Enter the password for this Emby user. Leave it empty if the user has none.",
                      placeholder: "None", keyboard: .asciiCapable, contentType: .password, isSecure: true,
                      value: { draft.password }, set: { draft.password = $0; draft.status = .idle })
        ]
    }

    private static func signInEmby(_ draft: AddSourceDraft, on vc: UIViewController) {
        guard draft.status != .checking else { return }
        let page = vc as? SettingsPageViewController
        let username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: sanitizeURL(draft.serverURL)), !username.isEmpty else {
            fail(draft, page: page, title: String(localized: "Couldn't Sign In"),
                 message: String(localized: "Enter your server's address and your username."))
            return
        }
        draft.status = .checking
        page?.reloadRows()

        Task { @MainActor in
            do {
                _ = try await EmbySession.signIn(serverURL: url, username: username, password: draft.password)
                finish(page, draft: draft)
            } catch {
                fail(draft, page: page, title: String(localized: "Couldn't Sign In"), message: embyFailureCopy(for: error))
            }
        }
    }

    static func embyFailureCopy(for error: Error) -> String {
        switch error {
        case EmbySignInError.notEmby:
            String(localized: "That address isn't an Emby server. Check the port.")
        case EmbySignInError.isJellyfin:
            String(localized: "That's a Jellyfin server. Sign in to it under Jellyfin Server.")
        case EmbySignInError.serverTooOld(let version):
            String(localized: "This server runs Emby \(version). Rivulet needs \(EmbySession.minimumVersion.major).\(EmbySession.minimumVersion.minor) or newer.")
        case JellyfinSignInError.untrustedCertificate:
            String(localized: "This server's HTTPS certificate isn't trusted. Try its http:// address.")
        case MediaProviderError.unauthorized:
            String(localized: "Emby didn't accept that username and password.")
        default:
            String(localized: "Couldn't reach that server. Check the address and port.")
        }
    }
}
