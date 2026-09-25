// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ChannelPickerSheet.swift
//  Rivulet
//
//  Modal sheet for selecting a channel to add to multi-stream view
//  Adapts layout based on user's Live TV layout preference
//

import SwiftUI

struct ChannelPickerSheet: View {
    let excludedChannelIds: Set<String>
    let onSelect: (UnifiedChannel) -> Void
    let onDismiss: () -> Void

    @StateObject private var dataStore = LiveTVDataStore.shared
    @AppStorage("liveTVLayout") private var liveTVLayoutRaw = "Guide"
    @State private var searchText = ""
    @FocusState private var focusedChannelId: String?

    private var layout: LiveTVLayout {
        LiveTVLayout(rawValue: liveTVLayoutRaw) ?? .guide
    }

    private var availableChannels: [UnifiedChannel] {
        dataStore.channels.filter { !excludedChannelIds.contains($0.id) }
    }

    private var filteredChannels: [UnifiedChannel] {
        if searchText.isEmpty {
            return availableChannels
        }
        let query = searchText.lowercased()
        return availableChannels.filter { channel in
            channel.name.lowercased().contains(query) ||
            (channel.callSign?.lowercased().contains(query) ?? false) ||
            (channel.channelNumber.map { String($0).contains(query) } ?? false)
        }
    }

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            // Sheet content
            VStack(spacing: 0) {
                // Header with close button
                header
                    .padding(.horizontal, 40)
                    .padding(.top, 30)
                    .padding(.bottom, 16)

                // Content based on layout preference
                switch layout {
                case .channels, .browse:
                    channelGridContent
                case .guide:
                    guideListContent
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(white: 0.12))
            )
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
        }
        .onAppear {
            // Focus the first channel on appear
            if let firstChannel = filteredChannels.first {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    focusedChannelId = firstChannel.id
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add Channel")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)

                Text("\(availableChannels.count) channels available")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            // Close button
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.card)
        }
    }

    // MARK: - Channel Grid Content (for Channels layout)

    private var channelGridContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: gridColumns, spacing: 12) {
                ForEach(filteredChannels) { channel in
                    PickerChannelCard(
                        channel: channel,
                        isFocused: focusedChannelId == channel.id
                    ) {
                        onSelect(channel)
                    }
                    .focused($focusedChannelId, equals: channel.id)
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
    }

    private var gridColumns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 400, maximum: 500), spacing: 16)
        ]
    }

    // MARK: - Guide List Content (for Guide layout)

    private var guideListContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 2) {
                ForEach(filteredChannels) { channel in
                    PickerGuideRow(
                        channel: channel,
                        isFocused: focusedChannelId == channel.id
                    ) {
                        onSelect(channel)
                    }
                    .focused($focusedChannelId, equals: channel.id)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
    }
}

// MARK: - Picker Guide Row (for Guide layout)

private struct PickerGuideRow: View {
    let channel: UnifiedChannel
    let isFocused: Bool
    let action: () -> Void

    @StateObject private var dataStore = LiveTVDataStore.shared

    private var currentProgram: UnifiedProgram? {
        dataStore.getCurrentProgram(for: channel)
    }

    private let channelColumnWidth: CGFloat = 140  // Narrower for vertical layout
    private let rowHeight: CGFloat = 110  // Taller for better readability

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                // Channel info column (left side) - logo on top, name below
                channelInfo
                    .frame(width: channelColumnWidth)

                // Current program (right side)
                programInfo
                    .frame(maxWidth: .infinity)

                // Add indicator
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(isFocused ? .green : .white.opacity(0.3))
                    .padding(.trailing, 24)
            }
            .frame(height: rowHeight)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isFocused ? .white.opacity(0.15) : .white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isFocused ? .white.opacity(0.5) : .clear, lineWidth: 3)
            )
        }
        .buttonStyle(PickerGuideRowButtonStyle(isFocused: isFocused))
    }

    // MARK: - Channel Info (vertical layout - logo on top, name below)

    private var channelInfo: some View {
        VStack(spacing: 6) {
            // Channel logo
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(white: 0.15))

                if let logoURL = channel.logoURL {
                    AsyncImage(url: logoURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .padding(8)
                        default:
                            channelPlaceholder
                        }
                    }
                } else {
                    channelPlaceholder
                }
            }
            .frame(width: 80, height: 50)

            // Channel number and name stacked
            VStack(spacing: 2) {
                if let number = channel.channelNumber {
                    Text("\(number)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                }

                Text(channel.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 8)
        .background(Color(white: 0.08))
    }

    private var channelPlaceholder: some View {
        Image(systemName: "tv")
            .font(.system(size: 22, weight: .light))
            .foregroundStyle(.white.opacity(0.3))
    }

    // MARK: - Program Info

    private var programInfo: some View {
        HStack(spacing: 0) {
            if let program = currentProgram {
                VStack(alignment: .leading, spacing: 6) {
                    // Program title - larger font
                    Text(program.title)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    // Time info
                    HStack(spacing: 12) {
                        // Time range - larger font
                        Text(formatTimeRange(program))
                            .font(.system(size: 18))
                            .foregroundStyle(.white.opacity(0.5))

                        // Progress indicator - wider
                        if let progress = programProgress(program) {
                            ProgressView(value: progress)
                                .progressViewStyle(LinearProgressViewStyle(tint: .red))
                                .frame(width: 120)
                        }

                        // HD badge - larger
                        if channel.isHD {
                            Text("HD")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(.white.opacity(0.85))
                                )
                        }
                    }

                    // Description if available - larger font
                    if let desc = program.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 20)
            } else {
                // No program info
                VStack(alignment: .leading, spacing: 6) {
                    Text(channel.callSign ?? "No Program Info")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.5))

                    if channel.isHD {
                        Text("HD")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(.white.opacity(0.85))
                            )
                    }
                }
                .padding(.horizontal, 20)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Helpers

    private func formatTimeRange(_ program: UnifiedProgram) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return "\(formatter.string(from: program.startTime)) - \(formatter.string(from: program.endTime))"
    }

    private func programProgress(_ program: UnifiedProgram) -> Double? {
        let now = Date()
        guard program.startTime <= now && program.endTime > now else { return nil }
        let total = program.endTime.timeIntervalSince(program.startTime)
        let elapsed = now.timeIntervalSince(program.startTime)
        return elapsed / total
    }
}

// MARK: - Picker Guide Row Button Style

private struct PickerGuideRowButtonStyle: ButtonStyle {
    let isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(isFocused ? 1.01 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

// MARK: - Picker Channel Card (for Channels layout)

private struct PickerChannelCard: View {
    let channel: UnifiedChannel
    let isFocused: Bool
    let action: () -> Void

    @StateObject private var dataStore = LiveTVDataStore.shared

    private var currentProgram: UnifiedProgram? {
        dataStore.getCurrentProgram(for: channel)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                // Logo
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(white: 0.2))

                    if let logoURL = channel.logoURL {
                        AsyncImage(url: logoURL) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .padding(8)
                            default:
                                channelPlaceholder
                            }
                        }
                    } else {
                        channelPlaceholder
                    }
                }
                .frame(width: 70, height: 52)

                // Info - takes all available space
                VStack(alignment: .leading, spacing: 4) {
                    // Channel number and name
                    HStack(spacing: 8) {
                        if let number = channel.channelNumber {
                            Text("\(number)")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(minWidth: 30, alignment: .leading)
                        }

                        Text(channel.name)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if channel.isHD {
                            Text("HD")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(.white.opacity(0.9))
                                )
                        }
                    }

                    // Program info
                    if let program = currentProgram {
                        Text(program.title)
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    } else if let callSign = channel.callSign {
                        Text(callSign)
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                // Add indicator
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(isFocused ? .green : .white.opacity(0.3))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isFocused ? .white.opacity(0.15) : .white.opacity(0.05))
            )
        }
        .buttonStyle(PickerCardButtonStyle(isFocused: isFocused))
    }

    private var channelPlaceholder: some View {
        Image(systemName: "tv")
            .font(.system(size: 20, weight: .light))
            .foregroundStyle(.white.opacity(0.3))
    }
}

// MARK: - Picker Card Button Style

private struct PickerCardButtonStyle: ButtonStyle {
    let isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

#Preview {
    ChannelPickerSheet(
        excludedChannelIds: [],
        onSelect: { _ in },
        onDismiss: {}
    )
}
