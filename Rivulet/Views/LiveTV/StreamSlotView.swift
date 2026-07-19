// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  StreamSlotView.swift
//  Rivulet
//
//  Individual player slot for multi-stream view
//

import SwiftUI

struct StreamSlotView: View {
    let slot: MultiStreamViewModel.StreamSlot
    let index: Int
    let isFocused: Bool
    var showBorder: Bool = true
    var showChannelBadge: Bool = true

    private var streamURL: URL? {
        LiveTVDataStore.shared.buildStreamURL(for: slot.channel)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Background
            Color.black

            if let _ = streamURL {
                playerView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .transaction { transaction in
                        // Disable animations for the player to prevent layout issues during resize
                        transaction.animation = nil
                    }
            }

            // Focus border (only in grid mode)
            if isFocused && showBorder {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white, lineWidth: 4)
                    .shadow(color: .white.opacity(0.3), radius: 8)
            }

            // Mini channel badge (only in grid mode, controlled by showChannelBadge)
            if showBorder && showChannelBadge {
                VStack {
                    Spacer()
                    HStack {
                        miniChannelBadge
                        Spacer()
                    }
                }
                .padding(12)
                .transition(.opacity)
            }

            // Muted indicator (top-right, when not focused, always visible in grid mode)
            if showBorder && slot.isMuted && !isFocused {
                VStack {
                    HStack {
                        Spacer()
                        mutedIndicator
                    }
                    Spacer()
                }
                .padding(12)
            }

            // Loading/buffering overlay
            if slot.playbackState == .loading || slot.playbackState == .buffering {
                loadingOverlay
            }

            // Error overlay
            if case .failed = slot.playbackState {
                errorOverlay
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: showBorder ? 8 : 0, style: .continuous))
    }

    // MARK: - Player View

    @ViewBuilder
    private var playerView: some View {
        if streamURL != nil {
            AetherSlotPlayerView(player: slot.aetherPlayer)
        }
    }

    // MARK: - Mini Channel Badge

    private var miniChannelBadge: some View {
        HStack(spacing: 8) {
            // Channel logo or icon
            if let logoURL = slot.channel.logoURL {
                AsyncImage(url: logoURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 24)
                    default:
                        channelIcon
                    }
                }
            } else {
                channelIcon
            }

            // Channel number and name
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if let number = slot.channel.channelNumber {
                        Text("\(number)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Text(slot.channel.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }

                // Current program (if available)
                if let program = slot.currentProgram {
                    Text(program.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.black.opacity(0.7))
        )
    }

    private var channelIcon: some View {
        Image(systemName: "tv")
            .font(.system(size: 16))
            .foregroundStyle(.white.opacity(0.6))
            .frame(width: 24, height: 24)
    }

    // MARK: - Muted Indicator

    private var mutedIndicator: some View {
        Image(systemName: "speaker.slash.fill")
            .font(.system(size: 16))
            .foregroundStyle(.white)
            .padding(8)
            .background(
                Circle()
                    .fill(.black.opacity(0.6))
            )
    }

    // MARK: - Loading Overlay

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.3)

            ProgressView()
                .scaleEffect(1.2)
                .tint(.white)
        }
    }

    // MARK: - Error Overlay

    private var errorOverlay: some View {
        ZStack {
            Color.black.opacity(0.8)

            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.yellow)

                Text("Stream Error")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)

                // Show error details if available
                if let errorMessage = extractErrorMessage() {
                    Text(errorMessage)
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .lineLimit(4)
                }
            }
            .padding(24)
        }
    }

    /// Extracts error message from the playback state
    private func extractErrorMessage() -> String? {
        if case .failed(let error) = slot.playbackState {
            switch error {
            case .invalidURL:
                return "Invalid stream URL"
            case .loadFailed(let message):
                return message
            case .networkError(let message):
                return message
            case .codecUnsupported(let message):
                return message
            case .unknown(let message):
                return message
            }
        }
        return nil
    }
}

#Preview {
    StreamSlotView(
        slot: MultiStreamViewModel.StreamSlot(
            channel: UnifiedChannel(
                id: "test",
                sourceType: .dispatcharr,
                sourceId: "test-source",
                channelNumber: 101,
                name: "Test Channel HD",
                callSign: "TEST",
                logoURL: nil,
                streamURL: URL(string: "http://example.com/stream.m3u8")!,
                tvgId: nil,
                groupTitle: "Entertainment",
                isHD: true
            ),
            aetherPlayer: AetherPlayer(),
            timelineReporter: nil,
            playbackState: .loading,
            isMuted: false
        ),
        index: 0,
        isFocused: true
    )
    .frame(width: 400, height: 300)
}
