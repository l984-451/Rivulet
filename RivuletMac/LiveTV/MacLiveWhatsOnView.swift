// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Combine
import SwiftUI

/// Stored once so `.onReceive` keeps one subscription; a fresh publisher per render resubscribes and loops.
@MainActor
private enum MacLiveWhatsOnFeed {
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

/// What's On: Home-style rails of 16:9 cards, one per shelf.
struct MacLiveWhatsOnView<Header: View>: View {
    let onWatch: (UnifiedChannel) -> Void
    let onDetails: (LiveProgrammeSelection) -> Void
    @ViewBuilder let header: () -> Header
    @EnvironmentObject private var recorder: LiveRecorder
    @ObservedObject private var store = LiveTVDataStore.shared
    @State private var shelves: [LiveShelf] = []
    @State private var now = Date()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                header()
                ForEach(shelves) { shelf in
                    MacLiveRail(title: shelf.title, items: shelf.items) { item, width in
                        card(item, width: width)
                    }
                }
            }
            .padding(.vertical, 16)
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
        .onReceive(MacLiveWhatsOnFeed.changes) { rebuild() }
        .onReceive(MacLiveWhatsOnFeed.tick) { _ in rebuild() }
    }

    private func rebuild() {
        now = Date()
        shelves = LiveTVDataStore.shared.whatsOnShelves(sourceIdFilter: nil, now: now).filter { !$0.items.isEmpty }
    }

    @ViewBuilder
    private func card(_ item: LiveCardItem, width: CGFloat) -> some View {
        let tile = MacLiveCard(item: item, now: now, width: width)
        switch item.kind {
        case .recording:
            NavigationLink(value: MacRoute.liveRecordings) { tile }
                .buttonStyle(.plain)
        case .channel, .upcoming:
            if let channel = item.channel {
                Button {
                    if item.kind == .channel {
                        onWatch(channel)
                    } else {
                        onDetails(LiveProgrammeSelection(channel: channel, program: item.program))
                    }
                } label: { tile }
                .buttonStyle(.plain)
                .contextMenu {
                    MacLiveMenuContent(sections: LiveMenu.sections(
                        channel: channel, program: item.program, recorder: recorder,
                        watch: onWatch, details: onDetails
                    ))
                }
            }
        }
    }
}

/// A row of cards under a title, with chevrons that page it for a mouse.
private struct MacLiveRail<Tile: View>: View {
    let title: String
    let items: [LiveCardItem]
    @ViewBuilder let tile: (LiveCardItem, CGFloat) -> Tile
    @State private var leading = 0

    private let width: CGFloat = 280

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).font(.title3.bold())
                    Spacer()
                    HStack(spacing: 4) {
                        Button { page(proxy, by: -3) } label: { Image(systemName: "chevron.left") }
                            .disabled(leading == 0)
                            .accessibilityLabel("Previous")
                        Button { page(proxy, by: 3) } label: { Image(systemName: "chevron.right") }
                            .disabled(leading + 3 >= items.count)
                            .accessibilityLabel("Next")
                    }
                    .buttonStyle(.borderless)
                    .opacity(items.count > 3 ? 1 : 0)
                }
                .padding(.horizontal, MacMetrics.pageMargin)
                .accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: MacMetrics.tileGap) {
                        ForEach(items) { tile($0, width).id($0.id) }
                    }
                    .padding(.vertical, 6)
                }
                .contentMargins(.horizontal, MacMetrics.pageMargin, for: .scrollContent)
                .scrollIndicators(.hidden)
            }
        }
    }

    private func page(_ proxy: ScrollViewProxy, by step: Int) {
        leading = min(max(0, leading + step), max(0, items.count - 1))
        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(items[leading].id, anchor: .leading) }
    }
}

/// One 16:9 card: art (or the logo on a soft field), pills, progress, then two lines of text.
struct MacLiveCard: View {
    let item: LiveCardItem
    let now: Date
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MacLiveCardArt(item: item, now: now)
                .frame(width: width, height: width * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .macTileHover()
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.footnote.weight(.semibold)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, detail].joined(separator: ", "))
        .accessibilityValue(accessibilityState)
        .accessibilityHint(item.kind == .channel ? String(localized: "Plays the channel") : "")
    }

    private var title: String {
        item.program?.displayTitle ?? item.recording?.title ?? item.channel?.name ?? ""
    }

    private var detail: String {
        if let channel = item.channel { return channel.numberAndName }
        return item.recording?.channelName ?? ""
    }

    /// The hover tooltip stands in for iOS's long-press preview.
    private var helpText: String {
        guard let program = item.program else { return title }
        let description = program.description.flatMap { $0.isEmpty ? nil : String($0.prefix(240)) }
        return [title, [program.timeRange, item.channel?.numberAndName].compactMap { $0 }.joined(separator: " · "), description]
            .compactMap { $0 }.joined(separator: "\n")
    }

    private var accessibilityState: String {
        var parts: [String] = []
        if let program = item.program {
            if item.kind == .upcoming {
                parts.append(String(localized: "Starts \(LiveCardItem.startLabel(program, now: now))"))
            } else if program.isLiveAiring {
                parts.append(String(localized: "Live"))
            }
        }
        if item.setToRecord || item.recording?.status == .recording { parts.append(String(localized: "Recording")) }
        return parts.joined(separator: ", ")
    }
}

/// The card's picture with its pills and progress bar.
private struct MacLiveCardArt: View {
    let item: LiveCardItem
    let now: Date
    @State private var wideArt: URL?

    private var program: UnifiedProgram? { item.program }
    private var art: URL? { wideArt ?? item.recording?.posterURL }

    var body: some View {
        ZStack {
            if let art { MacImage(url: art) } else { logoField }
        }
        .overlay(alignment: .topLeading) {
            if art != nil, let logo = item.channel?.logoURL {
                MacLiveLogo(url: logo)
                    .frame(maxWidth: 56, maxHeight: 24, alignment: .leading)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                    .padding(10)
            }
        }
        .overlay(alignment: .topTrailing) { pill.padding(8) }
        .overlay(alignment: .bottom) { progress }
        .modifier(MacLiveWideArt(program: program, url: $wideArt))
    }

    /// The channel logo large over a blurred, darkened field made from whatever art there is.
    private var logoField: some View {
        let source = program?.posterURL ?? program?.iconURL ?? item.channel?.logoURL
        return ZStack {
            Color(white: 0.16)
            MacImage(url: source).blur(radius: 28).saturation(1.3).opacity(0.7)
            Color.black.opacity(0.2)
            MacLiveLogo(url: item.channel?.logoURL)
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
                MacLivePill(text: String(localized: "REC"), dot: true, style: .red)
            } else if program?.isLiveAiring == true {
                MacLivePill(text: String(localized: "LIVE"), dot: false, style: .red)
            }
        case .upcoming:
            if let program {
                MacLivePill(text: LiveCardItem.startLabel(program, now: now), dot: item.setToRecord, style: .glass)
            }
        case .recording:
            if let recording = item.recording {
                if recording.status == .recording {
                    MacLivePill(text: String(localized: "REC"), dot: true, style: .red)
                } else {
                    MacLivePill(text: recording.startTime.formatted(.dateTime.weekday().hour().minute()),
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
