// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AddLiveTVSourceContent.swift
//  Rivulet
//
//  The Live TV add-source flow, as real pages in the UIKit Settings stack:
//  a picker (`.addLiveTVSource`) that pushes one of two forms
//  (`.addOwnServer`, `.addPlaylistURL`), each with a single terminal
//  verify-then-save action. Rendered by `SettingsPageViewController` like every
//  other page, so Glass rows, focus scaling and the left description panel come
//  for free.
//
//  Draft state lives in `AddSourceDraft`, created when the picker pushes a form
//  and released when the flow leaves. A half-typed URL must not survive a Menu
//  press, so nothing here touches UserDefaults until the source is actually
//  added.
//

import Foundation
import UIKit

// MARK: - Draft state

/// Form state for the add-source pages. Reference type so `.textEntry` closures
/// read/write one shared instance across row rebuilds, mirroring how `.toggle`
/// rows read/write `SettingsStore`. Deliberately NOT persisted.
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

// MARK: - Add-source pages

extension SettingsContent {

    /// Live for the duration of the add-source flow: created when the picker
    /// pushes a form page, cleared when the flow is entered or left. Static for
    /// the same reason as `pendingSourceDetail` — `SettingsPage` is
    /// `CaseIterable` and can't carry associated data — but mutable, so the
    /// forms' `.textEntry` closures can write through to it.
    static var addSourceDraft: AddSourceDraft?

    // MARK: Picker

    /// Names things by what the user has, not by protocol. The app names on the
    /// "My Own Server" row are load-bearing: they are how a user running
    /// Threadfin recognises the row as theirs.
    static var addLiveTVSource: [SettingsRowItem] {
        var rows: [SettingsRowItem] = []

        if PlexAuthManager.shared.isAuthenticated {
            rows.append(SettingsRowItem(
                id: "addPlexLiveTV",
                title: plexRowTitle,
                kind: .action(destructive: false, handler: { vc in addPlexLiveTV(on: vc) })))
        }

        rows.append(SettingsRowItem(
            id: "addOwnServer", title: "My Own Server",
            kind: .navigationAction(.addOwnServer,
                                    value: { "Dispatcharr, Threadfin" },
                                    prepare: { beginDraft(displayName: "Live TV") })))
        rows.append(SettingsRowItem(
            id: "addPlaylistURL", title: "Playlist URL",
            kind: .navigationAction(.addPlaylistURL,
                                    value: { "From an IPTV provider" },
                                    prepare: { beginDraft(displayName: "IPTV") })))
        return rows
    }

    /// Picker-local status for the Plex row (the Plex path has no form, so it
    /// can't use the draft). Reset by `resetAddSourceFlow()` on entry so a
    /// previous visit's failure text never greets the next one.
    static var plexStatus: AddSourceDraft.Status = .idle

    /// Clears everything the flow holds. Called when the picker page loads, so
    /// entering the flow always starts blank, and a half-typed URL from a
    /// Menu-ed-out visit can't come back.
    static func resetAddSourceFlow() {
        plexStatus = .idle
        addSourceDraft = nil
    }

    private static var plexRowTitle: String {
        plexStatus == .checking ? "Checking…" : "Plex Live TV"
    }

    private static func beginDraft(displayName: String) {
        let draft = AddSourceDraft()
        draft.displayName = displayName
        addSourceDraft = draft
    }

    /// Single press: check, add, load, pop. No confirm page. On failure the row
    /// stays put and the real reason renders in an `.info` row beneath it (the
    /// old SwiftUI picker set `plexError` and never rendered it).
    private static func addPlexLiveTV(on vc: UIViewController) {
        guard plexStatus != .checking else { return }
        let request: LiveTVSourceConnector.PlexRequest
        do {
            request = try LiveTVSourceConnector.plexRequest()
        } catch {
            plexStatus = .idle
            fail(nil, page: vc as? SettingsPageViewController, error: error)
            return
        }

        plexStatus = .checking
        let page = vc as? SettingsPageViewController
        page?.reloadRows()

        Task { @MainActor in
            do {
                try await LiveTVSourceConnector().connect(request)
            } catch {
                plexStatus = .idle
                fail(nil, page: page, error: error)
                return
            }
            plexStatus = .idle
            addSourceDraft = nil
            page?.onPop?()
        }
    }

    // MARK: My Own Server

    static var addOwnServer: [SettingsRowItem] {
        guard let draft = addSourceDraft else { return [] }
        let rows: [SettingsRowItem] = [
            SettingsRowItem(id: "serverURL", title: "Server URL",
                            kind: .textEntry(value: { draft.serverURL },
                                             placeholder: "http://\(baseHost):9191",
                                             hint: "Base URL. Rivulet reads /output/m3u and /output/epg.",
                                             suggestions: serverSuggestions,
                                             keyboardType: .URL,
                                             set: { draft.serverURL = $0; draft.status = .idle })),
            SettingsRowItem(id: "displayNameField", title: "Display Name",
                            kind: .textEntry(value: { draft.displayName }, placeholder: "Live TV",
                                             hint: nil, suggestions: [], keyboardType: .default,
                                             set: { draft.displayName = $0 })),
            SettingsRowItem(id: "usernameField", title: "Username",
                            kind: .textEntry(value: { draft.username }, placeholder: "Optional",
                                             hint: nil, suggestions: [], keyboardType: .asciiCapable,
                                             set: { draft.username = $0; draft.status = .idle })),
            SettingsRowItem(id: "passwordField", title: "Password",
                            kind: .textEntry(value: { draft.password }, placeholder: "Optional",
                                             hint: nil, suggestions: [], keyboardType: .asciiCapable,
                                             isSecure: true,
                                             set: { draft.password = $0; draft.status = .idle })),
            SettingsRowItem(id: "channelProfileField", title: "Channel Profile",
                            kind: .textEntry(value: { draft.channelProfile }, placeholder: "Optional",
                                             hint: nil, suggestions: [], keyboardType: .default,
                                             set: { draft.channelProfile = $0; draft.status = .idle })),
            SettingsRowItem(id: "addSourceConfirm", title: actionTitle(draft),
                            kind: .action(destructive: false, handler: { vc in
                                saveOwnServer(draft, on: vc)
                            }))
        ]
        return rows
    }

    private static var baseHost: String { LiveTVSourceConnector.suggestedHost }

    private static var serverSuggestions: [(label: String, value: String)] {
        LiveTVSourceConnector.serverSuggestions(host: baseHost)
    }

    /// Verify-then-save as ONE operation: check the server, and only add it if
    /// the check passed. Failure stays on the page with a real cause.
    private static func saveOwnServer(_ draft: AddSourceDraft, on vc: UIViewController) {
        guard draft.status != .checking else { return }
        let page = vc as? SettingsPageViewController
        let connector = LiveTVSourceConnector()
        let request: LiveTVSourceConnector.ServerRequest
        do {
            request = try connector.serverRequest(address: draft.serverURL, username: draft.username,
                                                  password: draft.password, channelProfile: draft.channelProfile)
        } catch {
            fail(draft, page: page, error: error)
            return
        }

        draft.status = .checking
        page?.reloadRows()

        Task { @MainActor in
            do {
                try await connector.connect(request, name: draft.displayName)
                finish(page, draft: draft)
            } catch {
                fail(draft, page: page, error: error)
            }
        }
    }

    // MARK: Playlist URL

    static var addPlaylistURL: [SettingsRowItem] {
        guard let draft = addSourceDraft else { return [] }
        let rows: [SettingsRowItem] = [
            SettingsRowItem(id: "m3uURLField", title: "M3U Playlist URL",
                            kind: .textEntry(value: { draft.m3uURL },
                                             placeholder: "http://example.com/playlist.m3u",
                                             hint: "The M3U or M3U8 playlist URL from your provider.",
                                             suggestions: [], keyboardType: .URL,
                                             set: { draft.m3uURL = $0; draft.status = .idle })),
            SettingsRowItem(id: "epgURLField", title: "EPG URL (Optional)",
                            kind: .textEntry(value: { draft.epgURL },
                                             placeholder: "http://example.com/epg.xml",
                                             hint: "XMLTV format, for the program guide.",
                                             suggestions: [], keyboardType: .URL,
                                             set: { draft.epgURL = $0; draft.status = .idle })),
            SettingsRowItem(id: "displayNameField", title: "Display Name",
                            kind: .textEntry(value: { draft.displayName }, placeholder: "IPTV",
                                             hint: nil, suggestions: [], keyboardType: .default,
                                             set: { draft.displayName = $0 })),
            SettingsRowItem(id: "addSourceConfirm", title: actionTitle(draft),
                            kind: .action(destructive: false, handler: { vc in
                                savePlaylist(draft, on: vc)
                            }))
        ]
        return rows
    }

    private static func savePlaylist(_ draft: AddSourceDraft, on vc: UIViewController) {
        guard draft.status != .checking else { return }
        let page = vc as? SettingsPageViewController
        let request: LiveTVSourceConnector.PlaylistRequest
        do {
            request = try LiveTVSourceConnector.playlistRequest(m3uURL: draft.m3uURL, epgURL: draft.epgURL)
        } catch {
            fail(draft, page: page, error: error)
            return
        }

        draft.status = .checking
        page?.reloadRows()

        Task { @MainActor in
            do {
                try await LiveTVSourceConnector().connect(request, name: draft.displayName)
                finish(page, draft: draft)
            } catch {
                fail(draft, page: page, error: error)
            }
        }
    }

    // MARK: Shared form pieces

    private static func actionTitle(_ draft: AddSourceDraft) -> String {
        draft.status == .checking ? "Checking…" : "Add Source"
    }

    /// A form check failed: put the button back to idle and say why in the
    /// app's popup card, one OK button. What the user typed stays put.
    static func fail(_ draft: AddSourceDraft?, page: SettingsPageViewController?, title: String, message: String) {
        draft?.status = .idle
        page?.reloadRows()
        guard let page else { return }
        page.present(ConfirmationPopupViewController(title: title, message: message, confirmTitle: "OK",
                                                     cancelTitle: nil, onConfirm: {}),
                     animated: true)
    }

    /// `fail` with a connector error's own title and copy.
    private static func fail(_ draft: AddSourceDraft?, page: SettingsPageViewController?, error: Error) {
        let connect = error as? LiveTVConnectError ?? .source(LiveTVSourceConnector.failureCopy(for: error))
        fail(draft, page: page, title: connect.title, message: connect.message)
    }

    /// Drop the draft and pop back to the source list. The container's `pop()`
    /// rebuilds the incoming page's rows, so `.iptv` picks up the new source.
    /// Runs after a network call, when the user may have left the form and
    /// started another: only this form's own draft is dropped, and the
    /// container ignores the pop unless the form is still on screen.
    static func finish(_ page: SettingsPageViewController?, draft: AddSourceDraft) {
        if addSourceDraft === draft { addSourceDraft = nil }
        page?.onPop?()
    }
}
