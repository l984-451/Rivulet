// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Combine
import SwiftUI

/// A Live TV channel on the iOS player. Switches channel in place.
@MainActor
final class IOSLivePlayback: ObservableObject, IOSPlaybackSession {
    let player = AetherPlayer()
    @Published private(set) var channel: UnifiedChannel
    /// Shown instead of the engine's failure: a refused tune or a busy tuner.
    @Published private(set) var notice: String?
    /// Start from Beginning or Watch Live, for a recording in progress (#444).
    @Published private(set) var startQuestion: LiveStartQuestion?
    /// How far the session's edge trails live: nonzero only after a join at a
    /// recording's start, which then plays at 1x.
    @Published private(set) var liveLag: TimeInterval = 0
    var onItemChange: (() -> Void)?
    /// The next join is Go Live from such a session: no question, the edge.
    private var joinsLiveWithoutAsking = false
    /// The recording this session plays from (Start from Beginning), and where it was loaded.
    private var recordingStart: LiveRecordingStart?

    private let store = LiveTVDataStore.shared
    private let keepalive = PlexLiveTimelineKeepalive()
    private var loadTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var rolloverTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var shownProgramId: String?

    /// Skips stack here and land as one seek once the taps settle: AVPlayer
    /// cancelling its segment loads for every superseded seek is what takes a
    /// live item down under rapid taps.
    private let windowSeeker = LiveWindowSeekController()

    init(channel: UnifiedChannel) {
        self.channel = channel
        let player = player
        windowSeeker.attach(LiveWindowSeekController.Player(
            window: { [weak player] in
                guard let window = player?.liveWindow, let range = window.seekableRange else { return nil }
                return LiveSeekableWindow(lowerBound: range.lowerBound, upperBound: window.edgeTime)
            },
            position: { [weak player] in player?.liveWindow.playhead ?? 0 },
            seek: { [weak self] in await self?.seekWithinRecording(to: $0) },
            seekToLiveEdge: { [weak self] in await self?.seekToLiveEdge() },
            play: { [weak player] in player?.play() },
            isUserPaused: { [weak player] in player?.state == .paused },
            reach: { [weak self] in
                guard let self, let start = self.recordingStart else { return (0, 0) }
                return start.reach(lag: self.liveLag)
            }
        ))
        windowSeeker.onChange = { [weak self] in self?.objectWillChange.send() }
        // The channel's picture and sound, for the channel lists (`LiveStreamQualityStore`), once it
        // plays: a switch clears the size, so the old channel's sound never lands on the new one.
        // Playing is an input too: tracks that settled before it must still be noted.
        Publishers.CombineLatest4(player.$videoSize, player.$audioTracks, player.$currentAudioTrackId, player.$state)
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] size, audio, audioId, state in
                guard let self, state == .playing, size.height > 0 || !audio.isEmpty else { return }
                let track = audio.first { $0.id == audioId } ?? audio.first { $0.isDefault } ?? audio.first
                LiveStreamQualityStore.shared.record(channelId: self.channel.id,
                                                     height: size.height > 0 ? Int(size.height.rounded()) : nil,
                                                     audioChannels: track?.channels)
            }
            .store(in: &cancellables)
    }

    /// Where stacked skips will land while they settle, on the session axis.
    var stagedSkipTarget: Double? {
        if case .position(let target) = windowSeeker.pendingRequest { return target }
        return nil
    }

    /// Skip within the rewind window, stacked; without one, the player's own skip.
    func skip(by seconds: Double) {
        if player.liveWindow.seekableRange != nil || windowSeeker.isLanding {
            windowSeeker.step(by: seconds)
        } else {
            Task { await player.skip(by: seconds) }
        }
    }

    /// A seek on the session axis. The engine fetches a recording's backlog at 1x, so a target
    /// past what it holds (or before where this join began) reloads the recording there.
    private func seekWithinRecording(to target: Double) async {
        let window = player.liveWindow
        if let start = recordingStart, liveLag > 0, let range = window.seekableRange,
           let offset = start.rejoinOffset(
               forSessionPosition: target,
               in: LiveSeekableWindow(lowerBound: range.lowerBound, upperBound: window.edgeTime),
               edgeWall: Date().addingTimeInterval(-liveLag)) {
            await reloadRecording(start.joining(atOffset: offset))
            return
        }
        await player.seekLive(to: target)
    }

    /// Loads the same recorder session from a later (or earlier) offset. The tune and its
    /// keepalive stay, so a skip costs one playlist fetch, not a re-tune.
    private func reloadRecording(_ start: LiveRecordingStart) async {
        recordingStart = start
        liveLag = start.lag(at: Date())
        await reloadEngine(start.url, joinsAtRecordingStart: true)
    }

    /// The same recorder session joined at its head, which is live: no re-tune.
    private func reloadAtLive(_ start: LiveRecordingStart) async {
        let head = start.joining(atOffset: Date().timeIntervalSince(start.firstSegmentAired) - LiveRecordingStart.headMargin)
        recordingStart = nil
        liveLag = 0
        await reloadEngine(head.url, joinsAtRecordingStart: false)
    }

    /// Reloads the engine on the session already tuned. Awaited, so the skip control holds
    /// presses until the new window exists.
    private func reloadEngine(_ url: URL, joinsAtRecordingStart: Bool) async {
        let headers = LiveTVClientIdentity.streamHeaders(for: channel)
        loadTask?.cancel()
        let task = Task {
            do {
                try await player.loadLive(url: url, headers: headers,
                                          forceEngineDemux: true, joinsAtRecordingStart: joinsAtRecordingStart)
            } catch {
                guard !Task.isCancelled, !isCancellationError(error) else { return }
                // The session is gone: join live again rather than ask a second time.
                joinsLiveWithoutAsking = true
                retry()
            }
        }
        loadTask = task
        await task.value
    }

    /// The controller's far end. Behind a recording's head, live is the recording's head.
    private func seekToLiveEdge() async {
        if liveLag > 0, let start = recordingStart {
            await reloadAtLive(start)
        } else {
            await player.seekToLiveEdge()
        }
    }

    func goLive() {
        if liveLag > 0, let start = recordingStart {
            windowSeeker.cancelPending()
            Task { await reloadAtLive(start) }
            return
        }
        if liveLag > 0 {
            // Joined at a recording's start, the session only reaches its own edge; live is a new join.
            joinsLiveWithoutAsking = true
            retry()
            return
        }
        windowSeeker.cancelPending()
        Task { await player.seekToLiveEdge() }
    }

    func seek(to sessionSeconds: Double) {
        windowSeeker.cancelPending()
        Task { await player.seekLive(to: sessionSeconds) }
    }

    var programme: UnifiedProgram? { store.getCurrentProgram(for: channel) }

    var nowPlayingItem: IOSNowPlaying.Item {
        let programme = programme
        return IOSNowPlaying.Item(
            title: programme?.displayTitle ?? channel.displayName,
            subtitle: programme == nil ? nil : channel.displayName,
            artworkURL: channel.logoURL,
            isLive: true
        )
    }

    func begin() async {
        startRollover()
        retry()
        await loadTask?.value
    }

    func end() {
        windowSeeker.reset()
        loadTask?.cancel()
        watchTask?.cancel()
        rolloverTask?.cancel()
        keepalive.stop()
    }

    func screen(_ controller: IOSPlaybackController) -> AnyView {
        AnyView(IOSLivePlayerScreen(session: self, player: player, controller: controller))
    }

    func switchChannel(to newChannel: UnifiedChannel) {
        guard newChannel.id != channel.id else { return }
        channel = newChannel
        shownProgramId = programme?.id
        onItemChange?()
        retry()
    }

    func retry() {
        loadTask?.cancel()
        loadTask = Task { await load() }
    }

    private func load() async {
        notice = nil
        liveLag = 0
        recordingStart = nil
        windowSeeker.cancelPending()
        keepalive.stop()
        watchTask?.cancel()
        let channel = channel
        watchTask = store.beganWatching(channel)

        let url: URL
        let recordingStart: LiveRecordingStart?
        do {
            let resolved = try await store.resolveStreamURLAndRecordingStart(for: channel)
            guard let resolvedURL = resolved.url else {
                notice = String(localized: "This channel has no stream.")
                return
            }
            url = resolvedURL
            recordingStart = resolved.recordingStart
        } catch {
            guard !isCancellationError(error) else { return }
            notice = error is PlexLiveTuneError
                ? String(localized: "Couldn't tune this channel. All tuners may be busy.")
                : (error as? TvheadendError)?.errorDescription ?? String(localized: "Couldn't tune this channel.")
            return
        }
        // A tune that finished after Close or a switch still holds the tuner.
        guard !Task.isCancelled else { PlexLiveTimelineKeepalive.release(url); return }

        // A no-op unless the URL is a Plex tuned session.
        keepalive.start(url: url)
        let asksForStart = !joinsLiveWithoutAsking
        joinsLiveWithoutAsking = false
        var fromStart: LiveRecordingStart?
        if asksForStart, let recordingStart {
            let question = LiveStartQuestion(recording: recordingStart.recording)
            if await question.ask(present: { startQuestion = question }) { fromStart = recordingStart }
            if startQuestion === question { startQuestion = nil }
            guard !Task.isCancelled else { return }
        }
        self.recordingStart = fromStart
        liveLag = fromStart?.lag(at: Date()) ?? 0
        let headers = LiveTVClientIdentity.streamHeaders(for: channel)
        do {
            try await player.loadLive(url: fromStart?.url ?? url, headers: headers,
                                      forceEngineDemux: url.path.hasPrefix("/livetv/sessions/"),
                                      joinsAtRecordingStart: fromStart != nil)
        } catch {
            guard !Task.isCancelled, !isCancellationError(error) else { return }
            keepalive.stop()
            if channel.sourceType != .plex, await LiveTunerBusy.sourceIsBusy(url, headers: headers) {
                notice = String(localized: "All tuners are busy. Stop another stream and try again.")
            }
        }
    }

    /// Now Playing follows the programme across its boundaries.
    private func startRollover() {
        shownProgramId = programme?.id
        rolloverTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self else { return }
                let id = self.programme?.id
                if id != self.shownProgramId {
                    self.shownProgramId = id
                    self.onItemChange?()
                }
            }
        }
    }
}

private struct IOSLivePlayerScreen: View {
    @ObservedObject var session: IOSLivePlayback
    @ObservedObject var player: AetherPlayer
    @ObservedObject var controller: IOSPlaybackController
    @ObservedObject private var store = LiveTVDataStore.shared
    @StateObject private var recorder = LiveRecorder()
    @State private var captionStyle = CaptionAppearance.current()
    @State private var showsChannels = false
    @State private var info: LiveProgrammeSelection?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let programme = programme(at: context.date)
            IOSPlayerChrome(
                title: programme?.displayTitle ?? session.channel.displayName,
                subtitle: session.channel.displayNumberAndName,
                isPlaying: player.state == .playing,
                isBusy: session.notice == nil && (player.state == .idle || player.state == .loading || player.isBuffering),
                timeline: .live(
                    range: player.liveWindow.seekableRange,
                    position: session.stagedSkipTarget ?? player.pendingSeekTarget ?? player.liveWindow.playhead,
                    edge: player.liveWindow.edgeTime,
                    isAtEdge: player.liveWindow.isAtLiveEdge && session.liveLag == 0,
                    programme: programme.map { $0.startTime...$0.endTime }
                ),
                audioTracks: player.audioTracks,
                selectedAudioID: player.currentAudioTrackId,
                subtitleTracks: player.subtitleTracks,
                selectedSubtitleID: player.currentSubtitleTrackId,
                failure: failure,
                isMuted: player.isMuted,
                canPictureInPicture: controller.isPictureInPicturePossible,
                actions: IOSPlayerChromeActions(
                    close: controller.close,
                    playPause: player.togglePlayPause,
                    skip: session.skip(by:),
                    seek: session.seek(to:),
                    goLive: session.goLive,
                    selectAudio: player.selectAudioTrack,
                    selectSubtitle: player.selectSubtitleTrack,
                    stepAudioDelay: player.stepAudioDelay,
                    pictureInPicture: controller.startPictureInPicture,
                    toggleMute: { player.setMuted(!player.isMuted) },
                    setFillsScreen: { player.fillsScreen = $0 },
                    retry: session.retry,
                    swipeDown: controller.dismissGesture
                ),
                liveScrub: liveScrub(now: context.date.addingTimeInterval(-session.liveLag))
            ) { osdTop in
                ZStack {
                    IOSPlayerSurface(surface: controller.surface)
                    IOSAetherSubtitleOverlay(
                        cues: player.subtitleCues.filter { $0.startTime <= player.sourceTime && $0.endTime >= player.sourceTime },
                        nativeCues: player.nativeSubtitleCues,
                        style: captionStyle,
                        osdTop: osdTop,
                        videoSize: player.videoSize,
                        fillsScreen: player.fillsScreen
                    )
                }
            } trailing: {
                hostButtons(programme: programme)
            }
        }
        .sheet(isPresented: $showsChannels) {
            NavigationStack {
                IOSLiveListView(mode: .picker(current: session.channel)) { session.switchChannel(to: $0) }
                    .navigationTitle("Channels")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(role: .confirm) { showsChannels = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $info) { selection in
            IOSLiveProgrammeSheet(selection: selection, onWatch: nil)
        }
        .liveRecorder(recorder)
        .alert("Recording in Progress", isPresented: Binding(
            get: { session.startQuestion != nil },
            // Dismissed without a choice: Watch Live. After a choice this is a no-op.
            set: { if !$0 { session.startQuestion?.answer(startsFromBeginning: false) } }
        ), presenting: session.startQuestion) { question in
            Button("Start from Beginning") { question.answer(startsFromBeginning: true) }
            Button("Watch Live", role: .cancel) { question.answer(startsFromBeginning: false) }
        } message: { question in
            Text(verbatim: question.recording.title)
        }
        .onReceive(NotificationCenter.default.publisher(for: CaptionAppearance.changedNotification)) { _ in
            captionStyle = CaptionAppearance.current()
        }
    }

    /// The bar reaching back over the rewind window, split at the earlier
    /// programmes it covers (at most four hours), on the session axis.
    private func liveScrub(now: Date) -> IOSLiveScrub? {
        let window = player.liveWindow
        guard let range = window.seekableRange, window.edgeTime > range.lowerBound else { return nil }
        let onAir = store.program(for: session.channel, at: now) ?? store.getCurrentProgram(for: session.channel)
        let earlier = onAir.map {
            store.getPrograms(for: session.channel,
                              startDate: now.addingTimeInterval(-LiveTimelineLayout.maximumLookback),
                              endDate: $0.startTime)
        } ?? []
        guard let layout = LiveTimelineLayout(
            now: now, program: onAir, earlierPrograms: earlier,
            seekWindowSeconds: window.edgeTime - range.lowerBound,
            behindLiveSeconds: max(0, window.edgeTime - window.playhead)
        ) else { return nil }
        // Wall clock to session axis: the edge is now.
        let span = layout.end.timeIntervalSince(layout.start)
        func onAxis(_ date: Date) -> Double { window.edgeTime - now.timeIntervalSince(date) }
        return IOSLiveScrub(
            bar: onAxis(layout.start)...max(onAxis(layout.end), onAxis(layout.start) + 1),
            sections: layout.boundaries.map { onAxis(layout.start.addingTimeInterval(span * $0)) }
        )
    }

    /// The programme at the playhead: behind live, that is in the past.
    private func programme(at date: Date) -> UnifiedProgram? {
        let window = player.liveWindow
        let behind = window.isAtLiveEdge ? 0 : max(0, window.edgeTime - window.playhead)
        return store.program(for: session.channel, at: date.addingTimeInterval(-behind - session.liveLag))
    }

    private var failure: IOSPlayerFailure? {
        if let notice = session.notice { return IOSPlayerFailure(message: notice, canRetry: true) }
        guard case .failed(let message) = player.state else { return nil }
        return IOSPlayerFailure(message: message, canRetry: player.canRetry)
    }

    @ViewBuilder
    private func hostButtons(programme: UnifiedProgram?) -> some View {
        let channel = session.channel
        glassButton("Channels", systemImage: "list.bullet") { showsChannels = true }

        let isFavorite = store.isFavorite(channel)
        glassButton(isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: isFavorite ? "star.fill" : "star") {
            store.toggleFavorite(channel)
        }
        .sensoryFeedback(.selection, trigger: isFavorite)

        if let programme, store.canRecord(channel) {
            if let recording = store.activeRecording(for: programme) {
                Menu {
                    Button(recording.status == .recording ? "Stop Recording" : "Cancel Recording",
                           systemImage: "stop.circle", role: .destructive) { recorder.cancel(recording) }
                    if recording.ruleIsSeries {
                        Button("Cancel Series", systemImage: "square.stack.3d.up.slash", role: .destructive) {
                            recorder.cancelSeries(of: recording)
                        }
                    }
                } label: {
                    glassLabel(systemImage: "record.circle.fill").foregroundStyle(.red)
                }
                .accessibilityLabel("Recording")
            } else {
                glassButton("Record", systemImage: "record.circle") {
                    recorder.offerRecording(programme, on: channel)
                }
                .disabled(recorder.isLoadingOptions)
            }
        }

        if programme != nil {
            glassButton("Info", systemImage: "info.circle") {
                info = LiveProgrammeSelection(channel: channel, program: programme)
            }
        }
    }

    private func glassButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { glassLabel(systemImage: systemImage) }
            .accessibilityLabel(title)
    }

    private func glassLabel(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.body.weight(.semibold))
            .frame(width: 44, height: 44)
            .glassEffect(.regular.interactive(), in: .circle)
    }
}
