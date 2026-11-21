// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbySettingsContent.swift
//  Rivulet
//
//  Settings > Servers > Emby Server. Signed out: the Jellyfin page's form
//  (shared draft and failure popup) without Quick Connect, which Emby lacks.
//  Signed in: the server, the user, Refresh and Sign Out.
//

import Combine
import Foundation
import UIKit

extension SettingsContent {

    private static var embyName: String { MediaProviderKind.emby.displayName }

    static var emby: [SettingsRowItem] {
        if let account = EmbySession.account {
            let hasLiveTV = EmbyLiveTVProvider.hiddenSource != nil
                || LiveTVDataStore.shared.sources.contains { $0.sourceType == .emby }
            return [
                SettingsRowItem(id: "embyServerInfo", title: "Server",
                                kind: .info(value: { account.serverName }))
            ] + (hasLiveTV ? [embyLiveTVToggle(id: "embyLiveTV")] : []) + [
            ] + embyUserRows(active: account) + [
                SettingsRowItem(id: "embyRefresh", title: "Refresh",
                                kind: .action(destructive: false, handler: { vc in
                    let page = vc as? SettingsPageViewController
                    // Every surface repaints from the server, favorites rows included (ServerDataStore reloads on it).
                    NotificationCenter.default.post(name: .plexDataNeedsRefresh, object: nil)
                    page?.reloadRows()
                    Task { @MainActor [weak page] in
                        for await loading in ServerDataStore.shared.$isLoading.values where !loading { break }
                        page?.reloadRows()
                    }
                }), isBusy: { ServerDataStore.shared.isLoading }),
                SettingsRowItem(id: "embySignOut", title: "Sign Out",
                                kind: .action(destructive: true, handler: { vc in
                    func signOut(_ scope: SignOutScope?) {
                        Task { @MainActor in
                            await EmbySession.signOut(scope: scope)
                            addSourceDraft = AddSourceDraft()
                            (vc as? SettingsPageViewController)?.reloadRows()
                        }
                    }
                    if CloudSync.shared.isSynced(accountID: account.providerID) {
                        presentSignOutChoice(
                            on: vc, title: String(localized: "Sign Out of Emby?"),
                            message: String(localized: "Your Emby sign-in is shared through iCloud. Sign out of this device only, or of every device?"),
                            thisDevice: { signOut(.thisDevice) }, everywhere: { signOut(.everywhere) })
                    } else {
                        signOut(nil)
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

    /// One row per signed-in user, the active one checked, when there is more than one;
    /// then Add User, and Remove User once there is someone to remove.
    private static func embyUserRows(active: EmbySession.Account) -> [SettingsRowItem] {
        let users = EmbySession.users
        let userRows: [SettingsRowItem] = users.count > 1
            ? users.sorted { $0.userName.localizedStandardCompare($1.userName) == .orderedAscending }.map { user in
                SettingsRowItem(id: "embyUser_\(user.userID)", verbatim: user.userName, kind: .selectable(
                    isSelected: { EmbySession.account?.userID == user.userID },
                    value: { nil },
                    handler: { vc in
                        Task { @MainActor in
                            await EmbySession.switchUser(to: user.userID)
                            (vc as? SettingsPageViewController)?.reloadRows()
                        }
                    }))
            }
            : [SettingsRowItem(id: "embyUserInfo", title: "User", kind: .info(value: { active.userName }))]
        return userRows + [
            SettingsRowItem(id: "embyAddUser", title: "Add User",
                            kind: .navigationAction(.embyAddUser, value: nil, prepare: { addSourceDraft = AddSourceDraft() }))
        ] + (EmbySession.savedUsers.isEmpty ? [] : [
            SettingsRowItem(id: "embyRemoveUser", title: "Remove User", kind: .navigation(.embyRemoveUser))
        ])
    }

    /// Settings > Emby Server > Add User: another user of the same server, signed in beside the active one.
    static var embyAddUser: [SettingsRowItem] {
        guard EmbySession.account != nil, let draft = addSourceDraft else { return [] }
        return Array(embySteps(draft).dropFirst()).map(\.row) + [
            SettingsRowItem(id: "embySignIn",
                            title: draft.status == .checking ? "Signing In…" : "Sign In",
                            kind: .action(destructive: false, handler: { vc in
                                addEmbyUser(draft, on: vc)
                            }))
        ]
    }

    /// Settings > Emby Server > Remove User: the users added beside the first one.
    static var embyRemoveUser: [SettingsRowItem] {
        EmbySession.savedUsers.map { user in
            SettingsRowItem(id: "embyRemove_\(user.userID)", verbatim: user.userName,
                            kind: .action(destructive: true, handler: { vc in
                Task { @MainActor in
                    await EmbySession.removeUser(user.userID)
                    let page = vc as? SettingsPageViewController
                    if EmbySession.savedUsers.isEmpty { page?.onPop?() } else { page?.reloadRows() }
                }
            }))
        }
    }

    private static func addEmbyUser(_ draft: AddSourceDraft, on vc: UIViewController) {
        guard draft.status != .checking else { return }
        let page = vc as? SettingsPageViewController
        let username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            fail(draft, page: page, title: String(localized: "Couldn't Sign In"),
                 message: String(localized: "Enter the username."))
            return
        }
        draft.status = .checking
        page?.reloadRows()
        Task { @MainActor in
            do {
                try await EmbySession.addUser(username: username, password: draft.password)
                finish(page, draft: draft)
            } catch {
                fail(draft, page: page, title: String(localized: "Couldn't Sign In"), message: EmbySession.failureMessage(for: error))
            }
        }
    }

    /// The sign-in form's fields. Each row opens the keyboard.
    static func embySteps(_ draft: AddSourceDraft) -> [EntryStep] {
        let name = embyName
        return [
            EntryStep(id: "embyURL", title: "Server Address",
                      message: "Enter your \(name) server's address, with its port.",
                      placeholder: "Required", keyboard: .URL, contentType: .URL,
                      value: { draft.serverURL }, set: { draft.serverURL = $0; draft.status = .idle }),
            EntryStep(id: "embyUsername", title: "Username",
                      message: "Enter your \(name) username.",
                      placeholder: "Required", keyboard: .asciiCapable, contentType: .username,
                      value: { draft.username }, set: { draft.username = $0; draft.status = .idle }),
            // Not required: an Emby user can have no password.
            EntryStep(id: "embyPassword", title: "Password",
                      message: "Enter the password for this \(name) user. Leave it empty if the user has none.",
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
                fail(draft, page: page, title: String(localized: "Couldn't Sign In"), message: EmbySession.failureMessage(for: error))
            }
        }
    }
}
