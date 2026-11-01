// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AddLiveTVSourceContent.swift
//  Rivulet
//
//  Live TV add-source flow: a picker (`.addLiveTVSource`) that pushes one form
//  per kind, each a list of its fields. Drafts live in `AddSourceDraft`, and
//  nothing touches UserDefaults until a source is added.
//

import Foundation
import UIKit

// MARK: - Draft state

/// Form state for the add-source pages. A reference type so `.textEntry`
/// closures read/write one shared instance across row rebuilds. Not persisted.
@MainActor
final class AddSourceDraft {
    var serverURL = ""
    var displayName = ""
    var username = ""
    var password = ""
    var channelProfile = ""
    var m3uURL = ""
    var epgURL = ""
    var status: Status = .idle

    /// A failed check is not a state: it goes back to `.idle` and the cause
    /// shows in a popup (`SettingsContent.fail`).
    enum Status: Equatable {
        case idle
        case checking
    }
}

// MARK: - Entry steps

/// One field of a form: its row, and the page that asks for it.
@MainActor
struct EntryStep {
    let id: String
    /// Row title, page title and the keyboard's header: the field's name.
    let title: String
    /// One sentence on the entry page saying what to type, examples included.
    let message: String
    /// What the row shows while the field is empty.
    var placeholder = "Optional"
    var keyboard: UIKeyboardType = .default
    var contentType: UITextContentType?
    var isSecure = false
    var suggestions: [(label: String, value: String)] = []
    let value: () -> String
    let set: (String) -> Void

    var row: SettingsRowItem {
        SettingsRowItem(id: id, title: title,
                        kind: .textEntry(value: value, placeholder: placeholder, hint: message,
                                         suggestions: suggestions, keyboardType: keyboard,
                                         isSecure: isSecure, contentType: contentType, set: set))
    }

}

// MARK: - Add-source pages

extension SettingsContent {

    /// The Live TV add-source draft: created when the picker pushes a form,
    /// cleared when the flow is entered or left. Static for the same reason
    /// `pendingSourceDetail` is: `SettingsPage` is `CaseIterable` and can't
    /// carry associated data.
    static var addSourceDraft: AddSourceDraft?

    // MARK: Picker

    /// Names things by what the user has, not by protocol: someone running
    /// Tvheadend looks for the word Tvheadend.
    static var addLiveTVSource: [SettingsRowItem] {
        // No Plex or Jellyfin row: a signed-in server's Live TV is added on its own.
        [
            .header("Your Server"),
            serverRow(id: "addDispatcharr", title: "Dispatcharr", page: .addDispatcharr, app: .dispatcharr),
            serverRow(id: "addTvheadend", title: "Tvheadend", page: .addTvheadend, app: .tvheadend),
            serverRow(id: "addThreadfin", title: "Threadfin", page: .addThreadfin, app: .threadfin),
            .header("Provider"),
            SettingsRowItem(id: "addXtream", title: "Xtream Codes",
                            kind: .navigationAction(.addXtream, value: { "Provider login" },
                                                    prepare: { beginDraft(displayName: "") })),
            SettingsRowItem(id: "addPlaylistURL", title: "Playlist URL",
                            kind: .navigationAction(.addPlaylistURL, value: { "M3U link" },
                                                    prepare: { beginDraft(displayName: "") }))
        ]
    }

    private static func serverRow(id: String, title: String, page: SettingsPage,
                                  app: LiveTVServerApp) -> SettingsRowItem {
        SettingsRowItem(id: id, title: title,
                        kind: .navigationAction(page, value: nil, prepare: { beginDraft(displayName: "", app: app) }))
    }

    /// Clears everything the flow holds. Called when the picker page loads, so
    /// entering the flow always starts blank.
    static func resetAddSourceFlow() {
        addSourceDraft = nil
    }

    /// A server app's form starts on that app's usual address.
    private static func beginDraft(displayName: String, app: LiveTVServerApp? = nil) {
        let draft = AddSourceDraft()
        draft.displayName = displayName
        draft.serverURL = app.map { LiveTVSourceConnector.defaultAddress(for: $0) } ?? ""
        addSourceDraft = draft
    }

    // MARK: Xtream Codes

    static var addXtream: [SettingsRowItem] {
        guard let draft = addSourceDraft else { return [] }
        return xtreamSteps(draft).map(\.row) + [addButton(draft) { saveXtream(draft, on: $0) }]
    }

    private static func xtreamSteps(_ draft: AddSourceDraft) -> [EntryStep] {
        [
            EntryStep(id: "xtreamServerField", title: "Server Address",
                      message: "Enter the server address from your provider, with its port, "
                          + "for example http://provider.example:8080. You can also paste a link "
                          + "that includes your username and password.",
                      placeholder: "Required", keyboard: .URL, contentType: .URL,
                      value: { draft.serverURL },
                      set: { text in
                          // A pasted get.php link carries the login: split it out.
                          let parsed = XtreamService.parseAddress(text)
                          if let username = parsed.username, let password = parsed.password {
                              draft.serverURL = parsed.server
                              draft.username = username
                              draft.password = password
                          } else {
                              draft.serverURL = text
                          }
                          draft.status = .idle
                      }),
            EntryStep(id: "xtreamUsernameField", title: "Username",
                      message: "Enter the username your provider gave you for this server.",
                      placeholder: "Required", keyboard: .asciiCapable, contentType: .username,
                      value: { draft.username }, set: { draft.username = $0; draft.status = .idle }),
            EntryStep(id: "xtreamPasswordField", title: "Password",
                      message: "Enter the password your provider gave you for this server.",
                      placeholder: "Required", keyboard: .asciiCapable, contentType: .password, isSecure: true,
                      value: { draft.password }, set: { draft.password = $0; draft.status = .idle }),
            nameStep(draft, fallback: xtreamDefaultName(draft))
        ]
    }

    private static func xtreamDefaultName(_ draft: AddSourceDraft) -> String {
        URL(string: XtreamService.parseAddress(draft.serverURL).server)?.host ?? LiveTVSourceConnector.defaultPlaylistName
    }

    private static func saveXtream(_ draft: AddSourceDraft, on vc: UIViewController) {
        let connector = LiveTVSourceConnector()
        save(draft, on: vc,
             request: { try connector.xtreamRequest(address: draft.serverURL, username: draft.username,
                                                    password: draft.password) },
             connect: { try await connector.connect($0, name: draft.displayName.isEmpty
                                                        ? xtreamDefaultName(draft) : draft.displayName) })
    }

    // MARK: Playlist URL

    static var addPlaylistURL: [SettingsRowItem] {
        guard let draft = addSourceDraft else { return [] }
        return playlistSteps(draft).map(\.row) + [addButton(draft) { savePlaylist(draft, on: $0) }]
    }

    private static func playlistSteps(_ draft: AddSourceDraft) -> [EntryStep] {
        [
            EntryStep(id: "m3uURLField", title: "Playlist URL",
                      message: "Enter the M3U playlist link from your provider, "
                          + "for example http://provider.example/playlist.m3u.",
                      placeholder: "Required", keyboard: .URL, contentType: .URL,
                      value: { draft.m3uURL }, set: { draft.m3uURL = $0; draft.status = .idle }),
            EntryStep(id: "epgURLField", title: "Guide URL",
                      message: "If your provider gave you a guide link (XMLTV), enter it. "
                          + "Otherwise leave this empty: Rivulet uses the guide the playlist names, if it has one.",
                      keyboard: .URL, contentType: .URL,
                      value: { draft.epgURL }, set: { draft.epgURL = $0; draft.status = .idle }),
            nameStep(draft, fallback: LiveTVSourceConnector.defaultPlaylistName)
        ]
    }

    private static func savePlaylist(_ draft: AddSourceDraft, on vc: UIViewController) {
        let connector = LiveTVSourceConnector()
        save(draft, on: vc,
             request: { try LiveTVSourceConnector.playlistRequest(m3uURL: draft.m3uURL, epgURL: draft.epgURL) },
             connect: { try await connector.connect($0, name: draft.displayName) })
    }

    // MARK: Dispatcharr

    static var addDispatcharr: [SettingsRowItem] {
        guard let draft = addSourceDraft else { return [] }
        return dispatcharrSteps(draft).map(\.row) + [addButton(draft) { saveDispatcharr(draft, on: $0) }]
    }

    private static func dispatcharrSteps(_ draft: AddSourceDraft) -> [EntryStep] {
        [
            EntryStep(id: "serverURL", title: "Server Address",
                      message: "Enter your Dispatcharr server's address, with its port.",
                      placeholder: "Required", keyboard: .URL, contentType: .URL,
                      value: { draft.serverURL }, set: { draft.serverURL = $0; draft.status = .idle }),
            EntryStep(id: "usernameField", title: "Username",
                      message: "Your Dispatcharr username. Only needed to record; leave it empty to just watch.",
                      keyboard: .asciiCapable, contentType: .username,
                      value: { draft.username }, set: { draft.username = $0; draft.status = .idle }),
            EntryStep(id: "passwordField", title: "Password",
                      message: "Your Dispatcharr password. Only needed to record; leave it empty to just watch.",
                      keyboard: .asciiCapable, contentType: .password, isSecure: true,
                      value: { draft.password }, set: { draft.password = $0; draft.status = .idle }),
            EntryStep(id: "channelProfileField", title: "Channel Profile",
                      message: "The name of a Dispatcharr channel profile, to show only its channels. "
                          + "Leave it empty for every channel.",
                      placeholder: "All Channels", keyboard: .asciiCapable,
                      value: { draft.channelProfile }, set: { draft.channelProfile = $0; draft.status = .idle }),
            nameStep(draft, fallback: LiveTVSourceConnector.defaultServerName)
        ]
    }

    /// Verify-then-save as one operation: the server is added only if the
    /// check passed. Failure stays on the page with a real cause.
    private static func saveDispatcharr(_ draft: AddSourceDraft, on vc: UIViewController) {
        let connector = LiveTVSourceConnector()
        save(draft, on: vc,
             request: { try connector.serverRequest(address: draft.serverURL, username: draft.username,
                                                    password: draft.password, channelProfile: draft.channelProfile) },
             connect: { try await connector.connect($0, name: draft.displayName) })
    }

    // MARK: Tvheadend

    static var addTvheadend: [SettingsRowItem] {
        guard let draft = addSourceDraft else { return [] }
        return tvheadendSteps(draft).map(\.row) + [addButton(draft) { saveTvheadend(draft, on: $0) }]
    }

    private static func tvheadendSteps(_ draft: AddSourceDraft) -> [EntryStep] {
        let loginMessage = "Only needed if your server asks for a login, and to record. Leave both empty to just watch."
        return [
            EntryStep(id: "tvhServerField", title: "Server Address",
                      message: "Enter your Tvheadend server's address, with its port.",
                      placeholder: "Required", keyboard: .URL, contentType: .URL,
                      value: { draft.serverURL }, set: { draft.serverURL = $0; draft.status = .idle }),
            EntryStep(id: "tvhUsernameField", title: "Username", message: loginMessage,
                      keyboard: .asciiCapable, contentType: .username,
                      value: { draft.username }, set: { draft.username = $0; draft.status = .idle }),
            EntryStep(id: "tvhPasswordField", title: "Password", message: loginMessage,
                      keyboard: .asciiCapable, contentType: .password, isSecure: true,
                      value: { draft.password }, set: { draft.password = $0; draft.status = .idle }),
            nameStep(draft, fallback: LiveTVSourceConnector.defaultTvheadendName)
        ]
    }

    private static func saveTvheadend(_ draft: AddSourceDraft, on vc: UIViewController) {
        let connector = LiveTVSourceConnector()
        save(draft, on: vc,
             request: { try connector.tvheadendRequest(address: draft.serverURL, username: draft.username,
                                                       password: draft.password) },
             connect: { try await connector.connect($0, name: draft.displayName) })
    }

    // MARK: Threadfin

    static var addThreadfin: [SettingsRowItem] {
        guard let draft = addSourceDraft else { return [] }
        return threadfinSteps(draft).map(\.row) + [addButton(draft) { saveThreadfin(draft, on: $0) }]
    }

    private static func threadfinSteps(_ draft: AddSourceDraft) -> [EntryStep] {
        [
            EntryStep(id: "threadfinServerField", title: "Server Address",
                      message: "Enter your Threadfin server's address, with its port.",
                      placeholder: "Required", keyboard: .URL, contentType: .URL,
                      value: { draft.serverURL }, set: { draft.serverURL = $0; draft.status = .idle }),
            nameStep(draft, fallback: LiveTVSourceConnector.defaultThreadfinName)
        ]
    }

    private static func saveThreadfin(_ draft: AddSourceDraft, on vc: UIViewController) {
        let connector = LiveTVSourceConnector()
        save(draft, on: vc,
             request: { try LiveTVSourceConnector.threadfinRequest(address: draft.serverURL) },
             connect: { try await connector.connect($0, name: draft.displayName.isEmpty
                                                        ? LiveTVSourceConnector.defaultThreadfinName : draft.displayName) })
    }

    // MARK: Shared form pieces

    private static func nameStep(_ draft: AddSourceDraft, fallback: String) -> EntryStep {
        EntryStep(id: "displayNameField", title: "Name",
                  message: "How this source appears in Live TV. Leave it empty to use \u{201C}\(fallback)\u{201D}.",
                  placeholder: fallback,
                  value: { draft.displayName }, set: { draft.displayName = $0 })
    }

    private static func addButton(_ draft: AddSourceDraft, action: @escaping (UIViewController) -> Void) -> SettingsRowItem {
        SettingsRowItem(id: "addSourceConfirm", title: draft.status == .checking ? "Checking…" : "Add Source",
                        kind: .action(destructive: false, handler: action))
    }

    /// The form check runs first so a bad field fails before the busy state.
    private static func save<Request>(_ draft: AddSourceDraft, on vc: UIViewController,
                                      request makeRequest: () throws -> Request,
                                      connect: @escaping (Request) async throws -> Void) {
        guard draft.status != .checking else { return }
        let page = vc as? SettingsPageViewController
        let request: Request
        do {
            request = try makeRequest()
        } catch {
            fail(draft, page: page, error: error)
            return
        }

        draft.status = .checking
        page?.reloadRows()

        Task { @MainActor in
            do {
                try await connect(request)
                if addSourceDraft === draft { addSourceDraft = nil }
                // Back past the picker to the source list, which now shows it.
                page?.onPopTwo?()
            } catch {
                fail(draft, page: page, error: error)
            }
        }
    }

    /// A form check failed: put the button back to idle and say why in the
    /// app's popup card, with one OK button. What the user typed stays put.
    static func fail(_ draft: AddSourceDraft?, page: SettingsPageViewController?, title: String, message: String) {
        draft?.status = .idle
        page?.reloadRows()
        guard let page else { return }
        page.present(ConfirmationPopupViewController(title: title, message: message, confirmTitle: "OK",
                                                     cancelTitle: nil, onConfirm: {}),
                     animated: true)
    }

    /// `fail` with the connector error's own title and copy.
    private static func fail(_ draft: AddSourceDraft?, page: SettingsPageViewController?, error: Error) {
        let connect = error as? LiveTVConnectError ?? .source(LiveTVSourceConnector.failureCopy(for: error))
        fail(draft, page: page, title: connect.title, message: connect.message)
    }

    /// Drop the draft and pop the form. This runs after a network call, so the
    /// user may have left the form and started another: only this form's own
    /// draft is dropped, and the container ignores the pop unless the form is
    /// still on screen.
    static func finish(_ page: SettingsPageViewController?, draft: AddSourceDraft) {
        if addSourceDraft === draft { addSourceDraft = nil }
        page?.onPop?()
    }
}
