// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ProviderPlayback+Prepare.swift
//  Rivulet
//
//  The play entry point for any item that is not on the Plex path. Every
//  surface's Play routes a non-Plex item here; nothing in it knows which
//  backend it is talking to.
//

import UIKit

extension ProviderPlayback {
    /// Everything the player needs for `item`, fetched from its provider. The
    /// detail and the stream run concurrently unless a tier match needs the
    /// version list first; the extras wait for the stream so they ask about
    /// the source that will actually play. `quality` is the player session's
    /// pick; nil follows the Home or Away setting.
    static func prepare(item: MediaItem, provider: any MediaProvider,
                        version: VersionChoice = .best, quality: StreamingQuality? = nil,
                        throughput: (kbps: Int, at: Date)? = nil,
                        nativeQuality: MediaQualityPreference? = nil) async throws -> ProviderPlayback {
        guard item.isAvailable != false else { throw MediaProviderError.notPlayable }
        var reserved: StreamInfo?
        do {
            if let silo = provider as? SiloProvider {
                let detail = try await provider.fullDetail(for: item.ref)
                let sourceID = VersionRanking.choose(version, from: detail.mediaSources)?.id
                let account = await MainActor.run { SiloSession.account }
                let authority = SiloPlaybackAuthority(providerID: silo.id,
                    accountID: account?.userID ?? silo.profileID, profileID: silo.profileID)
                let seriesID = detail.item.grandparentRef?.itemID ?? item.grandparentRef?.itemID
                    ?? item.dismissalMetadata?.seriesID
                let libraryID = detail.item.libraryID ?? item.libraryID
                let context = SiloPlaybackOverrideContext(authority: authority,
                    libraryID: libraryID, seriesID: seriesID)
                let preferences = SiloPlaybackPreferences(provider: silo)
                let schema = try? await preferences.schema()
                let effective = schema == nil ? nil : try? await preferences.effective(
                    libraryID: libraryID.flatMap(Int.init), seriesID: seriesID)
                let policy = await SiloPlaybackPolicyStore.shared.resolve(context: context, server: effective,
                    manualQuality: nativeQuality)
                let stream = try await silo.resolveStream(for: item.ref, sourceID: sourceID, policy: policy)
                reserved = stream
                try Task.checkCancellation()
                let extras = await provider.playbackExtras(for: item.ref, sourceID: stream.source.id)
                try Task.checkCancellation()
                var settled = ProviderQuality()
                settled.choice = .auto
                settled.plan = .original
                var playback = ProviderPlayback(provider: provider, item: item, detail: detail, stream: stream,
                                                extras: extras, quality: settled)
                if case .value(let quality) = policy.quality { playback.nativeRequestedQuality = quality }
                else { playback.nativeRequestedQuality = .automatic }
                if case .value(let choice) = policy.bufferingPolicy { playback.nativeBufferingPolicy = choice }
                else { playback.nativeBufferingPolicy = .ask }
                return playback
            }
            let detail: MediaItemDetail
            var stream: StreamInfo
            if case .matchingTier = version {
                detail = try await provider.fullDetail(for: item.ref)
                let sourceID = VersionRanking.choose(version, from: detail.mediaSources)?.id
                stream = try await provider.resolveStream(for: item.ref, sourceID: sourceID)
                reserved = stream
            } else {
                let sourceID: String?
                if case .source(let id) = version { sourceID = id } else { sourceID = nil }
                async let fetched = provider.fullDetail(for: item.ref)
                stream = try await provider.resolveStream(for: item.ref, sourceID: sourceID)
                reserved = stream
                detail = try await fetched
            }
            try Task.checkCancellation()
            let decided = await decideQuality(quality, version: version, stream: stream,
                                              sources: detail.mediaSources, throughput: throughput)
            var settled = decided.quality
            if decided.quality.plan != .original || decided.sourceID != stream.source.id {
                do {
                    let replacement: StreamInfo
                    if let native = try await provider.replaceStream(
                        for: item.ref, current: stream,
                        sourceID: decided.sourceID == stream.source.id ? nil : decided.sourceID,
                        position: (stream.playerStartTime ?? 0) + stream.timelineOffset,
                        maxBitrate: decided.quality.plan.step.map { $0.kbps * 1000 },
                        audioStreamIndex: nil, subtitleStreamIndex: nil, forceTranscode: false
                    ) {
                        replacement = native
                    } else {
                        replacement = try await provider.resolveStream(
                            for: item.ref, sourceID: decided.sourceID,
                            maxBitrate: decided.quality.plan.step.map { $0.kbps * 1000 })
                    }
                    reserved = replacement
                    if replacement.playSessionID != stream.playSessionID {
                        await discardUnplayedStream(stream, provider: provider)
                    }
                    stream = replacement
                    if stream.source.streamKind == .directPlay { settled.plan = .original }
                } catch MediaProviderError.transcodeRequired {
                    // A server that won't transcode still plays the file it already offered.
                    settled.plan = .original
                }
            }
            let extras = await provider.playbackExtras(for: item.ref, sourceID: stream.source.id)
            try Task.checkCancellation()
            return ProviderPlayback(provider: provider, item: item, detail: detail, stream: stream, extras: extras,
                                    quality: settled)
        } catch {
            if let reserved { await discardUnplayedStream(reserved, provider: provider) }
            throw error
        }
    }

    /// Runs independently of a cancelled preparation task so native reservations can close.
    static func discardUnplayedStream(_ stream: StreamInfo, provider: any MediaProvider) async {
        await Task {
            do { _ = try await provider.discardStream(stream) }
            catch { DiagLog.error(.playback, "Unplayed provider session cleanup failed: \(DiagLog.describe(error))") }
        }.value
    }

    /// The plan for an uncapped `stream`, and the version that should play under it.
    /// Probes the direct stream only when Auto has no measurement younger than 10 minutes.
    private static func decideQuality(
        _ quality: StreamingQuality?, version: VersionChoice, stream: StreamInfo, sources: [MediaSource],
        throughput: (kbps: Int, at: Date)?
    ) async -> (quality: ProviderQuality, sourceID: String) {
        let directURL = stream.source.streamKind == .directPlay ? stream.source.streamURL : nil
        var settled = ProviderQuality()
        settled.isHome = StreamingQuality.isHome(serverURL: (stream.upstreamURL ?? stream.source.streamURL)?.absoluteString ?? "")
        settled.choice = quality ?? StreamingQuality.setting(home: settled.isHome)
        settled.probeURL = directURL
        if QualityDecision.needsProbe(setting: settled.choice, isRelay: false) {
            settled.throughput = await measure(directURL, reusing: throughput)
        }
        let measured = settled.throughput?.kbps
        let cap = QualityDecision.capKbps(setting: settled.choice, measuredKbps: measured, isRelay: false)
        let sourceID = cap.flatMap { VersionRanking.choose(version, from: sources, capKbps: $0)?.id } ?? stream.source.id
        let source = sources.first { $0.id == sourceID } ?? stream.source
        settled.plan = QualityDecision.decide(setting: settled.choice, sourceKbps: source.sourceKbps,
                                              measuredKbps: measured, isRelay: false)
        return (settled, sourceID)
    }

    /// `last` while it is younger than 10 minutes, else a fresh probe of `url`; nil when that fails.
    static func measure(_ url: URL?, reusing last: (kbps: Int, at: Date)?) async -> (kbps: Int, at: Date)? {
        if let last, Date().timeIntervalSince(last.at) < 600 { return last }
        guard let url, let kbps = await ThroughputProbe.measure(url: url) else { return nil }
        return (kbps, Date())
    }
}

extension MediaSource {
    /// Container bitrate in kbps, or size over duration when the provider omits it.
    var sourceKbps: Int? {
        if let bitrate, bitrate > 0 { return bitrate / 1000 }
        guard let fileSize, duration > 0 else { return nil }
        return Int(Double(fileSize) * 8 / duration / 1000)
    }
}

enum ProviderPlayer {
    /// True while a play is preparing. A second press in that window is
    /// ignored, so one press presents one player.
    @MainActor private(set) static var isStarting = false

    /// Claims the start, or returns false when one is already preparing.
    @MainActor static func claimStart() -> Bool {
        guard !isStarting else { return false }
        isStarting = true
        return true
    }

    @MainActor static func finishStart() { isStarting = false }

    /// Where playback starts: the server's resume point unless the user
    /// chose the beginning. Zero means no resume point.
    static func startOffset(detailOffset: TimeInterval, fromBeginning: Bool) -> TimeInterval? {
        fromBeginning || detailOffset <= 0 ? nil : detailOffset
    }

    /// A Plex item's resume point in seconds, gated on the shared resume policy
    /// as the selected server's play path does.
    static func plexStartOffset(_ metadata: PlexMetadata, fromBeginning: Bool) -> TimeInterval? {
        guard !fromBeginning, metadata.isInProgress else { return nil }
        return metadata.viewOffset.map { TimeInterval($0) / 1000 }
    }

    /// Play `item` from its own provider. A show or a season resolves to the
    /// episode Play means first, the same way the Plex path does. `playQueue`
    /// is the playlist `item` starts.
    @MainActor
    static func play(_ item: MediaItem, fromBeginning: Bool, sourceID: String? = nil,
                     playQueue: PlayQueue<PlaylistEntry>? = nil,
                     from presenter: UIViewController, onDismiss: (() -> Void)?) {
        guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else {
            presentError(MediaProviderError.notFound, from: presenter)
            return
        }
        guard claimStart() else { return }
        Task { @MainActor in
            defer { finishStart() }
            var target = item
            if item.kind == .show || item.kind == .season {
                target = await EpisodePicker.resolvePlayTarget(for: item, provider: provider) ?? item
            }
            // The loading screen's art, fetched while the stream is resolved.
            async let loadingImages = HeroBackdropResolver.shared.playerLoadingImages(
                for: target.heroBackdropRequest())
            SiloThemeMusicController.shared.suspend()
            // Another Plex server's item takes the full Plex player with its own
            // server: markers, transcode fallback, content filter, BIF (#87).
            if let plex = provider as? PlexProvider {
                do {
                    let metadata = try await PlexNetworkManager.shared.getFullMetadata(
                        serverURL: plex.serverURL, authToken: plex.authToken, ratingKey: target.ref.itemID)
                    let (art, thumb) = await loadingImages
                    guard MediaProviderRegistry.shared.isCurrentAuthority(provider), !Task.isCancelled else {
                        SiloThemeMusicController.shared.resume()
                        return
                    }
                    let viewModel = UniversalPlayerViewModel(
                        metadata: metadata, serverURL: plex.serverURL, authToken: plex.authToken,
                        startOffset: plexStartOffset(metadata, fromBeginning: fromBeginning),
                        playQueue: playQueue,
                        loadingArtImage: art, loadingThumbImage: thumb, preferredMediaID: sourceID)
                    if !PlayerPresenter.present(viewModel: viewModel, from: presenter, onDismiss: onDismiss) {
                        SiloThemeMusicController.shared.resume()
                    }
                } catch {
                    SiloThemeMusicController.shared.resume()
                    presentError(MediaProviderError.mapping(error), from: presenter)
                }
                return
            }
            do {
                let playback = try await ProviderPlayback.prepare(
                    item: target, provider: provider, version: sourceID.map(VersionChoice.source) ?? .best)
                let (art, thumb) = await loadingImages
                guard MediaProviderRegistry.shared.isCurrentAuthority(provider), !Task.isCancelled else {
                    await ProviderPlayback.discardUnplayedStream(playback.stream, provider: provider)
                    SiloThemeMusicController.shared.resume()
                    return
                }
                let viewModel = UniversalPlayerViewModel(
                    providerPlayback: playback,
                    startOffset: startOffset(detailOffset: playback.detail.item.userState.viewOffset,
                                             fromBeginning: fromBeginning),
                    playQueue: playQueue,
                    loadingArtImage: art,
                    loadingThumbImage: thumb,
                    preferredMediaID: sourceID)
                PlayerPresenter.present(viewModel: viewModel, from: presenter, onDismiss: onDismiss)
            } catch {
                SiloThemeMusicController.shared.resume()
                presentError(error, from: presenter)
            }
        }
    }

    /// What the error popup says for a failed start.
    static func errorMessage(for error: Error) -> String {
        switch error as? MediaProviderError {
        case .transcodeRequired: "This server can't stream this title to Apple TV."
        case .unreachable: "Couldn't reach the server."
        case .unauthorized: "The server didn't accept your sign-in."
        default: "Something went wrong starting playback."
        }
    }

    @MainActor
    private static func presentError(_ error: Error, from presenter: UIViewController) {
        let popup = ConfirmationPopupViewController(
            title: "Couldn't Play", message: errorMessage(for: error),
            confirmTitle: "OK", cancelTitle: nil, onConfirm: {})
        presenter.topmostPresented.present(popup, animated: true)
    }
}
