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
    var onItemChange: (() -> Void)?

    private let store = LiveTVDataStore.shared
    private let keepalive = PlexLiveTimelineKeepalive()
    private var loadTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var rolloverTask: Task<Void, Never>?
    private var shownProgramId: String?

    init(channel: UnifiedChannel) {
        self.channel = channel
    }

    var programme: UnifiedProgram? { store.getCurrentProgram(for: channel) }

    var nowPlayingItem: IOSNowPlaying.Item {
        let programme = programme
        return IOSNowPlaying.Item(
            title: programme?.displayTitle ?? channel.name,
            subtitle: programme == nil ? nil : channel.name,
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
        keepalive.stop()
        watchTask?.cancel()
        let channel = channel
        watchTask = store.beganWatching(channel)

        let url: URL
        do {
            guard let resolved = try await store.resolveStreamURL(for: channel) else {
                notice = "This channel has no stream."
                return
            }
            url = resolved
        } catch {
            guard !isCancellationError(error) else { return }
            notice = error is PlexLiveTuneError
                ? "Couldn't tune this channel. All tuners may be busy."
                : "Couldn't tune this channel."
            return
        }
        // A tune that finished after Close or a switch still holds the tuner.
        guard !Task.isCancelled else { PlexLiveTimelineKeepalive.release(url); return }

        // A no-op unless the URL is a Plex tuned session.
        keepalive.start(url: url)
        let headers = LiveTVClientIdentity.streamHeaders(for: channel)
        do {
            try await player.loadLive(url: url, headers: headers,
                                      forceEngineDemux: url.path.hasPrefix("/livetv/sessions/"))
        } catch {
            guard !Task.isCancelled, !isCancellationError(error) else { return }
            keepalive.stop()
            if channel.sourceType != .plex, await LiveTunerBusy.sourceIsBusy(url, headers: headers) {
                notice = "All tuners are busy. Stop another stream and try again."
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
    @StateObject private var recorder = IOSLiveRecorder()
    @State private var captionStyle = CaptionAppearance.current()
    @State private var showsChannels = false
    @State private var info: IOSLiveProgrammeSelection?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let programme = programme(at: context.date)
            IOSPlayerChrome(
                title: programme?.displayTitle ?? session.channel.name,
                subtitle: session.channel.numberAndName,
                isPlaying: player.state == .playing,
                isBusy: session.notice == nil && (player.state == .idle || player.state == .loading || player.isBuffering),
                timeline: .live(
                    range: player.liveWindow.seekableRange,
                    position: player.pendingSeekTarget ?? player.liveWindow.playhead,
                    edge: player.liveWindow.edgeTime,
                    isAtEdge: player.liveWindow.isAtLiveEdge,
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
                    skip: { seconds in Task { await player.skip(by: seconds) } },
                    seek: { time in Task { await player.seekLive(to: time) } },
                    goLive: { Task { await player.seekToLiveEdge() } },
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
            } trailing: {
                hostButtons(programme: programme)
            }
        }
        .sheet(isPresented: $showsChannels) {
            IOSLiveChannelPicker(current: session.channel) { session.switchChannel(to: $0) }
        }
        .sheet(item: $info) { selection in
            IOSLiveProgrammeSheet(selection: selection, onWatch: nil)
        }
        .liveRecorder(recorder)
        .onReceive(NotificationCenter.default.publisher(for: CaptionAppearance.changedNotification)) { _ in
            captionStyle = CaptionAppearance.current()
        }
    }

    /// The programme at the playhead: behind live, that is in the past.
    private func programme(at date: Date) -> UnifiedProgram? {
        let window = player.liveWindow
        let behind = window.isAtLiveEdge ? 0 : max(0, window.edgeTime - window.playhead)
        return store.program(for: session.channel, at: date.addingTimeInterval(-behind))
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
                info = IOSLiveProgrammeSelection(channel: channel, program: programme)
            }
        }
    }

    private func glassButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
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

/// Every channel, favourites first, with what is on now. Picking one switches in place.
struct IOSLiveChannelPicker: View {
    let current: UnifiedChannel
    let onPick: (UnifiedChannel) -> Void
    @ObservedObject private var store = LiveTVDataStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                let favorites = filtered(store.favorites(in: store.channels))
                if !favorites.isEmpty {
                    Section("Favorites") { ForEach(favorites) { row($0) } }
                }
                Section(favorites.isEmpty ? "" : "All Channels") {
                    ForEach(filtered(store.channels)) { row($0) }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Channels")
            .navigationTitle("Channels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { dismiss() }
                }
            }
            .overlay {
                if !query.isEmpty, filtered(store.channels).isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func filtered(_ channels: [UnifiedChannel]) -> [UnifiedChannel] {
        guard !query.isEmpty else { return channels }
        return channels.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.channelNumber.map { String($0).hasPrefix(query) } == true
                || store.getCurrentProgram(for: $0)?.title.localizedCaseInsensitiveContains(query) == true
        }
    }

    private func row(_ channel: UnifiedChannel) -> some View {
        Button {
            onPick(channel)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                IOSLiveLogo(url: channel.logoURL)
                    .frame(width: 52, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.numberAndName).foregroundStyle(.primary)
                    if let programme = store.getCurrentProgram(for: channel) {
                        Text(programme.displayTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                if channel.id == current.id {
                    Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
                }
            }
        }
        .accessibilityAddTraits(channel.id == current.id ? .isSelected : [])
    }
}
