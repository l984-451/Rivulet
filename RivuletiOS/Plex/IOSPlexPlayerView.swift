// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AVFoundation
import SwiftUI

struct IOSPlexPlayerView: View {
    let request: IOSPlexPlaybackRequest

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var plex: IOSPlexSession
    @StateObject private var player = AetherPlayer()
    @State private var controlsVisible = true
    @State private var panel: Panel?
    @State private var autoHideTask: Task<Void, Never>?
    @State private var skippedMarkerIDs: Set<String> = []
    @State private var lastReportedSecond = -1
    @State private var captionStyle = CaptionAppearance.current()
    @State private var osdTop: CGFloat?

    @AppStorage("autoSkipIntro") private var autoSkipIntro = false
    @AppStorage("autoSkipCredits") private var autoSkipCredits = false
    @AppStorage("autoSkipAds") private var autoSkipAds = false
    @AppStorage("autoSkipRecap") private var autoSkipRecap = false
    @AppStorage("playerSkipBackwardSeconds") private var skipBackwardSeconds = 10
    @AppStorage("playerSkipForwardSeconds") private var skipForwardSeconds = 30

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AetherPlayerSurface(player: player).ignoresSafeArea()
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

            if controlsVisible { osd.transition(.opacity) }
            if let marker = activeMarker {
                markerButton(marker).transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if shouldShowActivity {
                ProgressView(player.isBuffering ? "Buffering…" : "Opening…")
                    .tint(.white).foregroundStyle(.white).padding(16)
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
            }
            if case .failed(let message) = player.state { errorCard(message) }
        }
        .coordinateSpace(name: IOSPlayerChromeCoordinateSpace.name)
        .foregroundStyle(.white)
        .statusBarHidden()
        .task { await load() }
        .onAppear { restartAutoHide() }
        .onChange(of: player.sourceTime) { _, time in
            evaluateAutoSkip(at: time)
            reportProgressIfNeeded(at: time)
        }
        .onReceive(NotificationCenter.default.publisher(for: CaptionAppearance.changedNotification)) { _ in
            captionStyle = CaptionAppearance.current()
        }
        .onPreferenceChange(IOSPlayerRailTopPreferenceKey.self) { osdTop = $0 }
        .sheet(item: $panel) { panel in
            playerPanel(panel).presentationDetents([.medium]).presentationDragIndicator(.visible)
        }
        .onDisappear {
            autoHideTask?.cancel()
            let time = player.sourceTime
            player.stop()
            Task { await plex.reportProgress(for: request, time: time, state: "stopped") }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private var osd: some View {
        GeometryReader { geometry in
            // Keep the portrait rail's typography, touch targets and height in
            // landscape; the landscape adaptation is width only.
            let compact = true

            ZStack {
                VStack {
                    HStack {
                        Button { dismiss() } label: {
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

                    Spacer()
                    controlRail(compact: compact)
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
                    colors: [.black.opacity(0.65), .clear, .black.opacity(0.82)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
            )
        }
    }

    private func controlRail(compact: Bool) -> some View {
        IOSPlayerGlassRail(
            eyebrow: request.item.subtitle,
            title: request.item.displayTitle,
            currentTime: player.sourceTime,
            duration: max(request.item.durationSeconds, player.duration),
            isSeekable: true,
            centerControl: AnyView(
                IOSPlayerControlButton(
                    title: isPlaying ? "Pause" : "Play",
                    systemImage: isPlaying ? "pause.fill" : "play.fill",
                    prominent: true,
                    compact: compact,
                    disabled: shouldShowActivity
                ) {
                    isPlaying ? player.pause() : player.play()
                    restartAutoHide()
                }
            ),
            compact: compact,
            onSeek: { value in Task { await player.seek(to: value) } }
        ) {
            HStack(spacing: 4) {
                IOSPlayerControlButton(
                    title: "Subtitles",
                    systemImage: subtitleIcon,
                    compact: compact,
                    dense: true
                ) {
                    show(.subtitles)
                }
                IOSPlayerControlButton(
                    title: "Audio",
                    systemImage: "waveform",
                    compact: compact,
                    dense: true
                ) {
                    show(.audio)
                }
                IOSPlayerControlButton(
                    title: "Info",
                    systemImage: "info.circle",
                    compact: compact,
                    dense: true
                ) {
                    show(.info)
                }
            }
        }
    }

    private func markerButton(_ marker: IOSPlexMarker) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    skip(marker)
                } label: {
                    HStack(spacing: 9) {
                        if marker.isCommunity { Image(systemName: "person.3.fill") }
                        Text("Skip \(marker.displayName)").font(.headline)
                        Image(systemName: "forward.end.fill")
                    }
                    .padding(.horizontal, 20).padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(.ultraThinMaterial, in: Capsule())
                .background(Color.white.opacity(0.10), in: Capsule())
                .overlay { Capsule().stroke(.white.opacity(0.10), lineWidth: 1) }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, controlsVisible ? 190 : 34)
        }
        .allowsHitTesting(true)
    }

    @ViewBuilder
    private func playerPanel(_ panel: Panel) -> some View {
        NavigationStack {
            List {
                switch panel {
                case .subtitles:
                    Button { player.selectSubtitleTrack(id: nil); self.panel = nil } label: {
                        trackRow("Off", detail: nil, selected: player.currentSubtitleTrackId == nil)
                    }
                    ForEach(player.subtitleTracks) { track in
                        Button { player.selectSubtitleTrack(id: track.id); self.panel = nil } label: {
                            trackRow(track.name, detail: track.detail, selected: player.currentSubtitleTrackId == track.id)
                        }
                    }
                case .audio:
                    ForEach(player.audioTracks) { track in
                        Button { player.selectAudioTrack(id: track.id); self.panel = nil } label: {
                            trackRow(track.name, detail: track.detail, selected: player.currentAudioTrackId == track.id)
                        }
                    }
                case .info:
                    Section("Media") {
                        LabeledContent("Title", value: request.item.displayTitle)
                        if let type = request.item.type { LabeledContent("Type", value: type.capitalized) }
                        LabeledContent("Player", value: "AetherEngine")
                    }
                    if !request.markers.isEmpty {
                        Section("Skip markers") {
                            ForEach(request.markers, id: \.stableID) { marker in
                                HStack {
                                    Label(marker.displayName, systemImage: marker.isCommunity ? "person.3.fill" : "forward.end")
                                    Spacer()
                                    Text("\(format(marker.start))–\(format(marker.end))").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(panel.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { self.panel = nil } } }
        }
    }

    private func trackRow(_ title: String, detail: String?, selected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title).foregroundStyle(.primary)
                if let detail, !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title).foregroundStyle(.yellow)
            Text("Couldn’t play this video").font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Close") { dismiss() }.buttonStyle(.borderedProminent)
        }
        .padding(20).frame(maxWidth: 360).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18)).padding()
    }

    private var activeMarker: IOSPlexMarker? {
        request.markers.first {
            !skippedMarkerIDs.contains($0.stableID) && player.sourceTime >= $0.start && player.sourceTime < $0.end
        }
    }

    private var visibleSubtitleCues: [AetherPlayer.SubtitleCue] {
        player.subtitleCues.filter { $0.startTime <= player.sourceTime && $0.endTime >= player.sourceTime }
    }

    private var shouldShowActivity: Bool {
        if case .idle = player.state { return true }
        if case .loading = player.state { return true }
        return player.isBuffering
    }

    private var isPlaying: Bool { if case .playing = player.state { true } else { false } }
    private var subtitleIcon: String { player.currentSubtitleTrackId == nil ? "captions.bubble" : "captions.bubble.fill" }

    private func load() async {
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .moviePlayback)
            try audio.setActive(true)
            try await player.load(url: request.url, headers: request.headers, startTime: request.item.resumeSeconds > 0 ? request.item.resumeSeconds : nil)
            await plex.reportProgress(for: request, time: player.sourceTime, state: "playing")
        } catch is CancellationError { return }
        catch { }
    }

    private func evaluateAutoSkip(at time: TimeInterval) {
        guard let marker = request.markers.first(where: {
            !skippedMarkerIDs.contains($0.stableID) && time >= $0.start && time < $0.end
        }) else { return }
        let enabled: Bool
        switch marker.type {
        case "intro": enabled = autoSkipIntro
        case "recap": enabled = autoSkipRecap
        case "commercial": enabled = autoSkipAds
        case "credits": enabled = autoSkipCredits
        default: enabled = false
        }
        if enabled { skip(marker) }
    }

    private func skip(_ marker: IOSPlexMarker) {
        skippedMarkerIDs.insert(marker.stableID)
        Task { await player.seek(to: marker.end) }
    }

    private func seekBy(_ interval: TimeInterval) {
        let duration = max(request.item.durationSeconds, player.duration)
        let target = min(max(player.sourceTime + interval, 0), max(duration, 0))
        Task { await player.seek(to: target) }
        restartAutoHide()
    }

    private func reportProgressIfNeeded(at time: TimeInterval) {
        let second = Int(time)
        guard second > 0, second % 10 == 0, second != lastReportedSecond else { return }
        lastReportedSecond = second
        Task { await plex.reportProgress(for: request, time: time, state: isPlaying ? "playing" : "paused") }
    }

    private func show(_ panel: Panel) {
        autoHideTask?.cancel()
        self.panel = panel
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
        restartAutoHide()
    }

    private func restartAutoHide() {
        autoHideTask?.cancel()
        guard controlsVisible, panel == nil else { return }
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, panel == nil else { return }
            withAnimation(.easeInOut(duration: 0.25)) { controlsVisible = false }
        }
    }

    private func format(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "0:00" }
        let total = max(0, Int(time))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private enum Panel: String, Identifiable {
        case subtitles, audio, info
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }
}
