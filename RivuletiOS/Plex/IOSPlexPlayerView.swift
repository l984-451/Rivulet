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
    /// Plex stream ids picked on a transcode; subtitle 0 is Off.
    @Published private(set) var chosenAudioID: Int?
    @Published private(set) var chosenSubtitleID: Int?
    var onItemChange: (() -> Void)?

    private let plex: IOSPlexSession
    private var skippedMarkerIDs: Set<String> = []
    private var lastReportBucket = -1
    private var reportedStopped = false
    private var countdownTask: Task<Void, Never>?
    private var nextLookupTask: Task<Void, Never>?
    private var nextTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var longStallTask: Task<Void, Never>?
    private var stallTracker = StallTracker()
    /// The player-menu pick; nil follows the Home or Away setting, item by item.
    private var sessionQuality: StreamingQuality?
    /// Plex stream ids a fresh load still has to select on the engine; subtitle 0 is Off.
    private var pendingEngineAudio: Int?
    private var pendingEngineSubtitle: Int?
    private var hasPlayed = false
    private var didFallBack = false
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
            artworkURL: request.localArtworkURL ?? plex.artworkURL(for: request.item, kind: .poster, width: 600, height: 900),
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
        reloadTask?.cancel()
        longStallTask?.cancel()
        let finish = finishItem(at: player.currentTime)
        let plex = plex
        let request = request
        // Repaint only after the stopped report and scrobble land.
        Task {
            await finish?.value
            await plex.watchStateDidChange()
        }
        Task { await plex.stopTranscode(request) }
    }

    func screen(_ controller: IOSPlaybackController) -> AnyView {
        AnyView(IOSPlexPlayerScreen(session: self, player: player, controller: controller))
    }

    // MARK: - Loading

    private func load(keepingTransport: Bool = false) async {
        hasPlayed = false
        stallTracker.noteSeekOrLoad(at: .now)
        // A transcode's text subtitle arrives as a WebVTT rendition nothing selects; the file
        // opens on its default tracks, so picks made on a transcode carry back.
        pendingEngineAudio = isTranscoding ? nil : chosenAudioID
        pendingEngineSubtitle = isTranscoding ? selectedSubtitleID : chosenSubtitleID
        await plex.openTranscode(request)
        try? await player.load(
            url: request.url,
            headers: request.headers,
            startTime: request.startTime,
            externalSubtitles: request.sidecarSubtitles,
            keepingTransport: keepingTransport
        )
    }

    func retry() {
        Task { await player.retry() }
    }

    // MARK: - Quality

    var qualityLabel: String {
        let playing = request.plan.step?.label ?? "Original"
        return request.quality == .auto ? "Auto · \(playing)" : playing
    }

    func switchQuality(_ quality: StreamingQuality) {
        guard quality != request.quality else { return }
        sessionQuality = quality
        reload(quality: quality)
    }

    /// Swaps the stream in place: no `onItemChange`, so PiP and Now Playing stay.
    /// `plan` skips the decision. A transcode starts on `streams`, else on the file's playing tracks.
    private func reload(
        quality: StreamingQuality,
        plan: StreamPlan? = nil,
        at time: TimeInterval? = nil,
        streams: (audio: Int?, subtitle: Int?)? = nil
    ) {
        reloadTask?.cancel()
        longStallTask?.cancel()
        let previous = request
        let time = time ?? player.pendingSeekTarget ?? player.currentTime
        let plex = plex
        // A file that never listed its tracks (a failed start) has no picks to carry.
        let picks = streams ?? (previous.plan == .original && !player.audioTracks.isEmpty ? enginePicksAsPlexIDs() : nil)
        reloadTask = Task { [weak self] in
            guard let next = try? await plex.playback(reloading: previous, quality: quality, plan: plan, at: time),
                  let self, !Task.isCancelled else { return }
            // Same plan from a menu change: only the choice moves.
            if plan == nil, streams == nil, next.plan == previous.plan {
                var kept = previous
                kept.quality = next.quality
                kept.measuredKbps = next.measuredKbps
                kept.measuredAt = next.measuredAt
                request = kept
                return
            }
            // Plex reads the part's selection when the session starts, which is the first fetch.
            if next.plan != .original, let picks {
                await plex.selectStream(audioID: picks.audio, subtitleID: picks.subtitle, in: previous)
                guard !Task.isCancelled else { return }
                if let audio = picks.audio { chosenAudioID = audio }
                if let subtitle = picks.subtitle { chosenSubtitleID = subtitle }
            }
            Task { await plex.stopTranscode(previous) }
            request = next
            await load(keepingTransport: true)
        }
    }

    /// Auto only: two stalls in a minute, or one that lasts, drops a step.
    private func stallChanged(_ stalled: Bool) {
        longStallTask?.cancel()
        guard stalled, request.quality == .auto else { return }
        switch stallTracker.bufferingStarted(at: .now) {
        case .ignored:
            break
        case .stepDown:
            stepDown()
        case .counted:
            longStallTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(StallTracker.longStall))
                guard !Task.isCancelled else { return }
                self?.stepDown()
            }
        }
    }

    private func stepDown() {
        guard let step = QualityDecision.stepDown(from: request.plan, sourceKbps: request.sourceKbps) else { return }
        stallTracker.noteStepDown()
        print("[Quality] Stalling, stepping down to \(step.label)")
        reload(quality: .auto, plan: .transcode(step))
    }

    /// A direct-play file that never starts gets one retry as a transcode, as on tvOS.
    private func fallBackToTranscode() {
        guard !hasPlayed, !didFallBack, request.plan == .original, !request.isLocal else { return }
        didFallBack = true
        let kbps = request.quality == .auto
            ? QualityDecision.capKbps(setting: .auto, measuredKbps: request.measuredKbps, isRelay: false) ?? 8000
            : 8000
        reload(quality: request.quality, plan: .transcode(QualityDecision.highestStep(atMost: kbps)),
               at: request.startTime ?? 0)
    }

    // MARK: - Tracks

    private var isTranscoding: Bool { request.plan != .original }

    /// A transcode lists the part's Plex streams; the file's own tracks otherwise.
    var audioTracks: [AetherPlayer.Track] {
        isTranscoding ? request.plexTracks(streamType: 2) : player.audioTracks
    }

    var selectedAudioID: Int? {
        isTranscoding ? chosenAudioID ?? request.selectedPlexStreamID(streamType: 2) : player.currentAudioTrackId
    }

    var subtitleTracks: [AetherPlayer.Track] {
        isTranscoding ? request.plexTracks(streamType: 3) : player.subtitleTracks
    }

    var selectedSubtitleID: Int? {
        guard isTranscoding else { return player.currentSubtitleTrackId }
        guard let chosenSubtitleID else { return request.selectedPlexStreamID(streamType: 3) }
        return chosenSubtitleID == 0 ? nil : chosenSubtitleID
    }

    /// On a transcode the server renders the tracks, so a change restarts it at the playhead.
    func selectAudio(_ id: Int) {
        guard isTranscoding else { return player.selectAudioTrack(id: id) }
        chosenAudioID = id
        reload(quality: request.quality, plan: request.plan, streams: (id, nil))
    }

    func selectSubtitle(_ id: Int?) {
        guard isTranscoding else { return player.selectSubtitleTrack(id: id) }
        chosenSubtitleID = id ?? 0
        reload(quality: request.quality, plan: request.plan, streams: (nil, id ?? 0))
    }

    private var plexStreams: [PlexStream] { request.item.Media?.first?.Part?.first?.Stream ?? [] }

    /// The engine's playing tracks as Plex stream ids. Embedded tracks join on the container
    /// stream index, sidecars on language. Subtitle 0 is Off.
    private func enginePicksAsPlexIDs() -> (audio: Int?, subtitle: Int?) {
        let streams = plexStreams
        let audio = player.currentAudioTrackId.flatMap { id in streams.first { $0.isAudio && $0.index == id }?.id }
        guard let subtitleID = player.currentSubtitleTrackId else { return (audio, 0) }
        let embedded = streams.first { $0.isSubtitle && $0.key == nil && $0.index == subtitleID }
        let language = player.subtitleTracks.first { $0.id == subtitleID }?.language
        let sidecar = streams.first {
            $0.isSubtitle && $0.key != nil && Self.sameLanguage($0.languageCode ?? $0.language, language)
        }
        return (audio, (embedded ?? sidecar)?.id)
    }

    /// Selects the pending Plex picks once the engine lists tracks they can map to.
    private func applyPendingEngineTracks() {
        let streams = plexStreams
        if let id = pendingEngineAudio, let index = streams.first(where: { $0.id == id })?.index,
           player.audioTracks.contains(where: { $0.id == index }) {
            pendingEngineAudio = nil
            player.selectAudioTrack(id: index)
        }
        guard let id = pendingEngineSubtitle, !player.subtitleTracks.isEmpty else { return }
        guard id != 0, let stream = streams.first(where: { $0.id == id }) else {
            pendingEngineSubtitle = nil
            if id == 0 { player.selectSubtitleTrack(id: nil) }
            return
        }
        let tracks = player.subtitleTracks
        let language = stream.languageCode ?? stream.language
        let match: AetherPlayer.Track? = if isTranscoding || stream.key != nil {
            tracks.first { Self.sameLanguage($0.language, language) } ?? (tracks.count == 1 ? tracks.first : nil)
        } else {
            tracks.first { $0.id == stream.index }
        }
        guard let match else { return }
        pendingEngineSubtitle = nil
        player.selectSubtitleTrack(id: match.id)
    }

    /// "eng" and "en" are the same language.
    private static func sameLanguage(_ a: String?, _ b: String?) -> Bool {
        func key(_ code: String?) -> String? {
            guard let code, !code.isEmpty else { return nil }
            return Locale.Language(identifier: code).languageCode?.identifier(.alpha2) ?? code.lowercased()
        }
        guard let a = key(a), let b = key(b) else { return false }
        return a == b
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

        player.$audioTracks
            .combineLatest(player.$subtitleTracks)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyPendingEngineTracks() }
            .store(in: &cancellables)

        player.$isStalled
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.stallChanged($0) }
            .store(in: &cancellables)

        // A seek buffers by design; the grace runs from its start and from its landing.
        player.$pendingSeekTarget
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.stallTracker.noteSeekOrLoad(at: .now) }
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
            hasPlayed = true
            reportedStopped = false
            report("playing")
        case .paused:
            report("paused")
        case .ended:
            finishItem(at: max(player.duration, player.currentTime))
            startUpNextCountdown()
        case .failed:
            fallBackToTranscode()
        default:
            break
        }
    }

    private func tick(_ time: TimeInterval) {
        // A load's clock reads 0 until it starts; an intro at 0 must not fire mid-reload.
        if !player.isStarting { evaluateAutoSkip(at: time) }
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
        reloadTask?.cancel()
        longStallTask?.cancel()
        let previous = request
        nextTask = Task { [weak self] in
            // Up Next keeps the player-menu pick, else decides Home or Away again; a fresh reading is reused.
            guard let self,
                  let nextRequest = try? await self.plex.playback(for: next, quality: self.sessionQuality, previous: previous),
                  !Task.isCancelled else { return }
            let plex = plex
            Task { await plex.stopTranscode(previous) }
            request = nextRequest
            chosenAudioID = nil
            chosenSubtitleID = nil
            didFallBack = false
            stallTracker = StallTracker()
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
            // A downloaded file has one quality: the one on disk.
            quality: session.request.isLocal ? nil : IOSPlayerQuality(
                choices: StreamingQuality.allChoices,
                selected: session.request.quality,
                label: session.qualityLabel
            ),
            audioTracks: session.audioTracks,
            selectedAudioID: session.selectedAudioID,
            subtitleTracks: session.subtitleTracks,
            selectedSubtitleID: session.selectedSubtitleID,
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
                selectQuality: session.switchQuality,
                selectAudio: session.selectAudio,
                selectSubtitle: session.selectSubtitle,
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
