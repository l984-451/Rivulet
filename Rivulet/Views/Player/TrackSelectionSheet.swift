// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TrackSelectionSheet.swift
//  Rivulet
//
//  Sheet for selecting audio and subtitle tracks with Liquid Glass styling
//

import SwiftUI

enum TrackType {
    case audio
    case subtitles

    var title: String {
        switch self {
        case .audio: return String(localized: "Audio")
        case .subtitles: return String(localized: "Subtitles")
        }
    }

    var icon: String {
        switch self {
        case .audio: return "speaker.wave.3"
        case .subtitles: return "captions.bubble"
        }
    }
}

struct TrackSelectionSheet: View {
    let trackType: TrackType
    let tracks: [MediaTrack]
    let selectedTrackId: Int?
    let onSelect: (Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedTrackId: Int?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    // "Off" option for subtitles
                    if trackType == .subtitles {
                        TrackRow(
                            name: String(localized: "Off"),
                            subtitle: nil,
                            isSelected: selectedTrackId == nil,
                            isFocused: focusedTrackId == -1
                        )
                        .focusable()
                        .focused($focusedTrackId, equals: -1)
                        .onTapGesture {
                            onSelect(nil)
                            dismiss()
                        }
                        .onPlayPauseCommand {
                            onSelect(nil)
                            dismiss()
                        }
                    }

                    // Track options
                    ForEach(tracks) { track in
                        TrackRow(
                            name: track.displayName,
                            subtitle: trackSubtitle(for: track),
                            isSelected: track.id == selectedTrackId,
                            isFocused: focusedTrackId == track.id
                        )
                        .focusable()
                        .focused($focusedTrackId, equals: track.id)
                        .onTapGesture {
                            onSelect(track.id)
                            dismiss()
                        }
                        .onPlayPauseCommand {
                            onSelect(track.id)
                            dismiss()
                        }
                    }
                }
                .padding(24)
            }
            .navigationTitle(trackType.title)
        }
        .onAppear {
            // Focus the selected track
            if trackType == .subtitles && selectedTrackId == nil {
                focusedTrackId = -1
            } else {
                focusedTrackId = selectedTrackId ?? tracks.first?.id
            }
        }
        .onExitCommand {
            dismiss()
        }
    }

    private func trackSubtitle(for track: MediaTrack) -> String? {
        var components: [String] = []

        if let language = track.language {
            components.append(language)
        }
        if let codec = track.codec {
            components.append(codec.uppercased())
        }

        return components.isEmpty ? nil : components.joined(separator: " • ")
    }
}

// MARK: - Track Row

private struct TrackRow: View {
    let name: String
    let subtitle: String?
    let isSelected: Bool
    let isFocused: Bool

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)

                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isFocused ? .white.opacity(0.2) : .white.opacity(0.08))
        )
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

#Preview {
    TrackSelectionSheet(
        trackType: .subtitles,
        tracks: [
            MediaTrack(id: 1, name: "English", language: "English", codec: "srt", isDefault: true),
            MediaTrack(id: 2, name: "Spanish", language: "Spanish", codec: "ass"),
            MediaTrack(id: 3, name: "French (SDH)", language: "French", codec: "pgs", isHearingImpaired: true)
        ],
        selectedTrackId: 1,
        onSelect: { id in
        }
    )
}
