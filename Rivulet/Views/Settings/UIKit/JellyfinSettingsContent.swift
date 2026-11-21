// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  JellyfinSettingsContent.swift
//  Rivulet
//
//  Settings > Servers > Jellyfin Server. Signed out: a form built from the
//  same rows as the Live TV "My Own Server" page, sharing its draft and its
//  failure popup. Signed in: the server, the user, Refresh and Sign Out.
//

import Combine
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
            ] + jellyfinUserRows(active: account) + [
                SettingsRowItem(id: "jellyfinRefresh", title: "Refresh",
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
                SettingsRowItem(id: "jellyfinSignOut", title: "Sign Out",
                                kind: .action(destructive: true, handler: { vc in
                    func signOut(_ scope: SignOutScope?) {
                        Task { @MainActor in
                            await JellyfinSession.signOut(scope: scope)
                            addSourceDraft = AddSourceDraft()
                            (vc as? SettingsPageViewController)?.reloadRows()
                        }
                    }
                    if CloudSync.shared.isSynced(accountID: account.providerID) {
                        presentSignOutChoice(
                            on: vc, title: String(localized: "Sign Out of Jellyfin?"),
                            message: String(localized: "Your Jellyfin sign-in is shared through iCloud. Sign out of this device only, or of every device?"),
                            thisDevice: { signOut(.thisDevice) }, everywhere: { signOut(.everywhere) })
                    } else {
                        signOut(nil)
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
                            })),
            SettingsRowItem(id: "jellyfinQuickConnect", title: "Quick Connect",
                            kind: .action(destructive: false, handler: { vc in
                                quickConnectJellyfin(draft, on: vc)
                            }))
        ]
    }

    /// One row per signed-in user, the active one checked, when there is more than one;
    /// then Add User, and Remove User once there is someone to remove.
    private static func jellyfinUserRows(active: JellyfinSession.Account) -> [SettingsRowItem] {
        let users = JellyfinSession.users
        let userRows: [SettingsRowItem] = users.count > 1
            ? users.sorted { $0.userName.localizedStandardCompare($1.userName) == .orderedAscending }.map { user in
                SettingsRowItem(id: "jellyfinUser_\(user.userID)", verbatim: user.userName, kind: .selectable(
                    isSelected: { JellyfinSession.account?.userID == user.userID },
                    value: { nil },
                    handler: { vc in
                        Task { @MainActor in
                            await JellyfinSession.switchUser(to: user.userID)
                            (vc as? SettingsPageViewController)?.reloadRows()
                        }
                    }))
            }
            : [SettingsRowItem(id: "jellyfinUserInfo", title: "User", kind: .info(value: { active.userName }))]
        return userRows + [
            SettingsRowItem(id: "jellyfinAddUser", title: "Add User",
                            kind: .navigationAction(.jellyfinAddUser, value: nil, prepare: { addSourceDraft = AddSourceDraft() }))
        ] + (JellyfinSession.savedUsers.isEmpty ? [] : [
            SettingsRowItem(id: "jellyfinRemoveUser", title: "Remove User", kind: .navigation(.jellyfinRemoveUser))
        ])
    }

    /// Settings > Jellyfin Server > Add User: another user of the same server, signed in beside the active one.
    static var jellyfinAddUser: [SettingsRowItem] {
        guard JellyfinSession.account != nil, let draft = addSourceDraft else { return [] }
        return Array(jellyfinSteps(draft).dropFirst()).map(\.row) + [
            SettingsRowItem(id: "jellyfinSignIn",
                            title: draft.status == .checking ? "Signing In…" : "Sign In",
                            kind: .action(destructive: false, handler: { vc in
                                addJellyfinUser(draft, on: vc)
                            })),
            SettingsRowItem(id: "jellyfinQuickConnect", title: "Quick Connect",
                            kind: .action(destructive: false, handler: { vc in
                                addJellyfinUserWithQuickConnect(draft, on: vc)
                            }))
        ]
    }

    /// Settings > Jellyfin Server > Remove User: the users added beside the first one.
    static var jellyfinRemoveUser: [SettingsRowItem] {
        JellyfinSession.savedUsers.map { user in
            SettingsRowItem(id: "jellyfinRemove_\(user.userID)", verbatim: user.userName,
                            kind: .action(destructive: true, handler: { vc in
                Task { @MainActor in
                    await JellyfinSession.removeUser(user.userID)
                    let page = vc as? SettingsPageViewController
                    if JellyfinSession.savedUsers.isEmpty { page?.onPop?() } else { page?.reloadRows() }
                }
            }))
        }
    }

    private static func addJellyfinUser(_ draft: AddSourceDraft, on vc: UIViewController) {
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
                try await JellyfinSession.addUser(username: username, password: draft.password)
                finish(page, draft: draft)
            } catch {
                fail(draft, page: page, title: String(localized: "Couldn't Sign In"), message: JellyfinSession.failureMessage(for: error))
            }
        }
    }

    /// Quick Connect for Add User: the code is approved on a device signed in as the user to add.
    private static func addJellyfinUserWithQuickConnect(_ draft: AddSourceDraft, on vc: UIViewController) {
        guard draft.status != .checking else { return }
        let page = vc as? SettingsPageViewController
        draft.status = .checking
        page?.reloadRows()
        let attempt = QuickConnectAttempt()
        attempt.task = Task { @MainActor in
            var popup: UIViewController?
            do {
                try await JellyfinSession.addUserWithQuickConnect { code in
                    let codePopup = ConfirmationPopupViewController(
                        title: code,
                        message: String(localized: "On a device signed in to Jellyfin as the user to add, open Settings, choose Quick Connect and enter this code."),
                        confirmTitle: String(localized: "Cancel"), cancelTitle: nil,
                        onConfirm: { attempt.task?.cancel() }, onCancel: { attempt.task?.cancel() })
                    popup = codePopup
                    vc.present(codePopup, animated: true)
                }
                popup?.dismiss(animated: true)
                finish(page, draft: draft)
            } catch where isCancellationError(error) {
                draft.status = .idle
                page?.reloadRows()
            } catch {
                popup?.dismiss(animated: true)
                fail(draft, page: page, title: String(localized: "Couldn't Sign In"), message: JellyfinSession.quickConnectFailureMessage(for: error))
            }
        }
    }

    /// The sign-in form's fields. Each row opens its own entry page.
    static func jellyfinSteps(_ draft: AddSourceDraft) -> [EntryStep] {
        [
            EntryStep(id: "jellyfinURL", title: "Server Address",
                      message: "Enter your Jellyfin server's address, with its port, for example http://192.168.1.100:8096.",
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
            fail(draft, page: page, title: String(localized: "Couldn't Sign In"),
                 message: String(localized: "Enter your server's address and your username."))
            return
        }
        draft.status = .checking
        page?.reloadRows()

        Task { @MainActor in
            do {
                _ = try await JellyfinSession.signIn(serverURL: url, username: username, password: draft.password)
                finish(page, draft: draft)
            } catch {
                fail(draft, page: page, title: String(localized: "Couldn't Sign In"), message: JellyfinSession.failureMessage(for: error))
            }
        }
    }

    /// Shows the code in a popup while the session polls; leaving the popup cancels the sign-in.
    private static func quickConnectJellyfin(_ draft: AddSourceDraft, on vc: UIViewController) {
        guard draft.status != .checking else { return }
        let page = vc as? SettingsPageViewController
        guard let url = URL(string: sanitizeURL(draft.serverURL)) else {
            fail(draft, page: page, title: String(localized: "Couldn't Sign In"),
                 message: String(localized: "Enter your server's address."))
            return
        }
        draft.status = .checking
        page?.reloadRows()

        let attempt = QuickConnectAttempt()
        attempt.task = Task { @MainActor in
            var popup: UIViewController?
            do {
                _ = try await JellyfinSession.signInWithQuickConnect(serverURL: url) { code in
                    let codePopup = ConfirmationPopupViewController(
                        title: code,
                        message: String(localized: "On a device signed in to Jellyfin, open Settings, choose Quick Connect and enter this code."),
                        confirmTitle: String(localized: "Cancel"), cancelTitle: nil,
                        onConfirm: { attempt.task?.cancel() }, onCancel: { attempt.task?.cancel() })
                    popup = codePopup
                    vc.present(codePopup, animated: true)
                }
                popup?.dismiss(animated: true)
                finish(page, draft: draft)
            } catch where isCancellationError(error) {
                draft.status = .idle
                page?.reloadRows()
            } catch {
                popup?.dismiss(animated: true)
                fail(draft, page: page, title: String(localized: "Couldn't Sign In"), message: JellyfinSession.quickConnectFailureMessage(for: error))
            }
        }
    }

    /// Lets the code popup cancel the task that presented it.
    @MainActor private final class QuickConnectAttempt {
        var task: Task<Void, Never>?
    }
}
