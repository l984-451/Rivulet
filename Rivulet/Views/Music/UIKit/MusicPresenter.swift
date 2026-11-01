// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicPresenter.swift
//  Rivulet
//
//  Opens the Music pages. They are presented full screen, outside the shell,
//  so the shell's Menu handler declines by containment and each page's own
//  Menu recognizer unwinds one level.
//

import UIKit

@MainActor
enum MusicPresenter {

    static func showAlbum(_ album: MusicAlbum, from presenter: UIViewController? = nil) {
        present(MusicAlbumViewController(album: album), from: presenter)
    }

    static func showPlaylist(_ playlist: MusicPlaylist, from presenter: UIViewController? = nil) {
        present(MusicAlbumViewController(playlist: playlist), from: presenter)
    }

    /// `detail` spares the page its own fetch when the caller already holds it.
    static func showArtist(_ artist: MusicArtist, detail: MusicArtistDetail? = nil,
                           from presenter: UIViewController? = nil) {
        present(MusicArtistViewController(artist: artist, detail: detail), from: presenter)
    }

    /// A menu's "Go to Album" / "Go to Artist": only the ref is known, so load the item first.
    static func show(_ request: MusicNavigationRequest, from presenter: UIViewController? = nil) {
        Task {
            do {
                switch request {
                case .album(let ref):
                    guard let detail = try await MusicProviderRegistry.shared.provider(for: ref)?
                        .albumDetail(for: ref) else { return }
                    showAlbum(detail.album, from: presenter)
                case .artist(let ref):
                    guard let detail = try await MusicProviderRegistry.shared.provider(for: ref)?
                        .artistDetail(for: ref) else { return }
                    showArtist(detail.artist, detail: detail, from: presenter)
                }
            } catch {
                reportFailure(error, from: presenter)
            }
        }
    }

    /// A Plex-typed artist or album from Search or Home. Tracks play at the tap site.
    /// False when there was nothing to present.
    @discardableResult
    static func showDetail(for meta: PlexMetadata, from presenter: UIViewController? = nil) -> Bool {
        guard let provider = MusicProviderRegistry.shared.primaryProvider, provider.kind == .plex,
              let serverURL = PlexAuthManager.shared.selectedServerURL,
              let token = PlexAuthManager.shared.selectedServerToken else { return false }
        switch PlexMusicMapper.item(meta, providerID: provider.id, serverURL: serverURL, authToken: token) {
        case .album(let album): showAlbum(album, from: presenter)
        case .artist(let artist): showArtist(artist, from: presenter)
        default: return false
        }
        return true
    }

    /// A Music request the server did not answer: the app's notice card, one OK button.
    static func reportFailure(_ error: Error, from presenter: UIViewController? = nil) {
        let message = switch error as? MediaProviderError {
        case .unreachable: String(localized: "Couldn't reach the server.")
        case .unauthorized: String(localized: "The server didn't accept your sign-in.")
        case .notFound: String(localized: "The server no longer has this item.")
        default: String(localized: "The server didn't answer as expected.")
        }
        top(from: presenter)?.present(
            ConfirmationPopupViewController(title: String(localized: "Couldn't Load"), message: message, confirmTitle: String(localized: "OK"),
                                            cancelTitle: nil, onConfirm: {}),
            animated: true)
    }

    /// Presenting onto a covered controller silently does nothing, so walk to
    /// the top, skipping a controller that is on its way out.
    static func top(from presenter: UIViewController?) -> UIViewController? {
        let root = presenter ?? UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        guard var top = root else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }

    private static func present(_ page: UIViewController, from presenter: UIViewController?) {
        page.modalPresentationStyle = .fullScreen
        page.modalTransitionStyle = .crossDissolve
        top(from: presenter)?.present(page, animated: true)
    }

    #if DEBUG
    /// Simulator iteration: `RIVULET_MUSIC_OPEN=album:<ratingKey>` (or `artist:`, `playlist:`)
    /// opens that page at launch; `play:<album ratingKey>` plays the album.
    static func debugOpenIfRequested() {
        guard let value = ProcessInfo.processInfo.environment["RIVULET_MUSIC_OPEN"],
              let provider = MusicProviderRegistry.shared.primaryProvider else { return }
        let parts = value.split(separator: ":").map(String.init)
        guard parts.count == 2 else { return }
        let ref = MediaItemRef(providerID: provider.id, itemID: parts[1])
        switch parts[0] {
        case "artist": show(.artist(ref))
        case "play": MusicMenus.play({ try await provider.tracks(for: ref) })
        case "playlist":
            Task {
                for library in (try? await provider.musicLibraries()) ?? [] {
                    let playlists = (try? await provider.playlists(in: library, sort: .title)) ?? []
                    if let playlist = playlists.first(where: { $0.ref == ref }) { return showPlaylist(playlist) }
                }
            }
        default: show(.album(ref))
        }
    }
    #endif
}
