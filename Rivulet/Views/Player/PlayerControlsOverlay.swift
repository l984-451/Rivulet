//
//  PlayerControlsOverlay.swift
//  Rivulet
//
//  Native tvOS-style player controls with transport bar and swipe-down info panel
//

import SwiftUI

struct PlayerControlsOverlay: View {
    @ObservedObject var viewModel: UniversalPlayerViewModel
    /// When true, shows only the info panel. When false, shows only the transport bar.
    var showInfoPanel: Bool = false

    /// When true, hides the title from the transport bar (used when paused poster is showing)
    var hideTitle: Bool = false

    var body: some View {
        ZStack {
            if showInfoPanel {
                // Info panel only
                infoPanel
            } else {
                // Transport bar at bottom only
                VStack {
                    Spacer()
                    transportBar
                }
            }
        }
    }

    // MARK: - Transport Bar (Bottom)

    private var transportBar: some View {
        VStack(spacing: 16) {
            // Title (shows briefly at top of transport area, hidden when paused poster is showing)
            if !hideTitle {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.title)
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if let subtitle = viewModel.subtitle {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                        }
                    }
                    Spacer()

                    // Playback state indicator
                    if viewModel.isBuffering {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.white)
                    }
                }
                .padding(.horizontal, 80)
            }

            // Progress bar with scrubbing support
            TransportProgressBar(
                currentTime: viewModel.currentTime,
                duration: viewModel.duration,
                isScrubbing: viewModel.isScrubbing,
                scrubTime: viewModel.scrubTime,
                scrubStepLabel: viewModel.scrubStepLabel,
                scrubThumbnail: viewModel.scrubThumbnail,
                markers: viewModel.metadata.allMarkers
            )
            .padding(.horizontal, 80)
            .padding(.bottom, 50)
        }
        .padding(.vertical, 30)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.8)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }

    // MARK: - Playback Settings Panel (Horizontal Bar at Top)

    private let settingsPanelHeight: CGFloat = 340

    private var infoPanel: some View {
        VStack(spacing: 0) {
            // Main panel content
            HStack(alignment: .top, spacing: 0) {
                // Left Column: Subtitles
                settingsColumn(title: "SUBTITLES", columnIndex: 0) {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 4) {
                                // Off option
                                PlaybackSettingsRow(
                                    title: "Off",
                                    subtitle: "No subtitles",
                                    isSelected: viewModel.currentSubtitleTrackId == nil,
                                    isFocused: viewModel.isSettingFocused(column: 0, index: 0)
                                )
                                .id("sub_0")

                                ForEach(Array(viewModel.subtitleTracks.enumerated()), id: \.element.id) { index, track in
                                    PlaybackSettingsRow(
                                        title: formatSubtitleTrackTitle(track),
                                        subtitle: formatSubtitleTrackSubtitle(track),
                                        isSelected: track.id == viewModel.currentSubtitleTrackId,
                                        isFocused: viewModel.isSettingFocused(column: 0, index: index + 1)
                                    )
                                    .id("sub_\(index + 1)")
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .onChange(of: viewModel.focusedRowIndex) { _, newIndex in
                            if viewModel.focusedColumn == 0 {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("sub_\(newIndex)", anchor: .center)
                                }
                            }
                        }
                    }
                }

                // Divider
                Rectangle()
                    .fill(.white.opacity(0.15))
                    .frame(width: 1)
                    .padding(.vertical, 20)

                // Middle Column: Audio
                settingsColumn(title: "AUDIO", columnIndex: 1) {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(viewModel.audioTracks.enumerated()), id: \.element.id) { index, track in
                                    PlaybackSettingsRow(
                                        title: formatAudioTrackTitle(track),
                                        subtitle: formatAudioTrackSubtitle(track),
                                        isSelected: track.id == viewModel.currentAudioTrackId,
                                        isFocused: viewModel.isSettingFocused(column: 1, index: index)
                                    )
                                    .id("audio_\(index)")
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .onChange(of: viewModel.focusedRowIndex) { _, newIndex in
                            if viewModel.focusedColumn == 1 {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("audio_\(newIndex)", anchor: .center)
                                }
                            }
                        }
                    }
                }

                // Divider
                Rectangle()
                    .fill(.white.opacity(0.15))
                    .frame(width: 1)
                    .padding(.vertical, 20)

                // Right Column: Media Info
                settingsColumn(title: "MEDIA INFO", columnIndex: 2) {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 10) {
                            // Title
                            Text(viewModel.title)
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(2)

                            if let subtitle = viewModel.subtitle {
                                Text(subtitle)
                                    .font(.system(size: 20))
                                    .foregroundStyle(.white.opacity(0.6))
                            }

                            Divider()
                                .background(.white.opacity(0.2))
                                .padding(.vertical, 8)

                            // Video info
                            if let videoInfo = videoInfoString {
                                mediaInfoText(label: "Video", value: videoInfo)
                            }

                            if let hdrInfo = hdrInfoString {
                                mediaInfoText(label: "HDR", value: hdrInfo, highlight: true)
                            }

                            if let audioInfo = audioInfoString {
                                mediaInfoText(label: "Audio", value: audioInfo)
                            }

                            if let fileInfo = fileInfoString {
                                mediaInfoText(label: "File", value: fileInfo)
                            }

                            if viewModel.duration > 0 {
                                mediaInfoText(label: "Duration", value: formatDuration(viewModel.duration))
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 20)
            .padding(.horizontal, 24)
            .frame(height: settingsPanelHeight)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .clipped()
            // Use dark translucent material instead of glassEffect for HDR/DV compatibility
            // glassEffect adapts to content behind it, appearing light on bright HDR video
            .background(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
            .background(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(.black.opacity(0.6))
            )
            // GPU-accelerated shadow
            .background(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(.black)
                    .blur(radius: 30)
                    .offset(y: 15)
                    .opacity(0.5)
            )
            .padding(.horizontal, 60)
            .padding(.top, 40)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        // Note: Menu/Back button handling is centralized in PlayerContainerViewController
        // to properly intercept the event before it can dismiss the modal.
        // Do NOT add onExitCommand here.
    }

    /// Column container with header
    private func settingsColumn<Content: View>(
        title: String,
        columnIndex: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Column header
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(viewModel.focusedColumn == columnIndex ? .white : .white.opacity(0.5))
                .padding(.horizontal, 16)

            // Column content
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Simple text row for media info
    private func mediaInfoText(label: String, value: String, highlight: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 90, alignment: .leading)

            Text(value)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(highlight ? .yellow : .white.opacity(0.9))
        }
    }

    private func settingsSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .bold))
            .tracking(1.5)
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 36)
            .padding(.top, 24)
            .padding(.bottom, 8)
    }

    // MARK: - Media Info Helpers

    private var videoInfoString: String? {
        guard let media = viewModel.metadata.Media?.first else { return nil }
        var parts: [String] = []

        // Resolution - prefer videoResolution field (handles ultrawide correctly)
        if let res = media.videoResolution {
            // Plex provides resolution like "1080p", "4k", "720p"
            let formatted = res.lowercased()
            if formatted.contains("4k") || formatted.contains("2160") {
                parts.append("4K")
            } else if formatted.contains("1080") {
                parts.append("1080p")
            } else if formatted.contains("720") {
                parts.append("720p")
            } else if formatted.contains("480") {
                parts.append("480p")
            } else {
                parts.append(res.uppercased())
            }
        } else if let height = media.height {
            // Fallback to height-based calculation
            if height >= 2160 {
                parts.append("4K")
            } else if height >= 1080 {
                parts.append("1080p")
            } else if height >= 720 {
                parts.append("720p")
            } else {
                parts.append("\(height)p")
            }
        }

        // Codec
        if let codec = media.videoCodec?.uppercased() {
            if codec.contains("HEVC") || codec.contains("H265") {
                parts.append("HEVC")
            } else if codec.contains("AVC") || codec.contains("H264") {
                parts.append("H.264")
            } else if codec.contains("AV1") {
                parts.append("AV1")
            } else {
                parts.append(codec)
            }
        }

        // Frame rate
        if let fps = media.videoFrameRate {
            if fps.contains("24") || fps.lowercased().contains("24p") {
                parts.append("24fps")
            } else if fps.contains("60") {
                parts.append("60fps")
            }
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var hdrInfoString: String? {
        guard let streams = viewModel.metadata.Media?.first?.Part?.first?.Stream else { return nil }
        let videoStream = streams.first { $0.isVideo }

        var hdrParts: [String] = []

        if videoStream?.isDolbyVision == true {
            hdrParts.append("Dolby Vision")
        } else if videoStream?.isHDR == true {
            hdrParts.append("HDR10")
        }

        if let bitDepth = videoStream?.bitDepth, bitDepth >= 10 {
            hdrParts.append("\(bitDepth)-bit")
        }

        return hdrParts.isEmpty ? nil : hdrParts.joined(separator: " · ")
    }

    private var audioInfoString: String? {
        // Show the currently selected audio track if available
        if let currentId = viewModel.currentAudioTrackId,
           let currentTrack = viewModel.audioTracks.first(where: { $0.id == currentId }) {
            var parts: [String] = []
            if let lang = currentTrack.language {
                parts.append(lang)
            }
            parts.append(currentTrack.audioFormatString)
            return parts.joined(separator: " · ")
        }

        // Fall back to first Plex audio stream displayTitle
        if let audioStream = viewModel.metadata.Media?.first?.Part?.first?.Stream?.first(where: { $0.isAudio }),
           let displayTitle = audioStream.displayTitle {
            return displayTitle
        }

        // Fall back to media-level info
        guard let media = viewModel.metadata.Media?.first else { return nil }
        var parts: [String] = []
        if let codec = media.audioCodec {
            parts.append(codec.uppercased())
        }
        if let channels = media.audioChannels {
            if channels >= 8 { parts.append("7.1") }
            else if channels >= 6 { parts.append("5.1") }
            else if channels == 2 { parts.append("Stereo") }
            else if channels == 1 { parts.append("Mono") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var fileInfoString: String? {
        guard let part = viewModel.metadata.Media?.first?.Part?.first else { return nil }
        var parts: [String] = []

        // Container
        if let container = part.container?.uppercased() {
            parts.append(container)
        }

        // File size (use binary GiB to match Plex display)
        if let size = part.size {
            let gib = Double(size) / 1_073_741_824  // 2^30 bytes
            if gib >= 1 {
                parts.append(String(format: "%.2f GB", gib))
            } else {
                let mib = Double(size) / 1_048_576  // 2^20 bytes
                parts.append(String(format: "%.0f MB", mib))
            }
        }

        // Bitrate
        if let bitrate = viewModel.metadata.Media?.first?.bitrate {
            let mbps = Double(bitrate) / 1000
            parts.append(String(format: "%.1f Mbps", mbps))
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Track Display Formatting

    /// Audio track title: Plex's long-form descriptive title when present
    /// (e.g., "English (AC3 5.1) - Director's Commentary"); otherwise the
    /// synthesized format string ("AAC Stereo", "TrueHD 5.1").
    private func formatAudioTrackTitle(_ track: MediaTrack) -> String {
        track.extendedDisplayTitle ?? track.audioFormatString
    }

    /// Audio track subtitle: language in uppercase (e.g., "ENGLISH")
    private func formatAudioTrackSubtitle(_ track: MediaTrack) -> String {
        track.languageDisplay
    }

    /// Subtitle track title: Plex's long-form descriptive title when
    /// present (already includes "Forced" / "SDH" where applicable);
    /// otherwise the language in uppercase ("ENGLISH") with suffixes
    /// appended.
    private func formatSubtitleTrackTitle(_ track: MediaTrack) -> String {
        if let extended = track.extendedDisplayTitle {
            return extended
        }
        var title = track.languageDisplay
        if track.isForced {
            title += " (Forced)"
        }
        if track.isHearingImpaired {
            title += " (SDH)"
        }
        return title
    }

    /// Subtitle track subtitle: format/codec (e.g., "SRT", "PGS")
    private func formatSubtitleTrackSubtitle(_ track: MediaTrack) -> String {
        track.formattedCodec
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes) min"
    }
}

// MARK: - Info Badge

private struct InfoBadge: View {
    let icon: String
    let text: String
    var highlight: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
            Text(text)
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundStyle(highlight ? .yellow : .white.opacity(0.7))
    }
}

// MARK: - Transport Progress Bar

private struct TransportProgressBar: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    var isScrubbing: Bool = false
    var scrubTime: TimeInterval = 0
    var scrubStepLabel: String?  // YouTube-style step indicator (e.g. "▶▶ 30s")
    var scrubThumbnail: UIImage?
    var markers: [PlexMarker] = []

    private var displayTime: TimeInterval {
        isScrubbing ? scrubTime : currentTime
    }

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, displayTime / duration))
    }

    /// Color for a marker type
    private func markerColor(for marker: PlexMarker) -> Color {
        if marker.isIntro {
            return .blue
        } else if marker.isCredits {
            return .purple
        } else {
            return .yellow  // commercial
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            // Thumbnail preview (above progress bar when scrubbing)
            if isScrubbing, let thumbnail = scrubThumbnail {
                VStack(spacing: 4) {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 240, height: 135)
                        .background(Color.gray.opacity(0.3))  // Debug: see actual image bounds
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(.white.opacity(0.3), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.5), radius: 10, y: 5)

                    Triangle()
                        .fill(.white.opacity(0.8))
                        .frame(width: 12, height: 8)
                }
                .frame(maxWidth: .infinity)
                // Position horizontally based on progress
                .offset(x: (progress - 0.5) * (UIScreen.main.bounds.width - 320))
            }

            // Progress track
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    Capsule()
                        .fill(.white.opacity(0.3))

                    // Progress fill (current position in blue when scrubbing)
                    if isScrubbing {
                        // Show current position as dimmer
                        let currentProgress = duration > 0 ? min(1, max(0, currentTime / duration)) : 0
                        Capsule()
                            .fill(.white.opacity(0.5))
                            .frame(width: max(0, geometry.size.width * currentProgress))
                    }

                    // Scrub/current position fill
                    Capsule()
                        .fill(isScrubbing ? .blue : .white)
                        .frame(width: max(0, geometry.size.width * progress))

                    // Marker highlights (on top of progress bar, only show unplayed portion)
                    if duration > 0 {
                        ForEach(Array(markers.enumerated()), id: \.offset) { _, marker in
                            let startProgress = max(0, marker.startTimeSeconds / duration)
                            let endProgress = min(1, marker.endTimeSeconds / duration)
                            // Only show if marker has valid range
                            if endProgress > startProgress {
                                let markerWidth = max(4, geometry.size.width * (endProgress - startProgress))
                                let markerX = geometry.size.width * startProgress

                                RoundedRectangle(cornerRadius: 2)
                                    .fill(markerColor(for: marker).opacity(0.85))
                                    .frame(width: markerWidth, height: geometry.size.height)
                                    .offset(x: markerX)
                            }
                        }
                    }

                    // Playhead
                    Circle()
                        .fill(isScrubbing ? .blue : .white)
                        .frame(width: isScrubbing ? 24 : 16, height: isScrubbing ? 24 : 16)
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                        .offset(x: max(0, min(geometry.size.width - (isScrubbing ? 24 : 16), geometry.size.width * progress - (isScrubbing ? 12 : 8))))
                        .animation(.easeOut(duration: 0.15), value: isScrubbing)
                }
            }
            .frame(height: isScrubbing ? 10 : 6)
            .animation(.easeOut(duration: 0.15), value: isScrubbing)

            // Time labels (with scrub time and speed below bar when scrubbing)
            HStack {
                if isScrubbing {
                    // Scrub time and speed indicator
                    HStack(spacing: 16) {
                        Text(formatTime(scrubTime))
                            .font(.body)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .foregroundStyle(.blue)

                        if let stepLabel = scrubStepLabel {
                            Text(stepLabel)
                                .font(.callout)
                                .fontWeight(.medium)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                } else {
                    Text(formatTime(displayTime))
                        .font(.caption)
                        .fontWeight(.medium)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }

                Spacer()

                Text("-\(formatTime(max(0, duration - displayTime)))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Playback Settings Row (matches SidebarRow style)

/// Row item for the playback settings list (matches sidebar row styling)
private struct PlaybackSettingsRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    var isFocused: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            // Selection indicator (checkmark for selected items)
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22, weight: .medium))
                .frame(width: 26)

            // Text content
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 24, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 19))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            // Selected indicator dot (like sidebar)
            if isSelected {
                Circle()
                    .fill(.white)
                    .frame(width: 6, height: 6)
            }
        }
        .foregroundStyle(.white.opacity(isFocused || isSelected ? 1.0 : 0.6))
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isFocused ? .white.opacity(0.15) : .clear)
        )
        .padding(.horizontal, 16)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

// MARK: - Triangle Shape (for thumbnail arrow)

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        Text("Video Content")
            .foregroundStyle(.white.opacity(0.3))
    }
}
