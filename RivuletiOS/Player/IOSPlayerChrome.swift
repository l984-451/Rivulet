// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AVKit
import SwiftUI
import UIKit

/// What the scrubber spans.
enum IOSPlayerTimeline: Equatable {
    /// Media time in seconds.
    case vod(position: Double, duration: Double)
    /// The live rewind window on the player's session axis. `range` is nil
    /// when the source has no DVR window; the programme then draws a
    /// non-interactive progress bar.
    case live(range: ClosedRange<Double>?, position: Double, edge: Double, isAtEdge: Bool, programme: ClosedRange<Date>?)
}

/// The capsule at the bottom trailing edge (Skip Intro, Next Episode).
struct IOSPlayerContextualAction {
    let title: String
    var systemImage: String?
    let action: () -> Void
    /// Shows a cancel button beside the capsule (the Up Next countdown).
    var cancel: (() -> Void)?
}

struct IOSPlayerFailure: Equatable {
    let message: String
    let canRetry: Bool
}

/// Everything the chrome can ask its host to do. Plain closures, so Plex VOD
/// and Live TV drive the same controls.
struct IOSPlayerChromeActions {
    var close: () -> Void
    var playPause: () -> Void
    var skip: (Double) -> Void
    /// VOD: media seconds. Live: the session axis `IOSPlayerTimeline.live` uses.
    var seek: (Double) -> Void
    var goLive: () -> Void = {}
    var setRate: (Float) -> Void = { _ in }
    var selectQuality: (StreamingQuality) -> Void = { _ in }
    var selectAudio: (Int) -> Void = { _ in }
    var selectSubtitle: (Int?) -> Void = { _ in }
    var pictureInPicture: () -> Void = {}
    var toggleMute: () -> Void = {}
    var setFillsScreen: (Bool) -> Void = { _ in }
    var retry: () -> Void = {}
    /// Swipe down: into PiP when that is possible, otherwise close.
    var swipeDown: (() -> Void)?
}

/// The quality menu: the choices, the session's pick, and what is playing.
struct IOSPlayerQuality {
    let choices: [StreamingQuality]
    let selected: StreamingQuality
    let label: String
}

/// Touch chrome modelled on the iOS 26 system player: close and PiP top
/// leading, AirPlay and mute top trailing, transport in the centre, title,
/// scrubber and menus along the bottom. Always dark.
struct IOSPlayerChrome<Video: View, Trailing: View>: View {
    private let title: String
    private let subtitle: String?
    private let isPlaying: Bool
    private let isBusy: Bool
    private let timeline: IOSPlayerTimeline
    private let rate: Float?
    private let quality: IOSPlayerQuality?
    private let audioTracks: [AetherPlayer.Track]
    private let selectedAudioID: Int?
    private let subtitleTracks: [AetherPlayer.Track]
    private let selectedSubtitleID: Int?
    private let contextualAction: IOSPlayerContextualAction?
    private let failure: IOSPlayerFailure?
    private let isMuted: Bool
    private let canPictureInPicture: Bool
    private let actions: IOSPlayerChromeActions
    private let video: (CGFloat?) -> Video
    private let trailing: () -> Trailing

    @AppStorage("playerSkipBackwardSeconds") private var skipBackwardSeconds = 10
    @AppStorage("playerSkipForwardSeconds") private var skipForwardSeconds = 30
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubValue: Double?
    @State private var ripple: Ripple?
    @State private var bottomBarTop: CGFloat?

    /// - Parameters:
    ///   - rate: nil hides the speed menu (live).
    ///   - quality: nil hides the quality menu (live).
    ///   - video: the picture and captions; receives the bottom bar's top edge
    ///     while the chrome is up, so captions can lift above it.
    ///   - trailing: host buttons for the bottom row (Live TV: Channels).
    init(
        title: String,
        subtitle: String? = nil,
        isPlaying: Bool,
        isBusy: Bool,
        timeline: IOSPlayerTimeline,
        rate: Float? = nil,
        quality: IOSPlayerQuality? = nil,
        audioTracks: [AetherPlayer.Track] = [],
        selectedAudioID: Int? = nil,
        subtitleTracks: [AetherPlayer.Track] = [],
        selectedSubtitleID: Int? = nil,
        contextualAction: IOSPlayerContextualAction? = nil,
        failure: IOSPlayerFailure? = nil,
        isMuted: Bool = false,
        canPictureInPicture: Bool = false,
        actions: IOSPlayerChromeActions,
        @ViewBuilder video: @escaping (CGFloat?) -> Video,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.isPlaying = isPlaying
        self.isBusy = isBusy
        self.timeline = timeline
        self.rate = rate
        self.quality = quality
        self.audioTracks = audioTracks
        self.selectedAudioID = selectedAudioID
        self.subtitleTracks = subtitleTracks
        self.selectedSubtitleID = selectedSubtitleID
        self.contextualAction = contextualAction
        self.failure = failure
        self.isMuted = isMuted
        self.canPictureInPicture = canPictureInPicture
        self.actions = actions
        self.video = video
        self.trailing = trailing
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            video(chromeVisible ? bottomBarTop : nil)
                .ignoresSafeArea()

            IOSPlayerGestureSurface(
                onTap: toggleChrome,
                onDoubleTap: { leading in skipFromGesture(leading: leading) },
                onPinch: { fill in actions.setFillsScreen(fill) },
                onSwipeDown: { (actions.swipeDown ?? actions.close)() }
            )
            .ignoresSafeArea()

            if let ripple { rippleView(ripple) }

            controls
                .opacity(chromeVisible ? 1 : 0)
                .allowsHitTesting(chromeVisible)

            if isBusy, !chromeVisible, failure == nil {
                ProgressView().controlSize(.large)
            }

            if let contextualAction, failure == nil {
                contextualCapsule(contextualAction)
            }

            if let failure { failureCard(failure) }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(BottomBarTopKey.self) { bottomBarTop = $0 }
        .foregroundStyle(.white)
        .tint(.white)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .statusBarHidden(!chromeVisible)
        .persistentSystemOverlays(chromeVisible ? .automatic : .hidden)
        .animation(.easeInOut(duration: 0.25), value: chromeVisible)
        .onAppear(perform: scheduleHide)
        .onDisappear { hideTask?.cancel() }
        .onChange(of: isPlaying) { _, playing in
            // Paused keeps the controls up, like the system player.
            if !playing { chromeVisible = true }
            scheduleHide()
        }
        .onChange(of: failure) { _, failure in
            if failure != nil { chromeVisible = true }
        }
    }

    // MARK: - Layout

    private static var space: String { "ios-player-chrome" }

    private var controls: some View {
        ZStack {
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomBar
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: BottomBarTopKey.self,
                                value: proxy.frame(in: .named(Self.space)).minY
                            )
                        }
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            transport
        }
        .background {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.55), location: 0),
                    .init(color: .clear, location: 0.22),
                    .init(color: .clear, location: 0.6),
                    .init(color: .black.opacity(0.7), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    glassButton("Close", systemImage: "xmark", action: actions.close)
                        .keyboardShortcut(.cancelAction)
                    if canPictureInPicture {
                        glassButton("Picture in Picture", systemImage: "pip.enter", action: actions.pictureInPicture)
                    }
                }
            }
            Spacer()
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    IOSRoutePicker()
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .accessibilityLabel("AirPlay")
                    glassButton(
                        isMuted ? "Unmute" : "Mute",
                        systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                        action: actions.toggleMute
                    )
                }
            }
        }
    }

    /// Live without a rewind window has nothing to skip through.
    private var canSkip: Bool {
        if case .live(nil, _, _, _, _) = timeline { return false }
        return true
    }

    private var transport: some View {
        HStack(spacing: 36) {
            if canSkip { skipButton(forward: false) }

            Button { interact(actions.playPause) } label: {
                Group {
                    if isBusy {
                        ProgressView().controlSize(.large)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 38, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 72, height: 72)
            }
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            if canSkip { skipButton(forward: true) }
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }

    private func skipButton(forward: Bool) -> some View {
        let seconds = forward ? skipForwardSeconds : skipBackwardSeconds
        return Button { interact { actions.skip(forward ? Double(seconds) : -Double(seconds)) } } label: {
            Image(systemName: Self.skipSymbol(forward ? "goforward" : "gobackward", seconds: seconds))
                .font(.system(size: 26, weight: .medium))
                .frame(width: 52, height: 52)
        }
        .keyboardShortcut(forward ? .rightArrow : .leftArrow, modifiers: [])
        .accessibilityLabel(forward ? "Forward \(seconds) seconds" : "Back \(seconds) seconds")
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    Text(title)
                        .font(.headline)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                liveBadge
            }

            scrubber

            HStack(spacing: 10) {
                if let rate { speedMenu(rate) }
                if let quality { qualityMenu(quality) }
                if !audioTracks.isEmpty || !subtitleTracks.isEmpty { tracksMenu }
                trailing()
                Spacer(minLength: 0)
            }
            .frame(height: 44)
        }
    }

    @ViewBuilder
    private var liveBadge: some View {
        if case .live(let range, _, _, let isAtEdge, _) = timeline {
            if isAtEdge || range == nil {
                Text("LIVE")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.red, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Button("Go Live") { interact(actions.goLive) }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.glass)
            }
        }
    }

    @ViewBuilder
    private var scrubber: some View {
        switch timeline {
        case .vod(let position, let duration):
            if duration > 0 {
                let shown = scrubValue ?? position
                IOSPlayerScrubber(
                    range: 0...duration,
                    value: position,
                    scrubValue: $scrubValue,
                    leadingLabel: Self.format(shown),
                    trailingLabel: "-" + Self.format(max(0, duration - shown)),
                    accessibilityValue: "\(Self.format(shown)) of \(Self.format(duration))",
                    onCommit: commitScrub,
                    onStep: stepFromAccessibility
                )
            }
        case .live(let range, let position, let edge, _, let programme):
            if let range, edge > range.lowerBound {
                let shown = scrubValue ?? position
                let behind = max(0, edge - shown)
                IOSPlayerScrubber(
                    range: range.lowerBound...edge,
                    value: position,
                    scrubValue: $scrubValue,
                    leadingLabel: behind >= 1 ? "-" + Self.format(behind) : "",
                    trailingLabel: programme.map { $0.upperBound.formatted(date: .omitted, time: .shortened) } ?? "",
                    accessibilityValue: behind >= 1 ? "\(Self.format(behind)) behind live" : "Live",
                    onCommit: commitScrub,
                    onStep: stepFromAccessibility
                )
            } else if let programme {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let span = programme.upperBound.timeIntervalSince(programme.lowerBound)
                    IOSPlayerScrubber(
                        range: 0...max(1, span),
                        value: min(max(context.date.timeIntervalSince(programme.lowerBound), 0), span),
                        scrubValue: .constant(nil),
                        leadingLabel: programme.lowerBound.formatted(date: .omitted, time: .shortened),
                        trailingLabel: programme.upperBound.formatted(date: .omitted, time: .shortened),
                        accessibilityValue: "Programme progress",
                        isInteractive: false,
                        onCommit: { _ in },
                        onStep: { _ in }
                    )
                }
            }
        }
    }

    private func speedMenu(_ rate: Float) -> some View {
        Menu {
            Picker("Playback Speed", selection: Binding(get: { rate }, set: { value in interact { actions.setRate(value) } })) {
                ForEach(Self.speeds, id: \.self) { speed in
                    Text(Self.speedLabel(speed)).tag(speed)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(Self.speedLabel(rate))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .frame(minWidth: 44, minHeight: 44)
                .padding(.horizontal, 6)
        }
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel("Playback speed")
    }

    private func qualityMenu(_ quality: IOSPlayerQuality) -> some View {
        Menu {
            Picker("Quality", selection: Binding(
                get: { quality.selected },
                set: { value in interact { actions.selectQuality(value) } }
            )) {
                ForEach(quality.choices, id: \.self) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(quality.label)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(minHeight: 44)
                .padding(.horizontal, 12)
        }
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel("Quality")
        .accessibilityValue(quality.label)
    }

    private var tracksMenu: some View {
        Menu {
            if !audioTracks.isEmpty {
                Picker("Audio", selection: Binding(
                    get: { selectedAudioID },
                    set: { id in if let id { interact { actions.selectAudio(id) } } }
                )) {
                    ForEach(audioTracks) { track in
                        trackLabel(track).tag(Optional(track.id))
                    }
                }
                .pickerStyle(.inline)
            }
            Picker("Subtitles", selection: Binding(
                get: { selectedSubtitleID },
                set: { id in interact { actions.selectSubtitle(id) } }
            )) {
                Text("Off").tag(Int?.none)
                ForEach(subtitleTracks) { track in
                    trackLabel(track).tag(Optional(track.id))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: selectedSubtitleID == nil ? "captions.bubble" : "captions.bubble.fill")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Audio and Subtitles")
    }

    @ViewBuilder
    private func trackLabel(_ track: AetherPlayer.Track) -> some View {
        let detail = track.detail
        if detail.isEmpty || detail == track.name {
            Text(track.name)
        } else {
            VStack(alignment: .leading) {
                Text(track.name)
                Text(detail)
            }
        }
    }

    private func contextualCapsule(_ item: IOSPlayerContextualAction) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                Spacer()
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        if let cancel = item.cancel {
                            glassButton("Cancel", systemImage: "xmark", action: cancel)
                        }
                        Button {
                            interact(item.action)
                        } label: {
                            HStack(spacing: 8) {
                                Text(item.title)
                                if let symbol = item.systemImage { Image(systemName: symbol) }
                            }
                            .font(.headline)
                            .padding(.horizontal, 8)
                            .frame(minHeight: 36)
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .transition(.opacity)
    }

    private func failureCard(_ failure: IOSPlayerFailure) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(.yellow)
            Text("Couldn't Play")
                .font(.headline)
            Text(failure.message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Close", action: actions.close)
                    .buttonStyle(.glass)
                if failure.canRetry {
                    Button("Retry", action: actions.retry)
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 380)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding()
    }

    private func rippleView(_ ripple: Ripple) -> some View {
        HStack {
            if !ripple.leading { Spacer() }
            VStack(spacing: 6) {
                Image(systemName: ripple.leading ? "gobackward" : "goforward")
                    .font(.title2.weight(.semibold))
                Text("\(ripple.seconds) seconds")
                    .font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 48)
            if ripple.leading { Spacer() }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
        .id(ripple.id)
    }

    private func glassButton(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button { interact(action) } label: {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }

    // MARK: - Behaviour

    private func interact(_ action: () -> Void) {
        action()
        scheduleHide()
    }

    private func toggleChrome() {
        chromeVisible.toggle()
        scheduleHide()
    }

    /// Hides after 3 s while playing; paused, failed, scrubbing or VoiceOver
    /// keep the controls up.
    private func scheduleHide() {
        hideTask?.cancel()
        guard chromeVisible, isPlaying, failure == nil, !voiceOverEnabled else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, scrubValue == nil else { return }
            chromeVisible = false
        }
    }

    private func commitScrub(_ value: Double) {
        actions.seek(value)
        scheduleHide()
    }

    private func stepFromAccessibility(_ direction: Double) {
        actions.skip(direction > 0 ? Double(skipForwardSeconds) : -Double(skipBackwardSeconds))
    }

    private func skipFromGesture(leading: Bool) {
        guard canSkip else { return }
        let seconds = leading ? skipBackwardSeconds : skipForwardSeconds
        actions.skip(leading ? -Double(seconds) : Double(seconds))
        let total = (ripple?.leading == leading ? ripple?.seconds ?? 0 : 0) + seconds
        let next = Ripple(leading: leading, seconds: total)
        withAnimation(.easeOut(duration: 0.15)) { ripple = next }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.8))
            if ripple?.id == next.id { withAnimation(.easeIn(duration: 0.25)) { ripple = nil } }
        }
    }

    private struct Ripple {
        let leading: Bool
        let seconds: Int
        let id = UUID()
    }

    private static var speeds: [Float] { [0.5, 0.75, 1, 1.25, 1.5, 2] }

    private static func speedLabel(_ rate: Float) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "x"
    }

    /// gobackward.N exists for these values; anything else gets the plain glyph.
    private static func skipSymbol(_ base: String, seconds: Int) -> String {
        [5, 10, 15, 30, 45, 60, 75, 90].contains(seconds) ? "\(base).\(seconds)" : base
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension IOSPlayerChrome where Trailing == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        isPlaying: Bool,
        isBusy: Bool,
        timeline: IOSPlayerTimeline,
        rate: Float? = nil,
        quality: IOSPlayerQuality? = nil,
        audioTracks: [AetherPlayer.Track] = [],
        selectedAudioID: Int? = nil,
        subtitleTracks: [AetherPlayer.Track] = [],
        selectedSubtitleID: Int? = nil,
        contextualAction: IOSPlayerContextualAction? = nil,
        failure: IOSPlayerFailure? = nil,
        isMuted: Bool = false,
        canPictureInPicture: Bool = false,
        actions: IOSPlayerChromeActions,
        @ViewBuilder video: @escaping (CGFloat?) -> Video
    ) {
        self.init(
            title: title, subtitle: subtitle, isPlaying: isPlaying, isBusy: isBusy, timeline: timeline,
            rate: rate, quality: quality, audioTracks: audioTracks, selectedAudioID: selectedAudioID,
            subtitleTracks: subtitleTracks, selectedSubtitleID: selectedSubtitleID,
            contextualAction: contextualAction, failure: failure, isMuted: isMuted,
            canPictureInPicture: canPictureInPicture, actions: actions,
            video: video, trailing: { EmptyView() }
        )
    }
}

private struct BottomBarTopKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

/// The system player's bar: no knob, thickens while dragging, and the time
/// labels follow the finger. Seeks on release.
private struct IOSPlayerScrubber: View {
    let range: ClosedRange<Double>
    let value: Double
    @Binding var scrubValue: Double?
    let leadingLabel: String
    let trailingLabel: String
    let accessibilityValue: String
    var isInteractive = true
    let onCommit: (Double) -> Void
    let onStep: (Double) -> Void

    private var span: Double { max(range.upperBound - range.lowerBound, 0.001) }

    private var fraction: Double {
        let shown = scrubValue ?? value
        return min(max((shown - range.lowerBound) / span, 0), 1)
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.28))
                    Capsule().fill(.white).frame(width: geometry.size.width * fraction)
                }
                .frame(height: scrubValue == nil ? 6 : 12)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard isInteractive, geometry.size.width > 0 else { return }
                            let f = min(max(drag.location.x / geometry.size.width, 0), 1)
                            scrubValue = range.lowerBound + span * f
                        }
                        .onEnded { _ in
                            guard let target = scrubValue else { return }
                            onCommit(target)
                            scrubValue = nil
                        }
                )
            }
            .frame(height: 24)
            .animation(.easeOut(duration: 0.15), value: scrubValue == nil)

            HStack {
                Text(leadingLabel)
                Spacer()
                Text(trailingLabel)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
        }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            guard isInteractive else { return }
            switch direction {
            case .increment: onStep(1)
            case .decrement: onStep(-1)
            @unknown default: break
            }
        }
    }
}

/// UIKit recognizers for what SwiftUI arbitrates poorly: single vs double tap
/// with the touch location, pinch, and a vertical swipe that must not steal
/// horizontal pans. Controls sit above this surface.
private struct IOSPlayerGestureSurface: UIViewRepresentable {
    let onTap: () -> Void
    let onDoubleTap: (_ leading: Bool) -> Void
    let onPinch: (_ fill: Bool) -> Void
    let onSwipeDown: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let coordinator = context.coordinator
        let single = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tap))
        let double = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)
        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.pinch(_:)))
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.pan(_:)))
        pan.delegate = coordinator
        [single, double, pinch, pan].forEach(view.addGestureRecognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.surface = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var surface: IOSPlayerGestureSurface?

        @objc func tap() { surface?.onTap() }

        @objc func doubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            surface?.onDoubleTap(recognizer.location(in: view).x < view.bounds.midX)
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            if recognizer.scale > 1.05 { surface?.onPinch(true) }
            if recognizer.scale < 0.95 { surface?.onPinch(false) }
        }

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view).y
            let velocity = recognizer.velocity(in: view).y
            if translation > 80 || velocity > 900 { surface?.onSwipeDown() }
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else { return true }
            let velocity = pan.velocity(in: view)
            return velocity.y > abs(velocity.x)
        }
    }
}

/// The system AirPlay button.
private struct IOSRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = true
        picker.tintColor = .white
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
