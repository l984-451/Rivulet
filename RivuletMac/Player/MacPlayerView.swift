// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import AppKit
import AVKit
import SwiftUI

/// The full-window player: the engine surface, captions and overlay controls that hide when the
/// pointer rests. Parity source: `IOSPlexPlayerScreen` and `IOSPlayerChrome`. Keys live in the
/// Playback menu (`MacPlaybackCommands`), so they show beside their items.
struct MacPlayerView: View {
    @ObservedObject var session: MacPlexPlayback
    @ObservedObject var player: AetherPlayer
    @ObservedObject var controller: MacPlaybackController

    @State private var captionStyle = CaptionAppearance.current()
    @State private var chromeVisible = true
    @State private var overControls = false
    /// The capsule its Hide button dismissed; it still shows with the controls.
    @State private var hiddenAction: String?
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubValue: Double?
    @State private var pointerLocation: CGPoint?
    @State private var bottomBarTop: CGFloat?
    @State private var containerHeight: CGFloat = 0
    @State private var isFullScreen = false
    @State private var showsChapters = false
    @State private var subtitleSearch: SubtitleSearchModel?
    @State private var showsPlaylist = false
    @AppStorage(SkipLengthKeys.back) private var skipBackSeconds = 10
    @AppStorage(SkipLengthKeys.forward) private var skipForwardSeconds = 30
    @AppStorage(AudioSync.key) private var audioDelayMs = 0
    @AppStorage(CaptionHeight.key) private var captionHeightUnits = 0

    private static let space = "mac-player"

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

            // Click plays or pauses, double-click toggles full screen, pinch fills the window.
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    TapGesture(count: 2).onEnded { controller.toggleFullScreen() }
                        .exclusively(before: TapGesture().onEnded { controller.togglePlayPause() })
                )
                .gesture(MagnifyGesture().onEnded { player.fillsScreen = $0.magnification > 1 })

            controls
                .opacity(chromeVisible ? 1 : 0)
                .allowsHitTesting(chromeVisible)

            if isBusy, !chromeVisible, failure == nil {
                ProgressView().controlSize(.large).colorScheme(.dark)
            }
            if failure == nil { contextualCapsule }
            if let failure { failureCard(failure) }
        }
        .coordinateSpace(name: Self.space)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { containerHeight = $0 }
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
            // Paused keeps the controls up, like the system player.
            if !playing { chromeVisible = true }
            scheduleHide()
        }
        .onChange(of: failure) { _, failure in if failure != nil { chromeVisible = true } }
        .onChange(of: contextualAction?.title) { _, title in
            if title == nil { hiddenAction = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: CaptionAppearance.changedNotification)) { _ in
            captionStyle = CaptionAppearance.current()
        }
        .sheet(item: $subtitleSearch) { model in
            MacSubtitleSearchPane(model: model)
        }
        .task(id: session.request.id) { await session.refreshSubtitleSearch() }
    }

    // MARK: - State

    private var isPlaying: Bool { player.state == .playing }

    private var isBusy: Bool {
        session.serverStopReason == nil && (player.state == .idle || player.state == .loading
            || player.isBuffering || (player.isStarting && player.state == .playing))
    }

    private var duration: Double { player.duration > 0 ? player.duration : session.request.item.durationSeconds }

    private var failure: MacPlayerFailure? {
        if let reason = session.serverStopReason {
            return MacPlayerFailure(message: reason, canRetry: false, title: String(localized: "Playback Stopped"),
                                    systemImage: "stop.circle.fill")
        }
        guard case .failed(let message) = player.state else { return nil }
        return MacPlayerFailure(message: message, canRetry: player.canRetry)
    }

    private var contextualAction: MacPlayerContextualAction? {
        let isEpisode = session.queue == nil
        let next = isEpisode ? String(localized: "Next Episode") : String(localized: "Next")
        if session.isPlayingCinemaExtra {
            return MacPlayerContextualAction(title: String(localized: "Skip"), systemImage: "forward.end.fill",
                                             action: session.advanceCinemaExtras)
        }
        if let countdown = session.upNextCountdown {
            return MacPlayerContextualAction(
                title: isEpisode ? String(localized: "Next Episode in \(countdown)") : String(localized: "Next in \(countdown)"),
                systemImage: "forward.end.fill", action: session.playNext, cancel: session.cancelUpNext)
        }
        if session.nextEpisode != nil, !session.upNextDismissed, session.isNearEnd {
            return MacPlayerContextualAction(title: next, systemImage: "forward.end.fill", action: session.playNext)
        }
        if let marker = session.activeMarker, MarkerSkipMode.current(for: marker.type ?? "") != .off {
            return MacPlayerContextualAction(
                title: String(localized: "Skip \(marker.displayName)"),
                systemImage: marker.isCommunity ? "person.3.fill" : nil,
                action: { session.skip(marker) })
        }
        return nil
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            bottomBar
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

    private var topBar: some View {
        let item = session.request.item
        return HStack(alignment: .center, spacing: 12) {
            iconButton("Close", systemImage: "xmark", action: controller.close)
            VStack(alignment: .leading, spacing: 1) {
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                Text(item.displayTitle).font(.headline).lineLimit(1)
            }
            Spacer(minLength: 0)
            MacRoutePicker().frame(width: 28, height: 28).help("AirPlay")
            if controller.isPictureInPicturePossible {
                iconButton("Picture in Picture", systemImage: "pip.enter", action: controller.startPictureInPicture)
            }
        }
        // Clear of the window's traffic lights while it is not full screen.
        .padding(.leading, isFullScreen ? 20 : 84)
        .padding(.trailing, 20)
        .padding(.top, isFullScreen ? 16 : 10)
        .onHover { overControls = $0; scheduleHide() }
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            if duration > 0 {
                MacPlayerScrubber(
                    range: 0...duration,
                    value: player.pendingSeekTarget ?? player.currentTime,
                    scrubValue: $scrubValue,
                    scrubStill: session.scrubStill,
                    onCommit: { time in
                        Task { await player.seek(to: time) }
                        scheduleHide()
                    },
                    onStep: { direction in controller.skip(forward: direction > 0) }
                )
                HStack {
                    let shown = scrubValue ?? player.pendingSeekTarget ?? player.currentTime
                    Text(Self.format(shown))
                    Spacer()
                    Text("-" + Self.format(max(0, duration - shown)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
            }
            ZStack {
                transport
                HStack {
                    volumeControls
                    Spacer(minLength: 12)
                    optionControls
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

    private var transport: some View {
        HStack(spacing: 18) {
            iconButton("Back \(skipBackSeconds) seconds", systemImage: Self.skipSymbol("gobackward", skipBackSeconds), size: 20) {
                controller.skip(forward: false)
            }
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
            iconButton("Forward \(skipForwardSeconds) seconds", systemImage: Self.skipSymbol("goforward", skipForwardSeconds), size: 20) {
                controller.skip(forward: true)
            }
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

    private var optionControls: some View {
        HStack(spacing: 6) {
            speedMenu
            if !session.request.isLocal { qualityMenu }
            if !session.audioTracks.isEmpty || !session.subtitleTracks.isEmpty { tracksMenu }
            if !session.chapters.isEmpty {
                iconButton("Chapters", systemImage: "list.bullet.rectangle") { showsChapters.toggle() }
                    .popover(isPresented: $showsChapters, arrowEdge: .top) {
                        MacPlayerChaptersPane(session: session, currentTime: player.currentTime) { showsChapters = false }
                    }
            }
            if session.queue != nil {
                iconButton("Playlist", systemImage: "list.bullet") { showsPlaylist.toggle() }
                    .popover(isPresented: $showsPlaylist, arrowEdge: .top) {
                        if let queue = session.queue {
                            MacPlayerPlaylistPane(session: session, queue: queue) { index in
                                showsPlaylist = false
                                session.playEntry(at: index)
                            }
                        }
                    }
            }
            iconButton(isFullScreen ? "Exit Full Screen" : "Full Screen",
                       systemImage: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       action: controller.toggleFullScreen)
        }
    }

    private var speedMenu: some View {
        Menu {
            Picker("Playback Speed", selection: Binding(get: { player.rate }, set: { player.setRate($0) })) {
                ForEach(MacPlayerSpeeds.all, id: \.self) { Text(MacPlayerSpeeds.label($0)).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Text(MacPlayerSpeeds.label(player.rate)).font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playback Speed")
    }

    private var qualityMenu: some View {
        Menu {
            Picker("Quality", selection: Binding(get: { session.request.quality }, set: { session.switchQuality($0) })) {
                ForEach(StreamingQuality.allChoices, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Text(session.qualityLabel).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Quality")
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
            if session.subtitleSearchAvailable {
                Button("Search for Subtitles") { subtitleSearch = session.makeSubtitleSearch() }
            }
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

    // MARK: - Overlays

    @ViewBuilder
    private var contextualCapsule: some View {
        if let item = contextualAction, chromeVisible || hiddenAction != item.title {
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Spacer()
                    if let cancel = item.cancel {
                        Button(action: cancel) {
                            Image(systemName: "xmark").frame(width: 22, height: 22)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel("Cancel")
                    } else if !chromeVisible {
                        Button { hiddenAction = item.title } label: {
                            Image(systemName: "xmark").frame(width: 22, height: 22)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel("Hide")
                    }
                    Button(action: item.action) {
                        HStack(spacing: 8) {
                            Text(item.title)
                            if let symbol = item.systemImage { Image(systemName: symbol) }
                        }
                        .font(.headline)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 28)
                    }
                    .buttonStyle(.glass)
                }
                .padding(.trailing, 24)
                .padding(.bottom, chromeVisible ? max(28, containerHeight - (bottomBarTop ?? containerHeight) + 12) : 28)
            }
            .transition(.opacity)
        }
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

    /// A moving pointer brings the controls up and keeps them up. Movement only: a hover phase
    /// can arrive again for a pointer that has not moved when the views under it change.
    private func pointerMoved(to location: CGPoint) {
        defer { pointerLocation = location }
        guard let last = pointerLocation else { return }
        guard abs(location.x - last.x) > 2 || abs(location.y - last.y) > 2 else { return }
        if !chromeVisible { chromeVisible = true }
        scheduleHide()
    }

    /// Hides after 3 s while playing; paused, failed, scrubbing, a popover or a pointer over
    /// the controls keep them up. The cursor goes with them until it moves.
    private func scheduleHide() {
        hideTask?.cancel()
        guard chromeVisible, isPlaying, failure == nil, !overControls, !showsChapters, !showsPlaylist, subtitleSearch == nil else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, scrubValue == nil else { return }
            chromeVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    /// gobackward.N exists for these values; anything else gets the plain glyph.
    private static func skipSymbol(_ base: String, _ seconds: Int) -> String {
        [5, 10, 15, 30, 45, 60, 75, 90].contains(seconds) ? "\(base).\(seconds)" : base
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Pieces

struct MacBottomBarTopKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}

/// The capsule above the bottom bar (Skip Intro, Next Episode).
private struct MacPlayerContextualAction {
    let title: String
    var systemImage: String?
    let action: () -> Void
    /// Shows a cancel button beside the capsule (the Up Next countdown).
    var cancel: (() -> Void)?
}

struct MacPlayerFailure: Equatable {
    let message: String
    let canRetry: Bool
    var title = String(localized: "Couldn't Play")
    var systemImage = "exclamationmark.triangle.fill"
}

/// A borderless glyph button that lights up under the pointer.
struct MacPlayerIconButton: View {
    let label: LocalizedStringKey
    let systemImage: String
    let size: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size + 14, height: size + 14)
                .background(.white.opacity(hovering ? 0.18 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .help(Text(label))
    }
}

/// The engine surface, re-parented into whichever view is showing it.
struct MacPlayerSurface: NSViewRepresentable {
    let surface: NSView?

    final class Container: NSView {
        override func layout() {
            super.layout()
            subviews.forEach { $0.frame = bounds }
        }
    }

    func makeNSView(context: Context) -> Container {
        let container = Container()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        return container
    }

    func updateNSView(_ container: Container, context: Context) {
        guard let surface, surface.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        container.addSubview(surface)
        container.needsLayout = true
    }
}

/// The system AirPlay button.
struct MacRoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        return picker
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {}
}

/// Reads the hosting window: tracks full screen, and hides the toolbar while the player covers it.
struct MacWindowReader: NSViewRepresentable {
    @Binding var isFullScreen: Bool
    var onEscape: () -> Void = {}

    final class Coordinator {
        weak var window: NSWindow?
        var tokens: [NSObjectProtocol] = []
        var keyMonitor: Any?
        var onEscape: () -> Void = {}

        func attach(_ window: NSWindow?, update: @escaping (Bool) -> Void) {
            guard self.window !== window else { return }
            detach()
            self.window = window
            guard let window else { return }
            window.toolbar?.isVisible = false
            // The sidebar list would otherwise own bare keys (Space, letters) under the player.
            DispatchQueue.main.async { window.makeFirstResponder(nil) }
            update(window.styleMask.contains(.fullScreen))
            let center = NotificationCenter.default
            // The Playback menu's Escape shortcut is not reached when a list owns the key; catch it here.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
                guard event.keyCode == 53, event.window === window, window?.attachedSheet == nil else { return event }
                self?.onEscape()
                return nil
            }
            tokens = [
                center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { _ in update(true) },
                center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in update(false) }
            ]
        }

        func detach() {
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            window?.toolbar?.isVisible = true
            window = nil
        }
    }

    final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        let binding = $isFullScreen
        context.coordinator.onEscape = onEscape
        view.onWindow = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(window) { value in Task { @MainActor in binding.wrappedValue = value } }
        }
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) { context.coordinator.onEscape = onEscape }

    static func dismantleNSView(_ view: ReaderView, coordinator: Coordinator) {
        view.onWindow = nil
        coordinator.detach()
    }
}

/// The playlist around the playing entry: 5 before it and 30 after, as on tvOS.
private struct MacPlayerPlaylistPane: View {
    let session: MacPlexPlayback
    let queue: PlayQueue<PlexMetadata>
    let onPick: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(window), id: \.self) { index in
                        let item = queue.entries[index]
                        Button { onPick(index) } label: {
                            HStack(spacing: 12) {
                                MacImage(url: session.queueArtworkURL(item, width: 96))
                                    .frame(width: 96, height: 54)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.displayTitle).font(.headline).lineLimit(2)
                                    if let subtitle = item.subtitle {
                                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                                if index == queue.index {
                                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                                        .accessibilityLabel("Now Playing")
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(index == queue.index)
                        .id(index)
                    }
                }
            }
            .onAppear { proxy.scrollTo(queue.index, anchor: .top) }
        }
        .frame(width: 380, height: 420)
    }

    private var window: Range<Int> {
        max(0, queue.index - 5)..<min(queue.entries.count, queue.index + 31)
    }
}

/// The title's chapters, opened on the one playing: the server's image, else a frame from the file.
private struct MacPlayerChaptersPane: View {
    let session: MacPlexPlayback
    let currentTime: TimeInterval
    let dismiss: () -> Void

    var body: some View {
        let chapters = session.chapters
        let current = chapters.lastIndex { TimeInterval($0.startTimeOffset ?? 0) / 1000 <= currentTime }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                        Button {
                            session.seekToChapter(chapter)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                MacChapterThumbnail(session: session, chapter: chapter)
                                    .frame(width: 96, height: 54)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(chapter.tag ?? String(localized: "Chapter \(index + 1)")).font(.headline).lineLimit(2)
                                    Text(Self.time(chapter.startTimeOffset ?? 0))
                                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if index == current {
                                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                                        .accessibilityLabel("Now Playing")
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
            }
            .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
        }
        .frame(width: 380, height: 420)
    }

    private static func time(_ ms: Int) -> String {
        Duration.milliseconds(ms).formatted(.time(pattern: ms >= 3_600_000 ? .hourMinuteSecond : .minuteSecond))
    }
}

private struct MacChapterThumbnail: View {
    let session: MacPlexPlayback
    let chapter: PlexChapter
    @State private var still: NSImage?

    var body: some View {
        if let url = session.chapterImageURL(chapter, width: 192) {
            MacImage(url: url)
        } else {
            Rectangle()
                .fill(.quaternary)
                .overlay { if let still { Image(nsImage: still).resizable().scaledToFill() } }
                .clipped()
                .task { still = await session.chapterStill(at: TimeInterval(chapter.startTimeOffset ?? 0) / 1000) }
        }
    }
}
