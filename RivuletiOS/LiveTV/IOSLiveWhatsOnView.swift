// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Combine
import SwiftUI

/// Stored once so `.onReceive` keeps one subscription; a fresh publisher per render resubscribes and loops.
@MainActor
private enum IOSLiveWhatsOnFeed {
    static let changes: AnyPublisher<Void, Never> = {
        let store = LiveTVDataStore.shared
        return Publishers.Merge4(
            store.$channels.map { _ in () },
            store.$epg.map { _ in () },
            store.$scheduledRecordings.map { _ in () },
            store.$favoriteIds.map { _ in () }
        )
        .merge(with: NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).map { _ in () })
        .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
        .eraseToAnyPublisher()
    }()
    static let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
}

/// What's On: the tvOS rows as Home-style rails of 16:9 cards.
struct IOSLiveWhatsOnView<Header: View>: View {
    let onWatch: (UnifiedChannel) -> Void
    let onDetails: (IOSLiveProgrammeSelection) -> Void
    @ViewBuilder let header: () -> Header
    @EnvironmentObject private var recorder: IOSLiveRecorder
    @ObservedObject private var store = LiveTVDataStore.shared
    @State private var shelves: [LiveShelf] = []
    @State private var now = Date()

    init(onWatch: @escaping (UnifiedChannel) -> Void,
         onDetails: @escaping (IOSLiveProgrammeSelection) -> Void,
         @ViewBuilder header: @escaping () -> Header) {
        self.onWatch = onWatch
        self.onDetails = onDetails
        self.header = header
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                header()
                ForEach(shelves) { shelf in
                    row(shelf)
                }
            }
            .padding(.bottom, 24)
        }
        .overlay {
            if shelves.isEmpty {
                if store.isLoadingEPG || store.isLoadingChannels {
                    ProgressView()
                } else {
                    ContentUnavailableView("Nothing On Right Now", systemImage: "tv",
                                           description: Text("Try the Guide to see what's coming up."))
                }
            }
        }
        .onAppear(perform: rebuild)
        .onReceive(IOSLiveWhatsOnFeed.changes) { rebuild() }
        .onReceive(IOSLiveWhatsOnFeed.tick) { _ in rebuild() }
    }

    private func rebuild() {
        now = Date()
        shelves = LiveTVDataStore.shared.whatsOnShelves(sourceIdFilter: nil, now: now).filter { !$0.items.isEmpty }
    }

    private func row(_ shelf: LiveShelf) -> some View {
        IOSShelfRow(kind: .landscape, items: shelf.items) {
            IOSPlexShelfHeader(title: shelf.title)
        } tile: { item, width in
            card(item, width: width)
        }
    }

    @ViewBuilder
    private func card(_ item: LiveCardItem, width: CGFloat) -> some View {
        let tile = IOSLiveCard(item: item, now: now, width: width)
        switch item.kind {
        case .recording:
            NavigationLink(value: IOSLiveRoute.recordings) { tile }
                .buttonStyle(.plain)
        case .channel, .upcoming:
            if let channel = item.channel {
                Button {
                    if item.kind == .channel {
                        onWatch(channel)
                    } else {
                        onDetails(IOSLiveProgrammeSelection(channel: channel, program: item.program))
                    }
                } label: { tile }
                .buttonStyle(.plain)
                .contextMenu {
                    IOSLiveMenuContent(sections: IOSLiveMenu.sections(
                        channel: channel, program: item.program, recorder: recorder,
                        watch: onWatch, details: onDetails
                    ))
                } preview: {
                    IOSLiveCardPreview(item: item, now: now)
                }
            }
        }
    }
}

/// One 16:9 card: art (or the logo on a soft field), pills, progress, then two lines of text.
struct IOSLiveCard: View {
    let item: LiveCardItem
    let now: Date
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            IOSLiveCardArt(item: item, now: now)
                .frame(width: width, height: width * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, detail].joined(separator: ", "))
        .accessibilityValue(accessibilityState)
        .accessibilityHint(item.kind == .channel ? "Plays the channel" : "")
    }

    private var title: String {
        item.program?.displayTitle ?? item.recording?.title ?? item.channel?.name ?? ""
    }

    private var detail: String {
        if let channel = item.channel { return channel.numberAndName }
        return item.recording?.channelName ?? ""
    }

    private var accessibilityState: String {
        var parts: [String] = []
        if let program = item.program {
            if item.kind == .upcoming {
                parts.append("Starts \(LiveCardItem.startLabel(program, now: now))")
            } else if program.isLiveAiring {
                parts.append("Live")
            }
        }
        if item.setToRecord || item.recording?.status == .recording { parts.append("Recording") }
        return parts.joined(separator: ", ")
    }
}

/// The card's picture with its pills and progress bar.
private struct IOSLiveCardArt: View {
    let item: LiveCardItem
    let now: Date
    @State private var wideArt: URL?

    private var program: UnifiedProgram? { item.program }
    private var art: URL? { wideArt ?? item.recording?.posterURL }

    var body: some View {
        ZStack {
            if let art {
                IOSPlexImage(url: art)
            } else {
                logoField
            }
        }
        .overlay(alignment: .topLeading) {
            if art != nil, let logo = item.channel?.logoURL {
                IOSLiveLogo(url: logo)
                    .frame(maxWidth: 56, maxHeight: 24, alignment: .leading)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                    .padding(10)
            }
        }
        .overlay(alignment: .topTrailing) { pill.padding(8) }
        .overlay(alignment: .bottom) { progress }
        .modifier(IOSLiveWideArt(program: program, url: $wideArt))
    }

    /// The channel logo large over a blurred, darkened field made from whatever art there is.
    private var logoField: some View {
        let source = program?.posterURL ?? program?.iconURL ?? item.channel?.logoURL
        return ZStack {
            Color(white: 0.16)
            IOSPlexImage(url: source)
                .blur(radius: 28)
                .saturation(1.3)
                .opacity(0.7)
            Color.black.opacity(0.2)
            IOSLiveLogo(url: item.channel?.logoURL)
                .environment(\.colorScheme, .dark)
                .padding(.horizontal, 36)
                .padding(.vertical, 30)
            if item.channel?.logoURL == nil {
                Text(item.channel?.name ?? item.recording?.channelName ?? "")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
    }

    @ViewBuilder
    private var pill: some View {
        switch item.kind {
        case .channel:
            if item.setToRecord {
                IOSLivePill(text: "REC", dot: true, style: .red)
            } else if program?.isLiveAiring == true {
                IOSLivePill(text: "LIVE", dot: false, style: .red)
            }
        case .upcoming:
            if let program {
                IOSLivePill(text: LiveCardItem.startLabel(program, now: now), dot: item.setToRecord, style: .glass)
            }
        case .recording:
            if let recording = item.recording {
                if recording.status == .recording {
                    IOSLivePill(text: "REC", dot: true, style: .red)
                } else {
                    IOSLivePill(text: recording.startTime.formatted(.dateTime.weekday().hour().minute()),
                                dot: true, style: .glass)
                }
            }
        }
    }

    @ViewBuilder
    private var progress: some View {
        if item.kind == .channel, let program, program.startTime <= now, program.endTime > now {
            let fraction = now.timeIntervalSince(program.startTime) / program.endTime.timeIntervalSince(program.startTime)
            GeometryReader { proxy in
                Capsule().fill(.white.opacity(0.3))
                    .overlay(alignment: .leading) {
                        Capsule().fill(.white).frame(width: proxy.size.width * fraction)
                    }
            }
            .frame(height: 3)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .shadow(color: .black.opacity(0.4), radius: 2)
            .accessibilityHidden(true)
        }
    }
}

struct IOSLivePill: View {
    enum Style { case red, glass }
    let text: String
    let dot: Bool
    let style: Style

    var body: some View {
        HStack(spacing: 4) {
            if dot {
                Circle()
                    .fill(style == .red ? Color.white : Color.red)
                    .frame(width: 6, height: 6)
            }
            Text(text)
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            if style == .red {
                Capsule().fill(.red)
            } else {
                Capsule().fill(.black.opacity(0.45))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The long-press preview: the card larger, with the description.
private struct IOSLiveCardPreview: View {
    let item: LiveCardItem
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IOSLiveCardArt(item: item, now: now)
                .frame(width: 340, height: 340 * 9 / 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.program?.displayTitle ?? item.channel?.name ?? "")
                    .font(.headline)
                if let program = item.program {
                    Text([program.timeRange, item.channel?.numberAndName].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let description = program.description, !description.isEmpty {
                        Text(description)
                            .font(.subheadline)
                            .lineLimit(4)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(width: 340)
    }
}
