// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Combine
import SwiftUI

/// A Plex item on the iOS player: timeline reports, skip markers and Up Next.
/// Owned by `IOSPlaybackController`, so it keeps reporting while in PiP.
@MainActor
final class IOSPlexPlayback: ObservableObject, IOSPlaybackSession {
    let player = AetherPlayer()
    @Published private(set) var request: IOSPlexPlaybackRequest
    @Published private(set) var nextEpisode: PlexMetadata?
    @Published private(set) var upNextCountdown: Int?
    @Published private(set) var upNextDismissed = false
    var onItemChange: (() -> Void)?

    private let plex: IOSPlexSession
    private var skippedMarkerIDs: Set<String> = []
    private var lastReportBucket = -1
    private var reportedStopped = false
    private var countdownTask: Task<Void, Never>?
    private var nextLookupTask: Task<Void, Never>?
    private var nextTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(request: IOSPlexPlaybackRequest, plex: IOSPlexSession) {
        self.request = request
        self.plex = plex
        observePlayer()
    }

    var nowPlayingItem: IOSNowPlaying.Item {
        IOSNowPlaying.Item(
            title: request.item.displayTitle,
            subtitle: request.item.subtitle,
            artworkURL: plex.artworkURL(for: request.item, kind: .poster, width: 600, height: 900),
            isLive: false
        )
    }

    func begin() async {
        lookUpNextEpisode()
        await load()
    }

    func end() {
        countdownTask?.cancel()
        nextLookupTask?.cancel()
        nextTask?.cancel()
        let finish = finishItem(at: player.currentTime)
        let plex = plex
        // Repaint only after the stopped report and scrobble land.
        Task {
            await finish?.value
            await plex.watchStateDidChange()
        }
    }

    func screen(_ controller: IOSPlaybackController) -> AnyView {
        AnyView(IOSPlexPlayerScreen(session: self, player: player, controller: controller))
    }

    // MARK: - Loading

    private func load() async {
        let item = request.item
        let resume = item.resumeSeconds
        let resumes = item.durationSeconds > 0
            ? WatchProgressPolicy.hasResumePoint(offsetSeconds: resume, runtimeSeconds: item.durationSeconds)
            : WatchProgressPolicy.hasResumePoint(offsetSeconds: resume)
        try? await player.load(
            url: request.url,
            headers: request.headers,
            startTime: resumes ? resume : nil,
            externalSubtitles: request.sidecarSubtitles
        )
    }

    func retry() {
        Task { await player.retry() }
    }

    // MARK: - Plex reporting

    /// Reports on every transport change and after seeks land, plus every
    /// 10 s of playback; `.ended` reports stopped and scrobbles.
    private func observePlayer() {
        player.$state
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.stateChanged(state) }
            .store(in: &cancellables)

        player.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in self?.tick(time) }
            .store(in: &cancellables)

        player.$pendingSeekTarget
            .removeDuplicates()
            .dropFirst()
            .filter { $0 == nil }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.report(self.player.state == .playing ? "playing" : "paused")
            }
            .store(in: &cancellables)
    }

    private func stateChanged(_ state: AetherPlayer.State) {
        switch state {
        case .playing:
            reportedStopped = false
            report("playing")
        case .paused:
            report("paused")
        case .ended:
            finishItem(at: max(player.duration, player.currentTime))
            startUpNextCountdown()
        default:
            break
        }
    }

    private func tick(_ time: TimeInterval) {
        evaluateAutoSkip(at: time)
        guard player.state == .playing else { return }
        let bucket = Int(time) / 10
        if bucket != lastReportBucket {
            lastReportBucket = bucket
            report("playing")
        }
    }

    private func report(_ state: String) {
        guard !reportedStopped else { return }
        let request = request
        let time = player.currentTime
        let plex = plex
        Task { await plex.reportProgress(for: request, time: time, state: state) }
    }

    /// Stopped, then a scrobble when the viewer got past the watched ceiling.
    @discardableResult
    private func finishItem(at time: TimeInterval) -> Task<Void, Never>? {
        guard !reportedStopped else { return nil }
        reportedStopped = true
        let request = request
        let plex = plex
        let runtime = player.duration > 0 ? player.duration : request.item.durationSeconds
        let watched = (WatchProgressPolicy.progress(offsetSeconds: time, runtimeSeconds: runtime) ?? 0)
            >= WatchProgressPolicy.completionThreshold
        return Task {
            await plex.reportProgress(for: request, time: time, state: "stopped")
            if watched { await plex.markWatched(request) }
        }
    }

    // MARK: - Markers

    var activeMarker: PlexMarker? {
        let time = player.currentTime
        return request.markers.first {
            !skippedMarkerIDs.contains($0.stableID) && time >= $0.start && time < $0.end
        }
    }

    private func evaluateAutoSkip(at time: TimeInterval) {
        guard let marker = activeMarker else { return }
        let key: String? = switch marker.type {
        case "intro": "autoSkipIntro"
        case "recap": "autoSkipRecap"
        case "commercial": "autoSkipAds"
        case "credits": "autoSkipCredits"
        default: nil
        }
        if let key, UserDefaults.standard.bool(forKey: key) { skip(marker) }
    }

    func skip(_ marker: PlexMarker) {
        skippedMarkerIDs.insert(marker.stableID)
        objectWillChange.send()
        Task { await player.seek(to: marker.end) }
    }

    // MARK: - Up Next

    /// Near the end: inside the credits marker, or the last 30 s.
    var isNearEnd: Bool {
        if activeMarker?.type == "credits" { return true }
        let duration = player.duration
        return duration > 60 && player.currentTime >= duration - 30
    }

    private func lookUpNextEpisode() {
        nextLookupTask?.cancel()
        let episode = request.item
        let request = request
        let plex = plex
        nextLookupTask = Task { [weak self] in
            let next = await plex.nextEpisode(after: episode, in: request)
            guard !Task.isCancelled else { return }
            self?.nextEpisode = next
        }
    }

    private func startUpNextCountdown() {
        guard nextEpisode != nil, !upNextDismissed else { return }
        countdownTask?.cancel()
        upNextCountdown = 5
        countdownTask = Task { [weak self] in
            while let remaining = self?.upNextCountdown, remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.upNextCountdown = remaining - 1
            }
            guard !Task.isCancelled else { return }
            self?.playNext()
        }
    }

    func cancelUpNext() {
        countdownTask?.cancel()
        upNextCountdown = nil
        upNextDismissed = true
    }

    func playNext() {
        guard let next = nextEpisode else { return }
        countdownTask?.cancel()
        upNextCountdown = nil
        finishItem(at: player.currentTime)
        nextTask?.cancel()
        nextTask = Task { [weak self] in
            guard let self, let nextRequest = try? await self.plex.playback(for: next), !Task.isCancelled else { return }
            request = nextRequest
            nextEpisode = nil
            upNextDismissed = false
            skippedMarkerIDs = []
            lastReportBucket = -1
            reportedStopped = false
            onItemChange?()
            lookUpNextEpisode()
            await load()
        }
    }
}

private struct IOSPlexPlayerScreen: View {
    @ObservedObject var session: IOSPlexPlayback
    @ObservedObject var player: AetherPlayer
    @ObservedObject var controller: IOSPlaybackController
    @State private var captionStyle = CaptionAppearance.current()

    var body: some View {
        let item = session.request.item
        IOSPlayerChrome(
            title: item.displayTitle,
            subtitle: item.subtitle,
            isPlaying: player.state == .playing,
            isBusy: player.state == .idle || player.state == .loading || player.isBuffering
                || (player.isStarting && player.state == .playing),
            timeline: .vod(
                position: player.pendingSeekTarget ?? player.currentTime,
                duration: player.duration > 0 ? player.duration : item.durationSeconds
            ),
            rate: player.rate,
            audioTracks: player.audioTracks,
            selectedAudioID: player.currentAudioTrackId,
            subtitleTracks: player.subtitleTracks,
            selectedSubtitleID: player.currentSubtitleTrackId,
            contextualAction: contextualAction,
            failure: failure,
            isMuted: player.isMuted,
            canPictureInPicture: controller.isPictureInPicturePossible,
            actions: IOSPlayerChromeActions(
                close: controller.close,
                playPause: player.togglePlayPause,
                skip: { seconds in Task { await player.skip(by: seconds) } },
                seek: { time in Task { await player.seek(to: time) } },
                setRate: player.setRate,
                selectAudio: player.selectAudioTrack,
                selectSubtitle: player.selectSubtitleTrack,
                pictureInPicture: controller.startPictureInPicture,
                toggleMute: { player.setMuted(!player.isMuted) },
                setFillsScreen: { player.fillsScreen = $0 },
                retry: session.retry,
                swipeDown: controller.dismissGesture
            )
        ) { osdTop in
            ZStack {
                IOSPlayerSurface(surface: controller.surface)
                IOSAetherSubtitleOverlay(
                    cues: player.subtitleCues.filter { $0.startTime <= player.sourceTime && $0.endTime >= player.sourceTime },
                    nativeCues: player.nativeSubtitleCues,
                    style: captionStyle,
                    landscapeOSDTop: osdTop,
                    videoSize: player.videoSize,
                    fillsScreen: player.fillsScreen
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: CaptionAppearance.changedNotification)) { _ in
            captionStyle = CaptionAppearance.current()
        }
    }

    private var failure: IOSPlayerFailure? {
        guard case .failed(let message) = player.state else { return nil }
        return IOSPlayerFailure(message: message, canRetry: player.canRetry)
    }

    private var contextualAction: IOSPlayerContextualAction? {
        if let countdown = session.upNextCountdown {
            return IOSPlayerContextualAction(
                title: "Next Episode in \(countdown)",
                systemImage: "forward.end.fill",
                action: session.playNext,
                cancel: session.cancelUpNext
            )
        }
        if session.nextEpisode != nil, !session.upNextDismissed, session.isNearEnd {
            return IOSPlayerContextualAction(title: "Next Episode", systemImage: "forward.end.fill", action: session.playNext)
        }
        if let marker = session.activeMarker {
            return IOSPlayerContextualAction(
                title: "Skip \(marker.displayName)",
                systemImage: marker.isCommunity ? "person.3.fill" : nil,
                action: { session.skip(marker) }
            )
        }
        return nil
    }
}
