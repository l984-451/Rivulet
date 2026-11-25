// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// The List layout: categories (recents, favorites, the viewer's lists, pinned groups, then
/// each source's groups), and a category's channels with what is on and the quality last
/// seen. Two columns on a regular width; on an iPhone, or as the player's Channels sheet,
/// a category opens its channels. The rows and their order are the tvOS List's
/// (`LiveCategoryList`, `LiveListText`).
struct IOSLiveListView: View {
    enum Mode {
        /// The Live TV tab: Select plays, a hold offers the channel menu.
        case tab
        /// The player's Channels sheet: picking switches the playing channel.
        case picker(current: UnifiedChannel)
    }

    let mode: Mode
    let onPick: (UnifiedChannel) -> Void
    var menu: ((UnifiedChannel) -> [[LiveMenuAction]])?
    /// Whether streams may be opened to read their quality: never while one plays.
    var canProbe: () -> Bool = { false }

    @ObservedObject private var store = LiveTVDataStore.shared
    @ObservedObject private var lists = LiveChannelListStore.shared
    @ObservedObject private var quality = LiveStreamQualityStore.shared
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss
    @AppStorage("iosLiveListCategory") private var rememberedId = ""
    @State private var model = LiveCategoryList.build(LiveCategoryList.Input(channels: []))
    @State private var selectedId: String?
    @StateObject private var searcher = LiveChannelSearcher()
    /// Counts five-minute steps: For You and the genre rows follow what is on.
    @State private var tick = 0

    private var isPicker: Bool { if case .picker = mode { true } else { false } }
    private var currentId: String? { if case .picker(let current) = mode { current.id } else { nil } }
    private var twoColumns: Bool { sizeClass == .regular && !isPicker }

    /// What the column depends on; the model is rebuilt only when it changes.
    private var modelKey: String {
        // The lineup and guide by their change counters (a regroup keeps its size), the time
        // (For You and the genre rows follow what is on), and every other input.
        "\(store.channelsVersion)|\(store.epgVersion)|\(tick)|\(store.favoriteIds.hashValue)|"
            + "\(store.unfavoritedIds.hashValue)|\(store.recentChannelIds.hashValue)|"
            + "\(store.sources.map { "\($0.id)\($0.displayName)" }.hashValue)|"
            + "\(lists.lists.hashValue)|\(lists.pinnedCategoryKeys.hashValue)"
    }

    var body: some View {
        // One search field for every state: swapping it as the query fills would drop the keyboard.
        content
            .searchable(text: $searcher.query, prompt: "Channels")
            .navigationDestination(for: IOSLiveCategoryRoute.self) { route in
                if let category = model.category(route.id) { channelColumn(category) }
            }
            .task(id: modelKey) { rebuild() }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(300))
                    tick += 1
                }
            }
            .onChange(of: selectedId) { _, id in if let id, twoColumns { rememberedId = id } }
            .onDisappear { LiveStreamProber.shared.stop() }
    }

    @ViewBuilder
    private var content: some View {
        if !searcher.query.isEmpty {
            searchResults
        } else if twoColumns {
            HStack(spacing: 0) {
                List(selection: $selectedId) { categoryRows(linked: false) }
                    .listStyle(.sidebar)
                    .frame(width: 320)
                Divider()
                if let id = selectedId, let category = model.category(id) {
                    channelColumn(category)
                } else {
                    ContentUnavailableView("No Channels", systemImage: "list.bullet")
                }
            }
        } else {
            List { categoryRows(linked: true) }
        }
    }

    // MARK: Categories

    @ViewBuilder
    private func categoryRows(linked: Bool) -> some View {
        ForEach(model.sections) { section in
            Section {
                ForEach(section.rows) { category in
                    if linked {
                        NavigationLink(value: IOSLiveCategoryRoute(id: category.id)) { categoryLabel(category) }
                    } else {
                        categoryLabel(category).tag(category.id)
                    }
                }
            } header: {
                if let header = section.header { Text(verbatim: header.title) }
            }
        }
    }

    private func categoryLabel(_ category: LiveCategory) -> some View {
        LabeledContent {
            Text(category.channelCount, format: .number)
        } label: {
            Label { Text(verbatim: category.title) } icon: { Image(systemName: icon(for: category)) }
        }
    }

    private func icon(for category: LiveCategory) -> String {
        switch category.kind {
        case .recent: "clock"
        case .forYou: "sparkles"
        case .onNow(let genre): genre.symbolName
        case .favorites: "star"
        case .all: "square.grid.2x2"
        case .list(let id): lists.list(id)?.isSmart == true ? "gearshape.2" : "list.bullet"
        case .group: category.id.hasPrefix("pin|") ? "pin" : "folder"
        case .sourceHeader: "antenna.radiowaves.left.and.right"
        }
    }

    // MARK: Channels

    private func channelColumn(_ category: LiveCategory) -> some View {
        IOSLiveChannelColumn(channels: model.channels(in: category.id), currentId: currentId,
                             onPick: pick, menu: menu, canProbe: canProbe)
            .navigationTitle(Text(verbatim: category.title))
    }

    private var searchResults: some View {
        IOSLiveChannelColumn(channels: searcher.results, currentId: currentId, onPick: pick, menu: menu,
                             canProbe: canProbe)
            .overlay {
                if searcher.isSearching, searcher.results.isEmpty {
                    ProgressView()
                } else if searcher.results.isEmpty {
                    ContentUnavailableView.search(text: searcher.query)
                }
            }
    }

    private func pick(_ channel: UnifiedChannel) {
        onPick(channel)
        if isPicker { dismiss() }
    }

    private func rebuild() {
        model = store.liveCategoryList(sourceIdFilter: nil)
        if selectedId == nil || model.category(selectedId ?? "") == nil {
            selectedId = model.startingCategoryId(remembered: rememberedId.isEmpty ? nil : rememberedId)
        }
    }
}

struct IOSLiveCategoryRoute: Hashable {
    let id: String
}

/// A category's channels: logo, name, what is on with its progress, and the quality line.
/// Rows on screen have their stream quality read once they rest there (`LiveStreamProber`).
struct IOSLiveChannelColumn: View {
    let channels: [UnifiedChannel]
    let currentId: String?
    let onPick: (UnifiedChannel) -> Void
    let menu: ((UnifiedChannel) -> [[LiveMenuAction]])?
    let canProbe: () -> Bool
    @ObservedObject private var store = LiveTVDataStore.shared
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var visible: [String: Int] = [:]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            List(Array(channels.enumerated()), id: \.element.id) { index, channel in
                row(channel, now: context.date)
                    .onAppear { visible[channel.id] = index }
                    .onDisappear { visible[channel.id] = nil }
            }
            .listStyle(.plain)
        }
        .task(id: visible.keys.sorted().joined(separator: "\n")) { await probeVisible() }
    }

    private func row(_ channel: UnifiedChannel, now: Date) -> some View {
        let nowNext = LiveNowNext.of(store.epg[channel.id], at: now)
        return Button { onPick(channel) } label: {
            HStack(spacing: 12) {
                IOSLiveLogo(url: channel.logoURL)
                    .frame(width: 64, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(channel.displayNumberAndName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let current = nowNext.current {
                        Text(current.displayTitle).font(.subheadline).foregroundStyle(.primary)
                        if let progress = nowNext.progress(at: now) {
                            ProgressView(value: progress)
                                .tint(.secondary)
                                .frame(maxWidth: 180)
                                .accessibilityLabel(LiveListText.times(current))
                        }
                    }
                    if sizeClass == .regular, let next = nowNext.next {
                        Text(LiveListText.next(next)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let detail = LiveListText.detail(channel) {
                        Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                if channel.id == currentId {
                    Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(channel.id == currentId ? .isSelected : [])
        .contextMenu {
            if let menu { IOSLiveMenuContent(sections: menu(channel)) }
        }
    }

    /// Once the rows on screen have rested a second, read their quality in screen order.
    private func probeVisible() async {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, canProbe() else { return }
        let shown = visible.sorted { $0.value < $1.value }.compactMap { entry in
            channels.indices.contains(entry.value) ? channels[entry.value] : nil
        }
        LiveStreamProber.shared.probe(shown, while: canProbe)
    }
}
