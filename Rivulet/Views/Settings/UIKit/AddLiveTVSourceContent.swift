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
    var apiToken = ""
    var channelProfile = ""
    var m3uURL = ""
    var epgURL = ""
    var status: Status = .idle

    enum Status: Equatable {
        case idle
        case checking
        case failed(String)
    }
}

// MARK: - URL sanitization

/// Fixes the URL typos a tvOS keyboard invites (doubled schemes, `htpp://`),
/// forces a scheme, and drops a trailing slash. Applied to every URL field on
/// entry. Behavior unchanged from the retired SwiftUI add-source sheet.
func sanitizeURL(_ input: String) -> String {
    var url = input.trimmingCharacters(in: .whitespacesAndNewlines)

    // Empty in, empty out. Without this, prepending the scheme and then
    // dropping the trailing slash turns "" into the garbage string "http:/",
    // which reads as a filled-in field and defeats every isEmpty check.
    guard !url.isEmpty else { return "" }

    let typoPatterns = [
        "http://http://", "https://https://",
        "http://https://", "https://http://",
        "hhttp://", "htttp://", "hhtp://", "htpp://",
        "httpss://", "htps://"
    ]

    for typo in typoPatterns {
        if url.lowercased().hasPrefix(typo) {
            let isSecure = typo.contains("https") || url.lowercased().hasPrefix("https")
            let correctProtocol = isSecure ? "https://" : "http://"
            url = correctProtocol + String(url.dropFirst(typo.count))
            break
        }
    }

    if !url.lowercased().hasPrefix("http://") && !url.lowercased().hasPrefix("https://") {
        url = "http://" + url
    }

    if url.hasSuffix("/") {
        url = String(url.dropLast())
    }

    return url
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
            if case .failed(let message) = plexStatus {
                rows.append(SettingsRowItem(id: "addPlexLiveTVError", title: message,
                                            kind: .info(value: { "" })))
            }
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
        let auth = PlexAuthManager.shared
        guard let serverURL = auth.selectedServerURL,
              let token = auth.selectedServerToken,
              let serverName = auth.savedServerName else {
            plexStatus = .failed("Plex server is not connected.")
            (vc as? SettingsPageViewController)?.reloadRows()
            return
        }

        plexStatus = .checking
        let page = vc as? SettingsPageViewController
        page?.reloadRows()

        Task { @MainActor in
            let isAvailable = await PlexLiveTVProvider.checkAvailability(
                serverURL: serverURL, authToken: token)
            guard isAvailable else {
                plexStatus = .failed("No DVR or tuners are set up on this Plex server.")
                page?.reloadRows()
                return
            }

            let provider = PlexLiveTVProvider(serverURL: serverURL, authToken: token,
                                              serverName: serverName)
            let store = LiveTVDataStore.shared
            await store.addPlexSource(provider: provider)
            await store.loadChannels()
            await store.loadEPG(startDate: Date(), hours: 6)

            plexStatus = .idle
            addSourceDraft = nil
            page?.onPop?()
        }
    }

    // MARK: My Own Server

    static var addOwnServer: [SettingsRowItem] {
        guard let draft = addSourceDraft else { return [] }
        var rows: [SettingsRowItem] = [
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
            SettingsRowItem(id: "apiTokenField", title: "API Key",
                            kind: .textEntry(value: { draft.apiToken }, placeholder: "Optional",
                                             hint: nil, suggestions: [], keyboardType: .default,
                                             set: { draft.apiToken = $0 })),
            SettingsRowItem(id: "channelProfileField", title: "Channel Profile",
                            kind: .textEntry(value: { draft.channelProfile }, placeholder: "Optional",
                                             hint: nil, suggestions: [], keyboardType: .default,
                                             set: { draft.channelProfile = $0; draft.status = .idle })),
            SettingsRowItem(id: "addSourceConfirm", title: actionTitle(draft),
                            kind: .action(destructive: false, handler: { vc in
                                saveOwnServer(draft, on: vc)
                            }))
        ]
        rows += errorRows(draft)
        return rows
    }

    /// Presets are derived from the Plex server's host when it's on the local
    /// network, so a user who runs both on one box gets a one-press fill.
    private static var baseHost: String {
        if let plexURLString = PlexAuthManager.shared.selectedServerURL,
           let plexURL = URL(string: plexURLString),
           let host = plexURL.host,
           isLocalIP(host) {
            return host
        }
        return "192.168.1.100"
    }

    private static func isLocalIP(_ host: String) -> Bool {
        host.hasPrefix("192.168.") || host.hasPrefix("10.") ||
        host.hasPrefix("172.16.") || host.hasPrefix("172.17.") ||
        host.hasPrefix("172.18.") || host.hasPrefix("172.19.") ||
        host.hasPrefix("172.2") || host.hasPrefix("172.30.") ||
        host.hasPrefix("172.31.") || host == "localhost" || host == "127.0.0.1"
    }

    private static var serverSuggestions: [(label: String, value: String)] {
        [
            ("Dispatcharr", "http://\(baseHost):9191"),
            ("Threadfin", "http://\(baseHost):34400"),
            ("xTeVe", "http://\(baseHost):34400"),
            ("ErsatzTV", "http://\(baseHost):8409"),
            ("Cabernet", "http://\(baseHost):6077")
        ]
    }

    /// Verify-then-save as ONE operation: check the server, and only add it if
    /// the check passed. Failure stays on the page with a real cause.
    private static func saveOwnServer(_ draft: AddSourceDraft, on vc: UIViewController) {
        guard draft.status != .checking else { return }
        let page = vc as? SettingsPageViewController
        guard !draft.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            draft.status = .failed("Enter your server's address first.")
            page?.reloadRows()
            return
        }
        let cleaned = sanitizeURL(draft.serverURL)
        let token = draft.apiToken.isEmpty ? nil : draft.apiToken

        // A profile typed into the field wins, but if the user instead pasted a
        // full endpoint such as .../output/m3u/Kids we adopt the profile from the
        // URL. Dispatcharr scopes the playlist only by that path segment, so
        // whichever way the user expressed it has to survive to the request.
        let split = DispatcharrService.splitEndpointPath(from: cleaned)
        let profile = DispatcharrService.normalizedProfile(draft.channelProfile) ?? split.channelProfile

        guard let url = URL(string: split.baseURL),
              let service = DispatcharrService.create(from: cleaned, apiToken: token,
                                                      channelProfile: profile) else {
            draft.status = .failed("Couldn't reach that server. Check the address and port.")
            page?.reloadRows()
            return
        }

        draft.status = .checking
        page?.reloadRows()

        Task { @MainActor in
            do {
                let channels = try await service.fetchChannels()
                guard !channels.isEmpty else {
                    // An empty playlist with a profile set is nearly always a
                    // profile name that does not match one on the server, so
                    // point at the field rather than at the connection.
                    draft.status = .failed(profile == nil
                                           ? "Connected, but found no channels."
                                           : "Connected, but that channel profile has no channels. Check the name.")
                    page?.reloadRows()
                    return
                }
                // The playlist needs no key, so a wrong one would otherwise
                // only show up the first time a recording fails. Check it now.
                // Only a rejection counts: a server that is not Dispatcharr
                // has no such endpoint, and its playlist already loaded.
                if token != nil {
                    do {
                        _ = try await service.fetchChannelSummaries()
                    } catch DispatcharrError.unauthorized {
                        throw DispatcharrError.unauthorized
                    } catch {}
                }
                let store = LiveTVDataStore.shared
                await store.addDispatcharrSource(
                    baseURL: url,
                    name: draft.displayName.isEmpty ? "Live TV" : draft.displayName,
                    apiToken: token,
                    channelProfile: profile)
                await store.loadChannels()
                await store.loadEPG(startDate: Date(), hours: 6)
                finish(page)
            } catch {
                draft.status = .failed(failureCopy(for: error))
                page?.reloadRows()
            }
        }
    }

    // MARK: Playlist URL

    static var addPlaylistURL: [SettingsRowItem] {
        guard let draft = addSourceDraft else { return [] }
        var rows: [SettingsRowItem] = [
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
        rows += errorRows(draft)
        return rows
    }

    private static func savePlaylist(_ draft: AddSourceDraft, on vc: UIViewController) {
        guard draft.status != .checking else { return }
        let page = vc as? SettingsPageViewController
        guard !draft.m3uURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            draft.status = .failed("Enter your playlist URL first.")
            page?.reloadRows()
            return
        }
        guard let m3u = URL(string: sanitizeURL(draft.m3uURL)) else {
            draft.status = .failed("That playlist URL doesn't look right. Check it and try again.")
            page?.reloadRows()
            return
        }
        let epg = draft.epgURL.isEmpty ? nil : URL(string: sanitizeURL(draft.epgURL))

        draft.status = .checking
        page?.reloadRows()

        Task { @MainActor in
            do {
                // Same fetch + parse path the source itself uses, so a playlist
                // that validates here is one that will load.
                let (data, response) = try await URLSession.shared.data(from: m3u)
                if let http = response as? HTTPURLResponse {
                    switch http.statusCode {
                    case 200...299: break
                    case 401, 403: throw DispatcharrError.unauthorized
                    default: throw DispatcharrError.httpError(http.statusCode)
                    }
                }
                let channels = try await M3UParser().parse(data: data)
                guard !channels.isEmpty else {
                    draft.status = .failed("Connected, but found no channels.")
                    page?.reloadRows()
                    return
                }
                let store = LiveTVDataStore.shared
                await store.addM3USource(m3uURL: m3u, epgURL: epg,
                                         name: draft.displayName.isEmpty ? "IPTV" : draft.displayName)
                await store.loadChannels()
                await store.loadEPG(startDate: Date(), hours: 6)
                finish(page)
            } catch {
                draft.status = .failed(failureCopy(for: error))
                page?.reloadRows()
            }
        }
    }

    // MARK: Shared form pieces

    private static func actionTitle(_ draft: AddSourceDraft) -> String {
        draft.status == .checking ? "Checking…" : "Add Source"
    }

    /// Failure text as a non-focusable row below the action, so the cause is on
    /// screen instead of stuffed into a button title.
    private static func errorRows(_ draft: AddSourceDraft) -> [SettingsRowItem] {
        guard case .failed(let message) = draft.status else { return [] }
        return [SettingsRowItem(id: "addSourceError", title: message, kind: .info(value: { "" }))]
    }

    /// Drop the draft and pop back to the source list. The container's `pop()`
    /// rebuilds the incoming page's rows, so `.iptv` picks up the new source.
    private static func finish(_ page: SettingsPageViewController?) {
        addSourceDraft = nil
        page?.onPop?()
    }

    /// Maps the underlying failure to one of the three real causes. The original
    /// error is preserved for Sentry — only the user-facing copy is collapsed.
    private static func failureCopy(for error: Error) -> String {
        if let dispatcharr = error as? DispatcharrError {
            switch dispatcharr {
            case .unauthorized: return "That server rejected the API key."
            case .invalidResponse, .notFound, .serverError, .httpError:
                return "Couldn't reach that server. Check the address and port."
            }
        }
        if error is M3UParseError {
            return "Connected, but found no channels."
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorUserAuthenticationRequired {
            return "That server rejected the API key."
        }
        return "Couldn't reach that server. Check the address and port."
    }
}
