// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import AppKit
import SwiftUI

/// The full-window player for a live channel: the VOD chrome with the rewind window for a
/// scrubber, Go Live, the channel picker, programme info, favourite and Record.
/// Parity source: `IOSLivePlayerScreen`.
struct MacLivePlayerView: View {
    @ObservedObject var session: MacLivePlayback
    @ObservedObject var player: AetherPlayer
    @ObservedObject var controller: MacPlaybackController
    @ObservedObject private var store = LiveTVDataStore.shared
    @StateObject private var recorder = LiveRecorder()

    @State private var captionStyle = CaptionAppearance.current()
    @State private var chromeVisible = true
    @State private var overControls = false
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubValue: Double?
    @State private var pointerLocation: CGPoint?
    @State private var bottomBarTop: CGFloat?
    @State private var isFullScreen = false
    @State private var showsChannels = false
    @State private var info: LiveProgrammeSelection?
    @AppStorage(AudioSync.key) private var audioDelayMs = 0
    @AppStorage(CaptionHeight.key) private var captionHeightUnits = 0

    private static let space = "mac-live-player"

    var body: some View {
        ZStack {
            Color.black
            MacPlayerSurface(surface: controller.surface)
            MacAetherSubtitleOverlay(
                cues: player.subtitleCues.filter { $0.startTime <= player.sourceTime && $0.endTime >= player.sourceTime },
                nativeCues: player.nativeSubtitleCues,
                style: captionStyle,
                osdTop: chromeVisible ? bottomBarTop : nil,
                videoSize: player.videoSize,
                fillsScreen: player.fillsScreen
            )

            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    TapGesture(count: 2).onEnded { controller.toggleFullScreen() }
                        .exclusively(before: TapGesture().onEnded { controller.togglePlayPause() })
                )
                .gesture(MagnifyGesture().onEnded { player.fillsScreen = $0.magnification > 1 })

            TimelineView(.periodic(from: .now, by: 15)) { context in
                controls(programme: programme(at: context.date))
            }
            .opacity(chromeVisible ? 1 : 0)
            .allowsHitTesting(chromeVisible)

            if isBusy, !chromeVisible, failure == nil {
                ProgressView().controlSize(.large).colorScheme(.dark)
            }
            if let failure { failureCard(failure) }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(MacBottomBarTopKey.self) { bottomBarTop = $0 }
        .onContinuousHover { phase in
            if case .active(let location) = phase { pointerMoved(to: location) }
        }
        .background(MacWindowReader(isFullScreen: $isFullScreen, onEscape: { controller.escape() }))
        .foregroundStyle(.white)
        .tint(.white)
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.25), value: chromeVisible)
        .onAppear(perform: scheduleHide)
        .onDisappear { hideTask?.cancel() }
        .onChange(of: player.state == .playing) { _, playing in
            if !playing { chromeVisible = true }
            scheduleHide()
        }
        .onChange(of: failure) { _, failure in if failure != nil { chromeVisible = true } }
        .onReceive(NotificationCenter.default.publisher(for: CaptionAppearance.changedNotification)) { _ in
            captionStyle = CaptionAppearance.current()
        }
        .sheet(item: $info) { MacLiveProgrammeSheet(selection: $0, onWatch: nil) }
        .liveRecorder(recorder)
    }

    // MARK: - State

    private var isPlaying: Bool { player.state == .playing }

    private var isBusy: Bool {
        session.notice == nil && (player.state == .idle || player.state == .loading || player.isBuffering)
    }

    private var failure: MacPlayerFailure? {
        if let notice = session.notice { return MacPlayerFailure(message: notice, canRetry: true) }
        guard case .failed(let message) = player.state else { return nil }
        return MacPlayerFailure(message: message, canRetry: player.canRetry)
    }

    /// The bar reaching back over the rewind window, split at the earlier programmes it covers.
    private func liveScrub(now: Date) -> (bar: ClosedRange<Double>, sections: [Double])? {
        let window = player.liveWindow
        guard let range = window.seekableRange, window.edgeTime > range.lowerBound else { return nil }
        let onAir = store.getCurrentProgram(for: session.channel)
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
        let span = layout.end.timeIntervalSince(layout.start)
        func onAxis(_ date: Date) -> Double { window.edgeTime - now.timeIntervalSince(date) }
        return (onAxis(layout.start)...max(onAxis(layout.end), onAxis(layout.start) + 1),
                layout.boundaries.map { onAxis(layout.start.addingTimeInterval(span * $0)) })
    }

    /// The programme at the playhead: behind live, that is in the past.
    private func programme(at date: Date) -> UnifiedProgram? {
        let window = player.liveWindow
        let behind = window.isAtLiveEdge ? 0 : max(0, window.edgeTime - window.playhead)
        return store.program(for: session.channel, at: date.addingTimeInterval(-behind))
    }

    // MARK: - Controls

    private func controls(programme: UnifiedProgram?) -> some View {
        VStack(spacing: 0) {
            topBar(programme: programme)
            Spacer(minLength: 0)
            bottomBar(programme: programme)
        }
        .background {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.6), location: 0),
                    .init(color: .clear, location: 0.2),
                    .init(color: .clear, location: 0.65),
                    .init(color: .black.opacity(0.7), location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
    }

    private func topBar(programme: UnifiedProgram?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            iconButton("Close", systemImage: "xmark", action: controller.close)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.channel.numberAndName).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                Text(programme?.displayTitle ?? session.channel.name).font(.headline).lineLimit(1)
            }
            Spacer(minLength: 0)
            MacRoutePicker().frame(width: 28, height: 28).help("AirPlay")
            if controller.isPictureInPicturePossible {
                iconButton("Picture in Picture", systemImage: "pip.enter", action: controller.startPictureInPicture)
            }
        }
        .padding(.leading, isFullScreen ? 20 : 84)
        .padding(.trailing, 20)
        .padding(.top, isFullScreen ? 16 : 10)
        .onHover { overControls = $0; scheduleHide() }
    }

    private func bottomBar(programme: UnifiedProgram?) -> some View {
        let window = player.liveWindow
        let scrub = liveScrub(now: .now)
        return VStack(spacing: 6) {
            let range = window.seekableRange.flatMap { window.edgeTime > $0.lowerBound ? $0 : nil }
            if let range {
                MacPlayerScrubber(
                    range: scrub?.bar ?? range.lowerBound...window.edgeTime,
                    value: session.stagedSkipTarget ?? player.pendingSeekTarget ?? window.playhead,
                    scrubValue: $scrubValue,
                    scrubStill: nil,
                    seekable: scrub == nil ? nil : range.lowerBound...window.edgeTime,
                    sections: scrub?.sections ?? [],
                    onCommit: { time in
                        session.seek(to: time)
                        scheduleHide()
                    },
                    onStep: { controller.skip(forward: $0 > 0) }
                )
            }
            HStack {
                if let programme {
                    Text(programme.startTime...programme.endTime ~= Date() ? programmeTimes(programme) : "")
                }
                Spacer()
                let behind = range == nil ? 0 : max(0, window.edgeTime - (scrubValue ?? window.playhead))
                Text(behind < 1 ? String(localized: "Live") : "-" + MacPlayerView.format(behind))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
            ZStack {
                transport
                HStack {
                    volumeControls
                    Spacer(minLength: 12)
                    optionControls(programme: programme)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: 940)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: MacBottomBarTopKey.self, value: proxy.frame(in: .named(Self.space)).minY)
            }
        }
        .onHover { overControls = $0; scheduleHide() }
    }

    private func programmeTimes(_ programme: UnifiedProgram) -> String {
        "\(programme.startTime.formatted(date: .omitted, time: .shortened)) – \(programme.endTime.formatted(date: .omitted, time: .shortened))"
    }

    private var transport: some View {
        HStack(spacing: 18) {
            iconButton("Previous Channel", systemImage: "chevron.down.circle", size: 20) { controller.stepChannel(-1) }
            iconButton("Skip Back", systemImage: "gobackward", size: 20) { controller.skip(forward: false) }
            Button {
                controller.togglePlayPause()
                scheduleHide()
            } label: {
                Group {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.system(size: 22, weight: .semibold))
                    }
                }
                .frame(width: 36, height: 36)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            .help(isPlaying ? "Pause" : "Play")
            iconButton("Skip Forward", systemImage: "goforward", size: 20) { controller.skip(forward: true) }
            iconButton("Next Channel", systemImage: "chevron.up.circle", size: 20) { controller.stepChannel(1) }
        }
    }

    private var volumeControls: some View {
        HStack(spacing: 6) {
            iconButton(player.isMuted ? "Unmute" : "Mute",
                       systemImage: player.isMuted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                       action: controller.toggleMute)
            Slider(value: Binding(get: { player.isMuted ? 0 : Double(player.volume) },
                                  set: { controller.setVolume(Float($0)) }), in: 0...1)
                .controlSize(.small)
                .frame(width: 90)
                .accessibilityLabel("Volume")
        }
    }

    private func optionControls(programme: UnifiedProgram?) -> some View {
        let channel = session.channel
        let isFavorite = store.isFavorite(channel)
        return HStack(spacing: 6) {
            if !player.liveWindow.isAtLiveEdge {
                Button { session.goLive(); scheduleHide() } label: { MacLivePill(text: String(localized: "Go Live"), dot: true, style: .red) }
                    .buttonStyle(.plain)
            }
            iconButton("Channels", systemImage: "list.bullet") { showsChannels.toggle() }
                .popover(isPresented: $showsChannels, arrowEdge: .top) {
                    MacLiveChannelPicker(current: channel) { session.switchChannel(to: $0) }
                }
            iconButton(isFavorite ? "Remove from Favorites" : "Add to Favorites",
                       systemImage: isFavorite ? "star.fill" : "star") { store.toggleFavorite(channel) }
            if let programme, store.canRecord(channel) { recordControl(programme: programme) }
            if programme != nil {
                iconButton("Info", systemImage: "info.circle") {
                    info = LiveProgrammeSelection(channel: channel, program: programme)
                }
            }
            if !session.audioTracks.isEmpty || !session.subtitleTracks.isEmpty { tracksMenu }
            iconButton(isFullScreen ? "Exit Full Screen" : "Full Screen",
                       systemImage: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       action: controller.toggleFullScreen)
        }
    }

    @ViewBuilder
    private func recordControl(programme: UnifiedProgram) -> some View {
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
                Image(systemName: "record.circle.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(.red)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Recording")
        } else {
            iconButton("Record", systemImage: "record.circle") {
                recorder.offerRecording(programme, on: session.channel)
            }
            .disabled(recorder.isLoadingOptions)
        }
    }

    private var tracksMenu: some View {
        Menu {
            if !session.audioTracks.isEmpty {
                Picker("Audio", selection: Binding(
                    get: { session.selectedAudioID },
                    set: { id in if let id { session.selectAudio(id) } }
                )) {
                    ForEach(session.audioTracks) { MacTrackLabel(track: $0).tag(Optional($0.id)) }
                }
                .pickerStyle(.inline)
                Section("Audio Delay") {
                    Button("Earlier") { player.stepAudioDelay(by: -1) }
                    Button("Later") { player.stepAudioDelay(by: 1) }
                    Button("Reset (\(AudioSync.formatted(audioDelayMs)))") { player.stepAudioDelay(by: -audioDelayMs / AudioSync.stepMs) }
                        .disabled(audioDelayMs == 0)
                }
            }
            Picker("Subtitles", selection: Binding(get: { session.selectedSubtitleID }, set: { session.selectSubtitle($0) })) {
                Text("Off").tag(Int?.none)
                ForEach(session.subtitleTracks) { MacTrackLabel(track: $0).tag(Optional($0.id)) }
            }
            .pickerStyle(.inline)
            Section("Subtitle Height") {
                Button("Lower") { CaptionHeight.step(by: -1) }
                    .disabled(captionHeightUnits <= CaptionHeight.unitRange.lowerBound)
                Button("Higher") { CaptionHeight.step(by: 1) }
                    .disabled(captionHeightUnits >= CaptionHeight.unitRange.upperBound)
                Button("Reset (\(CaptionHeight.formatted(captionHeightUnits)))") { CaptionHeight.units = 0 }
                    .disabled(captionHeightUnits == 0)
            }
        } label: {
            Image(systemName: session.selectedSubtitleID == nil ? "captions.bubble" : "captions.bubble.fill")
                .font(.system(size: 15, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Audio and Subtitles")
    }

    private func failureCard(_ failure: MacPlayerFailure) -> some View {
        VStack(spacing: 14) {
            Image(systemName: failure.systemImage).font(.title).foregroundStyle(.yellow)
            Text(failure.title).font(.headline)
            Text(failure.message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Close", action: controller.close).buttonStyle(.glass)
                if failure.canRetry {
                    Button(action: session.retry) { Text("Retry").foregroundStyle(.black) }
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 380)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding()
    }

    private func iconButton(_ label: LocalizedStringKey, systemImage: String, size: CGFloat = 15,
                            action: @escaping () -> Void) -> some View {
        MacPlayerIconButton(label: label, systemImage: systemImage, size: size) {
            action()
            scheduleHide()
        }
    }

    // MARK: - Behaviour

    private func pointerMoved(to location: CGPoint) {
        defer { pointerLocation = location }
        guard let last = pointerLocation else { return }
        guard abs(location.x - last.x) > 2 || abs(location.y - last.y) > 2 else { return }
        if !chromeVisible { chromeVisible = true }
        scheduleHide()
    }

    /// Hides after 3 s while playing; paused, failed, scrubbing, a popover or a pointer over
    /// the controls keep them up.
    private func scheduleHide() {
        hideTask?.cancel()
        guard chromeVisible, isPlaying, failure == nil, !overControls, !showsChannels, info == nil else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, scrubValue == nil else { return }
            chromeVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}
