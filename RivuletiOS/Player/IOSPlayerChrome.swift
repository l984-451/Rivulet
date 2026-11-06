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

/// Live only: the bar reaching back over a rewind window. `bar` is the span
/// on the session axis (earlier programmes the window reaches into, through
/// the end of the one on air), `sections` the programme boundaries inside it,
/// on the same axis. The scrub stays inside the timeline's seekable range.
struct IOSLiveScrub {
    let bar: ClosedRange<Double>
    let sections: [Double]
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
    var title = String(localized: "Couldn't Play")
    var systemImage = "exclamationmark.triangle.fill"
}

/// Everything the chrome can ask its host to do. Plain closures, so Plex VOD
/// and Live TV drive the same controls.
struct IOSPlayerChromeActions {
    var close: () -> Void
    var playPause: () -> Void
    var skip: (Double) -> Void
    /// VOD: media seconds. Live: the session axis `IOSPlayerTimeline.live` uses.
    var seek: (Double) -> Void
    /// The still for a scrub position; nil hides the preview (live).
    var scrubStill: ((Double) async -> UIImage?)?
    var goLive: () -> Void = {}
    var setRate: (Float) -> Void = { _ in }
    var selectQuality: (StreamingQuality) -> Void = { _ in }
    var selectAudio: (Int) -> Void = { _ in }
    var selectSubtitle: (Int?) -> Void = { _ in }
    /// Steps the audio delay by `AudioSync.stepMs` units; nil hides it.
    var stepAudioDelay: ((Int) -> Void)?
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
/// scrubber and menus along the bottom. Always dark. A hardware keyboard gets
/// Space, Left, Right and Escape; a pointer brings the controls up by moving
/// and is hidden over the picture while they are down.
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
    private let liveScrub: IOSLiveScrub?
    private let video: (CGFloat?) -> Video
    private let trailing: () -> Trailing

    @AppStorage(SkipLengthKeys.back) private var skipBackwardSeconds = 10
    @AppStorage(SkipLengthKeys.forward) private var skipForwardSeconds = 30
    @AppStorage(AudioSync.key) private var audioDelayMs = 0
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubValue: Double?
    @State private var ripple: Ripple?
    @State private var bottomBarTop: CGFloat?
    @State private var topBarBottom: CGFloat?
    @State private var transportSize: CGSize = .zero
    @State private var pointerLocation: CGPoint?

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
        liveScrub: IOSLiveScrub? = nil,
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
        self.liveScrub = liveScrub
        self.video = video
        self.trailing = trailing
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            video(chromeVisible ? bottomBarTop : nil)
                .ignoresSafeArea()

            IOSPlayerInputSurface(
                chromeVisible: chromeVisible,
                canSkip: canSkip,
                onTap: toggleChrome,
                onDoubleTap: { leading in skipFromGesture(leading: leading) },
                onPinch: { fill in actions.setFillsScreen(fill) },
                onSwipeDown: { (actions.swipeDown ?? actions.close)() },
                onKey: handleKey
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
        .onPreferenceChange(TopBarBottomKey.self) { topBarBottom = $0 }
        .onContinuousHover { phase in
            if case .active(let location) = phase { pointerMoved(to: location) }
        }
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
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: TopBarBottomKey.self,
                                value: proxy.frame(in: .named(Self.space)).maxY
                            )
                        }
                    }
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

            GeometryReader { proxy in
                transport
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { transportSize = $0 }
                    .offset(transportOffset(proxy))
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
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
                        .contentShape(.hoverEffect, .circle)
                        .hoverEffect()
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

    /// The centred transport, clear of the fold and, in a window too short to
    /// hold all three bands (Stage Manager, a small Mac window), clear of the
    /// bars: it lifts off the bottom bar and never rises into the top one.
    private func transportOffset(_ proxy: GeometryProxy) -> CGSize {
        var offset = foldOffset(proxy)
        let half = transportSize.height / 2
        var centre = proxy.size.height / 2 + offset.height
        if let bottomBarTop { centre = min(centre, bottomBarTop - Self.bandClearance - half) }
        if let topBarBottom { centre = max(centre, topBarBottom + Self.bandClearance + half) }
        offset.height = centre - proxy.size.height / 2
        return offset
    }

    private static var bandClearance: CGFloat { 12 }

    /// Moves the centred transport just clear of iPhone Duo's fold while partly
    /// folded: trailing for a book fold, below for a laptop fold. Zero otherwise.
    private func foldOffset(_ proxy: GeometryProxy) -> CGSize {
        guard let fold = proxy.duoFold() else { return .zero }
        return fold.height > fold.width
            ? CGSize(width: max(0, fold.maxX + transportSize.width / 2 - proxy.size.width / 2), height: 0)
            : CGSize(width: 0, height: max(0, fold.maxY + transportSize.height / 2 - proxy.size.height / 2))
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
                    accessibilityValue: String(localized: "\(Self.format(shown)) of \(Self.format(duration))"),
                    scrubStill: actions.scrubStill,
                    onCommit: commitScrub,
                    onStep: stepFromAccessibility
                )
            }
        case .live(let range, let position, let edge, _, let programme):
            if let range, edge > range.lowerBound {
                let shown = scrubValue ?? position
                let behind = max(0, edge - shown)
                IOSPlayerScrubber(
                    range: liveScrub?.bar ?? range.lowerBound...edge,
                    value: position,
                    scrubValue: $scrubValue,
                    leadingLabel: behind >= 1 ? "-" + Self.format(behind) : "",
                    trailingLabel: programme.map { $0.upperBound.formatted(date: .omitted, time: .shortened) } ?? "",
                    accessibilityValue: behind >= 1 ? String(localized: "\(Self.format(behind)) behind live") : String(localized: "Live"),
                    seekable: liveScrub == nil ? nil : range.lowerBound...edge,
                    sections: liveScrub?.sections ?? [],
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
                        accessibilityValue: String(localized: "Programme progress"),
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
                if let step = actions.stepAudioDelay { audioDelayControls(step) }
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

    /// − / value / + kept open while tapping, so the delay can be tuned by ear.
    private func audioDelayControls(_ step: @escaping (Int) -> Void) -> some View {
        Section("Audio Delay") {
            ControlGroup {
                Button { interact { step(-1) } } label: { Label("Earlier", systemImage: "minus") }
                Button { interact { step(-audioDelayMs / AudioSync.stepMs) } } label: {
                    Text(AudioSync.formatted(audioDelayMs))
                }
                .disabled(audioDelayMs == 0)
                .accessibilityLabel("Reset audio delay")
                Button { interact { step(1) } } label: { Label("Later", systemImage: "plus") }
            }
            .menuActionDismissBehavior(.disabled)
        }
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
            Image(systemName: failure.systemImage)
                .font(.title)
                .foregroundStyle(.yellow)
            Text(failure.title)
                .font(.headline)
            Text(failure.message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Close", action: actions.close)
                    .buttonStyle(.glass)
                if failure.canRetry {
                    // The chrome's white tint fills this button, so the label goes dark.
                    Button(action: actions.retry) { Text("Retry").foregroundStyle(.black) }
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

    private func glassButton(_ label: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
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

    /// A moving pointer brings the controls up and keeps them up (Mac, iPad
    /// trackpad). Movement only: a hover phase can arrive again for a pointer
    /// that has not moved when the views under it change, as they do when the
    /// chrome hides, and that must not bring it straight back.
    private func pointerMoved(to location: CGPoint) {
        defer { pointerLocation = location }
        guard let last = pointerLocation else { return }
        guard abs(location.x - last.x) > 2 || abs(location.y - last.y) > 2 else { return }
        if !chromeVisible { chromeVisible = true }
        scheduleHide()
    }

    /// One action per key press. Skips show the double-tap ripple, so a keyboard
    /// user sees the jump with the controls down.
    private func handleKey(_ key: IOSPlayerInputSurface.Key) {
        switch key {
        case .playPause: interact(actions.playPause)
        case .skipBackward: skipFromGesture(leading: true)
        case .skipForward: skipFromGesture(leading: false)
        case .close: actions.close()
        }
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

private struct TopBarBottomKey: PreferenceKey {
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
    var scrubStill: ((Double) async -> UIImage?)?
    /// Live with a rewind window: what can be reached inside the bar. The
    /// reachable part is filled the way a buffered range is, the fill runs from
    /// its start, and a drag stays inside it. nil draws the plain bar.
    var seekable: ClosedRange<Double>? = nil
    /// Programme boundaries on the bar's axis: they cut it into sections.
    var sections: [Double] = []
    let onCommit: (Double) -> Void
    let onStep: (Double) -> Void
    @State private var still: UIImage?
    @State private var stillTime: Double?
    @State private var stillLoad: Task<Void, Never>?

    /// A fifth of the bar, no smaller than the phone's: an iPad's preview reads at arm's length.
    private static func stillWidth(for barWidth: CGFloat) -> CGFloat {
        min(max(176, barWidth * 0.2), 320)
    }

    private var span: Double { max(range.upperBound - range.lowerBound, 0.001) }

    private func fraction(_ value: Double) -> Double {
        min(max((value - range.lowerBound) / span, 0), 1)
    }

    private var fraction: Double { fraction(scrubValue ?? value) }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                track(width: geometry.size.width)
                .frame(height: scrubValue == nil ? 6 : 12)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .overlay(alignment: .topLeading) {
                    if let still, scrubValue != nil {
                        let width = Self.stillWidth(for: geometry.size.width)
                        let half = width / 2
                        let height = width * still.size.height / max(still.size.width, 1)
                        Image(uiImage: still)
                            .resizable()
                            .frame(width: width, height: height)
                            .clipShape(.rect(cornerRadius: 10))
                            .shadow(radius: 8)
                            .position(x: min(max(geometry.size.width * fraction, half), max(half, geometry.size.width - half)),
                                      y: -height / 2 - 8)
                            .allowsHitTesting(false)
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard isInteractive, geometry.size.width > 0 else { return }
                            let f = min(max(drag.location.x / geometry.size.width, 0), 1)
                            var target = range.lowerBound + span * f
                            if let seekable { target = min(max(target, seekable.lowerBound), seekable.upperBound) }
                            scrubValue = target
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
            .onChange(of: scrubValue) { _, time in
                stillTime = time
                if time == nil { still = nil } else { loadStill() }
            }

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

    /// Latest wins: one load at a time, then the newest position the finger reached.
    private func loadStill() {
        guard stillLoad == nil, let scrubStill else { return }
        stillLoad = Task {
            while let time = stillTime {
                stillTime = nil
                let image = await scrubStill(time)
                if scrubValue != nil, let image { still = image }
            }
            stillLoad = nil
        }
    }
}

extension IOSPlayerScrubber {
    @ViewBuilder
    fileprivate func track(width: CGFloat) -> some View {
        if seekable == nil, sections.isEmpty {
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28))
                Capsule().fill(.white).frame(width: width * fraction)
            }
        } else {
            let start = seekable.map { width * fraction($0.lowerBound) } ?? 0
            let reach = seekable.map { width * fraction($0.upperBound) } ?? width
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.28))
                Rectangle().fill(.white.opacity(0.22))
                    .frame(width: max(0, reach - start)).offset(x: start)
                Rectangle().fill(.white)
                    .frame(width: max(0, width * fraction - start)).offset(x: start)
            }
            .mask { IOSTimelineSections(cuts: sections.map(fraction)) }
        }
    }
}

/// The track cut into one rounded section per programme. No cuts: one capsule.
private struct IOSTimelineSections: View {
    let cuts: [Double]
    private static let gap: CGFloat = 3

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            let edges = [0] + cuts.filter { $0 > 0 && $0 < 1 }.sorted() + [1]
            var path = Path()
            for (from, to) in zip(edges, edges.dropFirst()) {
                let minX = size.width * from + (from > 0 ? Self.gap / 2 : 0)
                let maxX = size.width * to - (to < 1 ? Self.gap / 2 : 0)
                guard maxX > minX else { continue }
                let rect = CGRect(x: minX, y: 0, width: maxX - minX, height: size.height)
                let radius = min(size.height / 2, rect.width / 2)
                path.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius))
            }
            context.fill(path, with: .color(.white))
        }
    }
}
/// UIKit for what SwiftUI arbitrates poorly: single vs double tap with the
/// touch location, pinch, and a vertical swipe that must not steal horizontal
/// pans; plus the hardware keys and the pointer. Controls sit above this
/// surface. The view is the first responder while nothing is presented over
/// the player, so its key commands fire whether or not the chrome is up, and
/// a sheet gets the keyboard back (its own Escape) while it is open.
private struct IOSPlayerInputSurface: UIViewRepresentable {
    enum Key {
        case playPause, skipBackward, skipForward, close
    }

    let chromeVisible: Bool
    let canSkip: Bool
    let onTap: () -> Void
    let onDoubleTap: (_ leading: Bool) -> Void
    let onPinch: (_ fill: Bool) -> Void
    let onSwipeDown: () -> Void
    let onKey: (Key) -> Void

    func makeUIView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.backgroundColor = .clear
        let single = UITapGestureRecognizer(target: view, action: #selector(SurfaceView.tap))
        let double = UITapGestureRecognizer(target: view, action: #selector(SurfaceView.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)
        let pinch = UIPinchGestureRecognizer(target: view, action: #selector(SurfaceView.pinch(_:)))
        let pan = UIPanGestureRecognizer(target: view, action: #selector(SurfaceView.pan(_:)))
        pan.delegate = view
        [single, double, pinch, pan].forEach(view.addGestureRecognizer)
        view.addInteraction(UIPointerInteraction(delegate: view))
        return view
    }

    func updateUIView(_ view: SurfaceView, context: Context) {
        view.surface = self
        view.syncKeyboardOwnership()
    }

    final class SurfaceView: UIView, UIGestureRecognizerDelegate, UIPointerInteractionDelegate {
        var surface: IOSPlayerInputSurface? {
            didSet {
                guard surface?.chromeVisible != oldValue?.chromeVisible else { return }
                // The style is read when the pointer enters a region; a stationary pointer needs a re-read.
                interactions.compactMap { $0 as? UIPointerInteraction }.forEach { $0.invalidate() }
            }
        }

        private var recheckPending = false

        override var canBecomeFirstResponder: Bool { true }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            syncKeyboardOwnership()
        }

        /// First responder while the player is frontmost; a sheet or alert over it takes the
        /// keyboard (UIKit starts at the deepest presented controller when nobody holds it).
        /// Nothing announces the cover's dismissal, so while covered it looks again every
        /// half second and takes the keyboard back on the first look after it is gone.
        func syncKeyboardOwnership() {
            guard window != nil else { return }
            if isCovered {
                if isFirstResponder { resignFirstResponder() }
                guard !recheckPending else { return }
                recheckPending = true
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    self?.recheckPending = false
                    self?.syncKeyboardOwnership()
                }
            } else if !isFirstResponder {
                becomeFirstResponder()
            }
        }

        private var isCovered: Bool {
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let controller = next as? UIViewController { return controller.presentedViewController != nil }
                responder = next
            }
            return false
        }

        // MARK: Keys

        /// Space, Left, Right and Escape; one action per press, however long the key
        /// is held (UIKit repeats a key command by default, which would stack seeks).
        /// With keyboard navigation on, the system would otherwise take Space and the
        /// arrows for the focused control; Escape stays the system's.
        /// Known gap: on iPad the Now Playing Live Activity can take keyboard focus after playback starts.
        override var keyCommands: [UIKeyCommand]? {
            guard let surface, !isCovered else { return nil }
            var inputs = [UIKeyCommand.inputEscape, " "]
            if surface.canSkip { inputs += [UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow] }
            return inputs.map { input in
                let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(handleKey(_:)))
                command.repeatBehavior = .nonRepeatable
                command.wantsPriorityOverSystemBehavior = input != UIKeyCommand.inputEscape
                return command
            }
        }

        @objc private func handleKey(_ command: UIKeyCommand) {
            let key: Key? = switch command.input {
            case UIKeyCommand.inputEscape: .close
            case " ": .playPause
            case UIKeyCommand.inputLeftArrow: .skipBackward
            case UIKeyCommand.inputRightArrow: .skipForward
            default: nil
            }
            if let key { surface?.onKey(key) }
        }

        // MARK: Pointer

        /// Hidden over the picture while the chrome is down; the system arrow otherwise.
        func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
            surface?.chromeVisible == false ? .hidden() : nil
        }

        // MARK: Touches

        @objc func tap() { surface?.onTap() }

        @objc func doubleTap(_ recognizer: UITapGestureRecognizer) {
            surface?.onDoubleTap(recognizer.location(in: self).x < bounds.midX)
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            if recognizer.scale > 1.05 { surface?.onPinch(true) }
            if recognizer.scale < 0.95 { surface?.onPinch(false) }
        }

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            let translation = recognizer.translation(in: self).y
            let velocity = recognizer.velocity(in: self).y
            if translation > 80 || velocity > 900 { surface?.onSwipeDown() }
        }

        // UIView asks its own recognizers this too, so it is an override, not only the delegate.
        override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: self)
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
