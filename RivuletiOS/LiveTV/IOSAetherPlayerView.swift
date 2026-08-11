// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AVFoundation
import Combine
import SwiftUI

struct IOSAetherPlayerView: View {
    let channels: [IOSIPTVChannel]
    let programsByChannel: [String: [IOSEPGProgram]]

    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = AetherPlayer()
    @State private var request: IOSPlaybackRequest
    @State private var loadAttempt = 0
    @State private var controlsVisible = true
    @State private var activePanel: Panel?
    @State private var autoHideTask: Task<Void, Never>?
    @State private var captionStyle = CaptionAppearance.current()
    @State private var osdTop: CGFloat?
    @AppStorage("playerSkipBackwardSeconds") private var skipBackwardSeconds = 10
    @AppStorage("playerSkipForwardSeconds") private var skipForwardSeconds = 30

    init(
        request: IOSPlaybackRequest,
        channels: [IOSIPTVChannel],
        programsByChannel: [String: [IOSEPGProgram]]
    ) {
        self.channels = channels
        self.programsByChannel = programsByChannel
        _request = State(initialValue: request)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            AetherPlayerSurface(player: player)
                .ignoresSafeArea()

            IOSAetherSubtitleOverlay(
                cues: visibleSubtitleCues,
                nativeCues: player.nativeSubtitleCues,
                style: captionStyle,
                landscapeOSDTop: controlsVisible ? osdTop : nil,
                videoSize: player.videoSize
            )
            .ignoresSafeArea()

            IOSPlayerTapSurface(
                onSingleTap: { toggleControls() },
                onDoubleTapLeft: { seekBy(-TimeInterval(skipBackwardSeconds)) },
                onDoubleTapRight: { seekBy(TimeInterval(skipForwardSeconds)) }
            )
            .ignoresSafeArea()

            if controlsVisible {
                osd
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if shouldShowActivity {
                ProgressView(player.isBuffering ? "Buffering…" : "Opening channel…")
                    .tint(.white)
                    .foregroundStyle(.white)
                    .padding(18)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
            }

            if case .failed(let message) = player.state {
                errorCard(message: message)
            }
        }
        .coordinateSpace(name: IOSPlayerChromeCoordinateSpace.name)
        .foregroundStyle(.white)
        .statusBarHidden()
        .task(id: loadAttempt) {
            await loadChannel()
        }
        .onAppear { restartAutoHide() }
        .onChange(of: activePanel) { _, panel in
            if panel == nil { restartAutoHide() }
        }
        .onReceive(NotificationCenter.default.publisher(for: CaptionAppearance.changedNotification)) { _ in
            captionStyle = CaptionAppearance.current()
        }
        .onPreferenceChange(IOSPlayerRailTopPreferenceKey.self) { osdTop = $0 }
        .sheet(item: $activePanel) { panel in
            playerPanel(panel)
                .presentationDetents(panel == .channels ? [.medium, .large] : [.medium])
                .presentationDragIndicator(.visible)
        }
        .onDisappear {
            autoHideTask?.cancel()
            player.stop()
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    private var osd: some View {
        GeometryReader { geometry in
            // Landscape widens the portrait rail without scaling its height,
            // typography or 44-point touch controls.
            let compact = true

            ZStack {
                VStack(spacing: 0) {
                    topBar(compact: compact)
                    Spacer()
                    liveRail(compact: compact)
                        .padding(.horizontal, compact ? 10 : 24)
                        .padding(.bottom, compact ? 8 : 18)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: IOSPlayerRailTopPreferenceKey.self,
                                    value: proxy.frame(in: .named(IOSPlayerChromeCoordinateSpace.name)).minY
                                )
                            }
                        }
                }

            }
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.62), .clear, .black.opacity(0.72)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
            )
        }
    }

    private func topBar(compact: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.62), in: Circle())
            }
            .accessibilityLabel("Close player")
            Spacer()
        }
        .padding(.horizontal, compact ? 10 : 24)
        .padding(.top, 8)
    }

    private func liveRail(compact: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            IOSPlayerGlassRail(
                eyebrow: request.channel.name,
                title: request.program?.title ?? "Live channel",
                currentTime: liveProgramCurrentTime(at: context.date),
                duration: liveProgramDuration,
                isSeekable: false,
                centerControl: AnyView(
                    IOSPlayerControlButton(
                        title: isPlaying ? "Pause" : "Play",
                        systemImage: isPlaying ? "pause.fill" : "play.fill",
                        prominent: true,
                        compact: compact,
                        disabled: shouldShowActivity || isFailed
                    ) {
                        togglePlayback()
                    }
                ),
                progressLeadingLabel: request.program.map { programStartLabel($0) },
                progressTrailingLabel: request.program.map { programEndLabel($0) },
                compact: compact,
                onSeek: { _ in }
            ) {
                HStack(spacing: 4) {
                    IOSPlayerControlButton(
                        title: "Channels",
                        systemImage: "tv.inset.filled",
                        compact: compact,
                        dense: true
                    ) {
                        showPanel(.channels)
                    }
                    IOSPlayerControlButton(
                        title: "Subtitles",
                        systemImage: subtitleIcon,
                        compact: compact,
                        dense: true
                    ) {
                        showPanel(.subtitles)
                    }
                    IOSPlayerControlButton(
                        title: "Audio",
                        systemImage: "waveform",
                        compact: compact,
                        dense: true
                    ) {
                        showPanel(.audio)
                    }
                    IOSPlayerControlButton(
                        title: "Info",
                        systemImage: "info.circle",
                        compact: compact,
                        dense: true
                    ) {
                        showPanel(.info)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func playerPanel(_ panel: Panel) -> some View {
        NavigationStack {
            List {
                switch panel {
                case .channels:
                    channelRows
                case .subtitles:
                    subtitleRows
                case .audio:
                    audioRows
                case .info:
                    infoRows
                }
            }
            .navigationTitle(panel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { activePanel = nil }
                }
            }
        }
    }

    @ViewBuilder
    private var channelRows: some View {
        ForEach(channels) { channel in
            Button {
                switchChannel(to: channel)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(channel.name)
                            .foregroundStyle(.primary)
                        if let program = currentProgram(for: channel) {
                            Text(program.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if channel.id == request.channel.id {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var subtitleRows: some View {
        Button {
            player.selectSubtitleTrack(id: nil)
            activePanel = nil
        } label: {
            trackRow(title: "Off", detail: nil, selected: player.currentSubtitleTrackId == nil)
        }

        if player.subtitleTracks.isEmpty {
            ContentUnavailableView(
                "No subtitle tracks",
                systemImage: "captions.bubble",
                description: Text("This channel has not reported embedded captions.")
            )
        } else {
            ForEach(player.subtitleTracks) { track in
                Button {
                    player.selectSubtitleTrack(id: track.id)
                    activePanel = nil
                } label: {
                    trackRow(
                        title: track.name,
                        detail: track.detail,
                        selected: player.currentSubtitleTrackId == track.id
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var audioRows: some View {
        if player.audioTracks.isEmpty {
            ContentUnavailableView(
                "No alternate audio",
                systemImage: "waveform",
                description: Text("The channel currently exposes only its default audio.")
            )
        } else {
            ForEach(player.audioTracks) { track in
                Button {
                    player.selectAudioTrack(id: track.id)
                    activePanel = nil
                } label: {
                    trackRow(
                        title: track.name,
                        detail: track.detail,
                        selected: player.currentAudioTrackId == track.id
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var infoRows: some View {
        Section {
            LabeledContent("Channel", value: request.channel.name)
            if let number = request.channel.channelNumber {
                LabeledContent("Number", value: "\(number)")
            }
        }

        if let program = request.program {
            Section("Programme") {
                Text(program.title)
                    .font(.headline)
                if let subtitle = program.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Airing") {
                    Text(programTimeRange(program))
                }
            }

            if let description = program.description, !description.isEmpty {
                Section("Description") {
                    Text(description)
                }
            }
        }
    }

    private func trackRow(title: String, detail: String?, selected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .foregroundStyle(.primary)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
    }

    private func errorCard(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(.yellow)
            Text("Couldn’t play this channel")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)

            HStack {
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Retry") {
                    player.stop()
                    loadAttempt += 1
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(maxWidth: 360)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding()
    }

    private var visibleSubtitleCues: [AetherPlayer.SubtitleCue] {
        player.subtitleCues.filter {
            $0.startTime <= player.sourceTime && $0.endTime >= player.sourceTime
        }
    }

    private var shouldShowActivity: Bool {
        switch player.state {
        case .idle, .loading:
            return true
        default:
            return player.isBuffering
        }
    }

    private var isPlaying: Bool {
        if case .playing = player.state { return true }
        return false
    }

    private var isFailed: Bool {
        if case .failed = player.state { return true }
        return false
    }

    private var subtitleIcon: String {
        player.currentSubtitleTrackId == nil ? "captions.bubble" : "captions.bubble.fill"
    }

    private var liveProgramDuration: TimeInterval {
        guard let program = request.program else { return 0 }
        return max(0, program.end.timeIntervalSince(program.start))
    }

    private func liveProgramCurrentTime(at date: Date) -> TimeInterval {
        guard let program = request.program else { return 0 }
        return min(max(date.timeIntervalSince(program.start), 0), liveProgramDuration)
    }

    private func programStartLabel(_ program: IOSEPGProgram) -> String {
        program.start.formatted(date: .omitted, time: .shortened)
    }

    private func programEndLabel(_ program: IOSEPGProgram) -> String {
        program.end.formatted(date: .omitted, time: .shortened)
    }

    private func programTimeRange(_ program: IOSEPGProgram) -> String {
        "\(program.start.formatted(date: .omitted, time: .shortened)) – \(program.end.formatted(date: .omitted, time: .shortened))"
    }

    private func currentProgram(for channel: IOSIPTVChannel) -> IOSEPGProgram? {
        programsByChannel[channel.id]?.first { $0.isAiring(at: Date()) }
    }

    private func showPanel(_ panel: Panel) {
        autoHideTask?.cancel()
        activePanel = panel
    }

    private func switchChannel(to channel: IOSIPTVChannel) {
        guard channel.id != request.channel.id else {
            activePanel = nil
            return
        }
        player.stop()
        request = IOSPlaybackRequest(channel: channel, program: currentProgram(for: channel))
        loadAttempt += 1
        activePanel = nil
        revealControls()
    }

    private func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        restartAutoHide()
    }

    private func seekBy(_ interval: TimeInterval) {
        var target = max(0, player.sourceTime + interval)
        if player.duration.isFinite, player.duration > 0 {
            target = min(target, player.duration)
        }
        Task { await player.seek(to: target) }
        restartAutoHide()
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            controlsVisible.toggle()
        }
        restartAutoHide()
    }

    private func revealControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            controlsVisible = true
        }
        restartAutoHide()
    }

    private func restartAutoHide() {
        autoHideTask?.cancel()
        guard controlsVisible, activePanel == nil else { return }
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, activePanel == nil else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                controlsVisible = false
            }
        }
    }

    private func loadChannel() async {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback)
            try audioSession.setActive(true)
            var headers = request.channel.playbackHeaders.dictionary
            // A client-generated ID stays stable across Aether/AVPlayer's
            // internal retries for this load, and changes when the user tunes
            // another channel or explicitly retries.
            headers["X-Playback-Session-Id"] = UUID().uuidString
            try await player.loadLive(
                url: request.channel.streamURL,
                headers: headers
            )
        } catch is CancellationError {
            return
        } catch {
            // AetherPlayer publishes the useful failure text for the overlay.
        }
    }

    private enum Panel: String, Identifiable {
        case channels
        case subtitles
        case audio
        case info

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }
}

struct IOSAetherSubtitleOverlay: View {
    let cues: [AetherPlayer.SubtitleCue]
    let nativeCues: [AetherPlayer.SubtitleCue]
    let style: CaptionStyle
    let landscapeOSDTop: CGFloat?
    let videoSize: CGSize

    private enum Metrics {
        // iPhone captions need a smaller curve than the 10-foot tvOS UI.
        // 0.039675 is a 25% reduction from tvOS's 0.0529, equivalent to
        // reducing a 0.20 scale factor to 0.15.
        static let fontHeightFraction: CGFloat = 0.039675
        static let minimumPointSize: CGFloat = 10
        static let positionedSafeFraction: CGFloat = 0.10
        static let unpositionedBottomFraction: CGFloat = 0.05
    }

    var body: some View {
        GeometryReader { proxy in
            let allCues = cues + nativeCues
            let pointSize = max(
                Metrics.minimumPointSize,
                min(proxy.size.width, proxy.size.height)
                    * Metrics.fontHeightFraction
                    * style.fontScale
            )
            let picture = pictureRect(in: proxy.size)
            let osdBoundary = landscapeCaptionMaxY(
                in: picture,
                container: proxy.size
            )
            let positionedSafe = positionedSafeRect(in: picture)
            let defaultBand = defaultBandRect(
                in: picture,
                osdBoundary: osdBoundary
            )
            ZStack {
                ForEach(allCues) { cue in
                    if case .image(let image, let position) = cue.body {
                        let frame = adjustedPositionedFrame(
                            CGRect(
                                x: picture.minX + picture.width * position.minX,
                                y: picture.minY + picture.height * position.minY,
                                width: picture.width * position.width,
                                height: picture.height * position.height
                            ),
                            in: picture,
                            osdBoundary: osdBoundary
                        )
                        Image(uiImage: image)
                            .resizable()
                            .frame(
                                width: frame.width,
                                height: frame.height
                            )
                            .position(
                                x: frame.midX,
                                y: frame.midY
                            )
                            .animation(.easeInOut(duration: 0.25), value: osdBoundary)
                    }
                }

                ForEach(allCues) { cue in
                    if cue.hasText, let placement = cue.placement {
                        IOSPositionedCaptionLayout(
                            placement: placement,
                            pictureRect: picture,
                            safeRect: positionedSafe,
                            osdBoundary: osdBoundary
                        ) {
                            subtitleText(cue.body, pointSize: pointSize)
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .animation(.easeInOut(duration: 0.25), value: osdBoundary)
                    }
                }

                VStack(spacing: 6) {
                    ForEach(allCues) { cue in
                        if cue.hasText, cue.placement == nil {
                            subtitleText(cue.body, pointSize: pointSize)
                        }
                    }
                }
                .frame(width: defaultBand.width, height: defaultBand.height, alignment: .bottom)
                .position(x: defaultBand.midX, y: defaultBand.midY)
                .animation(.easeInOut(duration: 0.25), value: osdBoundary)
            }
        }
        .allowsHitTesting(false)
    }

    private func subtitleText(
        _ body: AetherPlayer.SubtitleCue.Body,
        pointSize: CGFloat
    ) -> some View {
        renderedText(body, pointSize: pointSize)
            .multilineTextAlignment(.center)
            .padding(.horizontal, pointSize * 0.30)
            .padding(.vertical, pointSize * 0.075)
            .background(
                style.edge == .uniform
                    ? Color.clear
                    : Color(uiColor: style.backgroundColor).opacity(style.backgroundOpacity),
                in: RoundedRectangle(cornerRadius: pointSize * 0.25)
            )
            .modifier(IOSCaptionEdgeModifier(style: style.edge, pointSize: pointSize))
    }

    private func renderedText(
        _ body: AetherPlayer.SubtitleCue.Body,
        pointSize: CGFloat
    ) -> Text {
        let userColor = Color(uiColor: style.foreground).opacity(style.foregroundOpacity)
        switch body {
        case .text(let string):
            return Text(string)
                .font(Font(style.font(ofSize: pointSize)))
                .foregroundColor(userColor)
        case .styledText(let runs):
            return runs.reduce(Text("")) { result, run in
                let runColor = style.allowsContentColor ? run.color : nil
                var text = Text(run.text)
                    .font(Font(font(for: run, baseSize: pointSize)))
                    .foregroundColor(
                        runColor.map {
                            Color(uiColor: $0).opacity(style.foregroundOpacity)
                        } ?? userColor
                    )
                if style.allowsContentFont {
                    if run.isUnderlined { text = text.underline() }
                    if run.isStruckThrough { text = text.strikethrough() }
                }
                return Text("\(result)\(text)")
            }
        case .image:
            return Text("")
        }
    }

    private func font(
        for run: AetherPlayer.SubtitleCue.StyledRun,
        baseSize: CGFloat
    ) -> UIFont {
        var size = baseSize
        if style.allowsContentFontSize, let contentSize = run.fontSize, contentSize > 0 {
            size *= min(max(CGFloat(contentSize) / 16, 0.5), 2)
        }

        var font: UIFont
        if style.allowsContentFont,
           let name = run.fontName,
           !name.isEmpty,
           let named = UIFont(name: name, size: size) {
            font = named
        } else {
            font = style.font(ofSize: size)
        }

        guard style.allowsContentFont else { return font }
        var traits: UIFontDescriptor.SymbolicTraits = []
        if run.isBold { traits.insert(.traitBold) }
        if run.isItalic { traits.insert(.traitItalic) }
        if !traits.isEmpty,
           let descriptor = font.fontDescriptor.withSymbolicTraits(
               font.fontDescriptor.symbolicTraits.union(traits)
           ) {
            font = UIFont(descriptor: descriptor, size: size)
        }
        return font
    }

    private func pictureRect(in container: CGSize) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0,
              container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / videoSize.width, container.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func positionedSafeRect(in picture: CGRect) -> CGRect {
        picture.insetBy(
            dx: picture.width * Metrics.positionedSafeFraction,
            dy: picture.height * Metrics.positionedSafeFraction
        )
    }

    /// Matches the subtitle-refinement renderer: clamp authored text and DVB/
    /// PGS bitmap boxes into the picture's central 80%, then move an overlapping
    /// cue only far enough upward to keep the 5%-of-picture OSD clearance.
    private func adjustedPositionedFrame(
        _ frame: CGRect,
        in picture: CGRect,
        osdBoundary: CGFloat?
    ) -> CGRect {
        let safe = positionedSafeRect(in: picture)
        let maxX = max(safe.minX, safe.maxX - frame.width)
        var originX = min(max(frame.minX, safe.minX), maxX)
        let maxY = max(safe.minY, safe.maxY - frame.height)
        var originY = min(max(frame.minY, safe.minY), maxY)

        if let osdBoundary {
            originY = min(originY, osdBoundary - frame.height)
            originY = max(picture.minY, originY)
        }

        if !originX.isFinite { originX = safe.minX }
        if !originY.isFinite { originY = safe.minY }
        return CGRect(origin: CGPoint(x: originX, y: originY), size: frame.size)
    }

    private func defaultBandRect(
        in picture: CGRect,
        osdBoundary: CGFloat?
    ) -> CGRect {
        let sideInset = picture.width * Metrics.positionedSafeFraction
        let restingMaxY = picture.maxY
            - picture.height * Metrics.unpositionedBottomFraction
        let maxY = min(restingMaxY, osdBoundary ?? restingMaxY)
        return CGRect(
            x: picture.minX + sideInset,
            y: picture.minY,
            width: max(0, picture.width - sideInset * 2),
            height: max(0, maxY - picture.minY)
        )
    }

    private func landscapeCaptionMaxY(
        in picture: CGRect,
        container: CGSize
    ) -> CGFloat? {
        guard container.width > container.height, let landscapeOSDTop else { return nil }
        return min(
            picture.maxY,
            landscapeOSDTop - picture.height * Metrics.unpositionedBottomFraction
        )
    }
}

private extension AetherPlayer.SubtitleCue {
    var hasText: Bool {
        switch body {
        case .text(let text): return !text.isEmpty
        case .styledText(let runs): return runs.contains { !$0.text.isEmpty }
        case .image: return false
        }
    }
}

/// Places a content-positioned text cue inside the visible picture's title-safe
/// region. Fine x positions belong to the left/centre/right caption-box edge
/// selected by the cue alignment; fine y positions name the box's top edge.
/// Coarse ASS/teletext positions resolve to the corresponding 10/50/90% band.
/// The measured box is clamped after wrapping, matching subtitle-refinement.
private struct IOSPositionedCaptionLayout: Layout {
    let placement: AetherPlayer.SubtitleCue.TextPlacement
    let pictureRect: CGRect
    let safeRect: CGRect
    let osdBoundary: CGFloat?

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first, safeRect.width > 0, safeRect.height > 0 else { return }

        let fitted = subview.sizeThatFits(
            ProposedViewSize(width: safeRect.width, height: safeRect.height)
        )
        let width = min(fitted.width, safeRect.width)
        let height = min(fitted.height, safeRect.height)
        let alignment = min(max(placement.alignment ?? 2, 1), 9)
        let column = (alignment - 1) % 3
        let row = (alignment - 1) / 3

        let anchorX: CGFloat
        if let x = placement.position?.x {
            anchorX = pictureRect.minX
                + min(max(x, 0.10), 0.90) * pictureRect.width
        } else if column == 0 {
            anchorX = pictureRect.minX + pictureRect.width * 0.10
        } else if column == 2 {
            anchorX = pictureRect.minX + pictureRect.width * 0.90
        } else {
            anchorX = pictureRect.midX
        }

        let requestedX: CGFloat
        switch column {
        case 0: requestedX = anchorX
        case 2: requestedX = anchorX - width
        default: requestedX = anchorX - width / 2
        }

        let requestedY: CGFloat
        if let y = placement.position?.y {
            // Fine positions describe the caption box's top edge.
            requestedY = pictureRect.minY
                + min(max(y, 0.10), 0.90) * pictureRect.height
        } else if row == 2 {
            requestedY = pictureRect.minY + pictureRect.height * 0.10
        } else if row == 1 {
            requestedY = pictureRect.midY - height / 2
        } else {
            requestedY = pictureRect.minY + pictureRect.height * 0.90 - height
        }

        let maximumX = max(safeRect.minX, safeRect.maxX - width)
        let originX = min(max(requestedX, safeRect.minX), maximumX)
        let maximumY = max(safeRect.minY, safeRect.maxY - height)
        var originY = min(max(requestedY, safeRect.minY), maximumY)
        if let osdBoundary {
            originY = min(originY, osdBoundary - height)
            originY = max(pictureRect.minY, originY)
        }
        subview.place(
            at: CGPoint(x: originX, y: originY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: height)
        )
    }
}

private struct IOSCaptionEdgeModifier: ViewModifier {
    let style: CaptionStyle.Edge
    let pointSize: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        let depth = max(1, pointSize * 0.04)
        switch style {
        case .none:
            content
        case .dropShadow:
            content.shadow(color: .black.opacity(0.85), radius: 3, y: 1)
        case .raised:
            content.shadow(color: .black.opacity(0.9), radius: 0, x: depth, y: depth)
        case .depressed:
            content.shadow(color: .black.opacity(0.9), radius: 0, x: -depth, y: -depth)
        case .uniform:
            content
                .shadow(color: .black, radius: 0, x: depth, y: 0)
                .shadow(color: .black, radius: 0, x: -depth, y: 0)
                .shadow(color: .black, radius: 0, x: 0, y: depth)
                .shadow(color: .black, radius: 0, x: 0, y: -depth)
        }
    }
}
