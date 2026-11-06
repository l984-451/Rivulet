// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  Plays a trailer or extra from any detail surface (the carousel's expanded detail, the
//  episode page, the season page).

import Sentry
import UIKit
import os.log

private let extraPlayerLog = Logger(subsystem: "com.rivulet.app", category: "ExtraPlayer")

@MainActor
enum ExtraPlayer {

    /// Fetches a Plex ratingKey's metadata and presents the player. A nil `resumeOffset`
    /// means ask the server: the only place an extra's resume point appears (#303).
    static func presentPlayer(ratingKey: String, resumeOffset: Double?, mediaID: String? = nil,
                              server: PlexServerAddress?, from presenter: UIViewController) {
        Task { [weak presenter] in
            guard let serverURL = server?.address, let token = server?.token else {
                extraPlayerLog.error("play handoff: no server/token")
                return
            }
            let network = PlexNetworkManager.shared
            let playItem: PlexMetadata
            do {
                playItem = try await network.getFullMetadata(
                    serverURL: serverURL, authToken: token, ratingKey: ratingKey)
            } catch {
                do {
                    playItem = try await network.getMetadata(
                        serverURL: serverURL, authToken: token, ratingKey: ratingKey)
                } catch {
                    extraPlayerLog.error("play handoff fetch failed: \(String(describing: error), privacy: .public)")
                    return
                }
            }
            // `viewOffset` is ms, gated on the shared resume policy rather than `> 0`.
            let serverResume = playItem.isInProgress
                ? playItem.viewOffset.map { Double($0) / 1000 }
                : nil
            guard let presenter else { return }
            present(playItem: playItem, serverURL: serverURL, token: token,
                    resumeOffset: resumeOffset ?? serverResume, mediaID: mediaID, from: presenter)
        }
    }

    /// Plays a trailer or extra. A user-added extra has a library ratingKey. A Plex IVA
    /// extra has none, only `key`, an absolute part path (`/services/iva/assets/...`) that
    /// 404s under `/library/metadata` (#255); it plays directly through a synthetic PlexMetadata.
    /// `server` defaults to the one the extra's own provider lives on.
    static func play(_ trailer: BelowFoldTrailer, server: PlexServerAddress? = nil, from presenter: UIViewController) {
        if let videoID = trailer.youTubeVideoID {
            confirmYouTube(videoID, from: presenter)
            return
        }
        let key = trailer.playbackKey ?? trailer.id
        // Off Plex an extra is a library item of its own provider.
        if let provider = MediaProviderRegistry.shared.provider(for: trailer.providerID), provider.kind != .plex {
            playProviderExtra(MediaItemRef(providerID: trailer.providerID, itemID: key), provider: provider, from: presenter)
            return
        }
        let server = server ?? MediaProviderRegistry.shared.plexServer(for: trailer.providerID)
        let route = ExtraPlaybackKey.route(for: key)

        // Context for the request's own Sentry capture, whose endpoint tag cannot group IVA paths.
        let crumb = Breadcrumb(level: .info, category: "playback.extra")
        crumb.message = "Playing extra"
        crumb.data = [
            "route": route.telemetryName,
            "subtype": trailer.subtype.displayName,
            "key_shape": ExtraPlaybackKey.keyShape(key),
            "had_playback_key": trailer.playbackKey != nil
        ]
        SentryBridge.addBreadcrumb(crumb)

        switch route {
        case .libraryMetadata(let ratingKey):
            // nil = resume from whatever the server has for this extra.
            presentPlayer(ratingKey: ratingKey, resumeOffset: nil, server: server, from: presenter)

        case .directPartPath(let path):
            // IVA extras aren't library items, so /:/timeline never recorded a
            // position for them — there is nothing to resume from.
            guard let serverURL = server?.address, let token = server?.token else {
                extraPlayerLog.error("extra play: no server/token")
                return
            }
            extraPlayerLog.info("extra play: direct part path (non-library extra)")
            present(playItem: syntheticMetadata(forPartKey: path, trailer: trailer),
                    serverURL: serverURL, token: token, resumeOffset: nil, mediaID: nil, from: presenter)
        }
    }

    /// A Jellyfin or Emby internet trailer plays in the YouTube app, after a confirm.
    private static func confirmYouTube(_ videoID: String, from presenter: UIViewController) {
        presenter.present(ConfirmationPopupViewController(
            title: String(localized: "Open in YouTube"),
            message: String(localized: "This trailer plays in the YouTube app."),
            confirmTitle: String(localized: "Open in YouTube"),
            onConfirm: {
                guard let url = YouTubeTrailer.appURL(videoID: videoID) else { return }
                UIApplication.shared.open(url) { opened in
                    guard !opened else { return }
                    presenter.present(ConfirmationPopupViewController(
                        title: String(localized: "YouTube Isn't Installed"),
                        message: String(localized: "Install YouTube from the App Store to watch this trailer."),
                        confirmTitle: String(localized: "OK"), cancelTitle: nil, onConfirm: {}), animated: true)
                }
            }), animated: true)
    }

    private static func playProviderExtra(_ ref: MediaItemRef, provider: any MediaProvider, from presenter: UIViewController) {
        Task { [weak presenter] in
            do {
                let detail = try await provider.fullDetail(for: ref)
                guard let presenter else { return }
                ProviderPlayer.play(detail.item, fromBeginning: false, from: presenter, onDismiss: nil)
            } catch {
                extraPlayerLog.error("extra play: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Minimal PlexMetadata standing in for a non-library extra, carrying the
    /// part path ContentRouter needs to build a direct-play URL.
    private static func syntheticMetadata(forPartKey key: String, trailer: BelowFoldTrailer) -> PlexMetadata {
        let part = PlexPart(id: 0, key: key, duration: nil, file: nil, size: nil, container: nil, Stream: nil)
        let media = PlexMedia(
            id: 0, duration: nil, bitrate: nil, width: nil, height: nil, aspectRatio: nil,
            audioChannels: nil, audioCodec: nil, videoCodec: nil, videoResolution: nil,
            container: nil, videoFrameRate: nil, Part: [part]
        )
        return PlexMetadata(
            ratingKey: trailer.id,
            key: key,
            type: "clip",
            title: trailer.title,
            Media: [media]
        )
    }

    private static func present(playItem: PlexMetadata, serverURL: String, token: String, resumeOffset: Double?,
                                mediaID: String?, from presenter: UIViewController) {
        let viewModel = UniversalPlayerViewModel(
            metadata: playItem,
            serverURL: serverURL,
            authToken: token,
            startOffset: resumeOffset,
            preferredMediaID: mediaID
        )
        // From the topmost VC, so Play also works from a page over the carousel.
        PlayerPresenter.present(viewModel: viewModel, from: presenter)
    }
}
