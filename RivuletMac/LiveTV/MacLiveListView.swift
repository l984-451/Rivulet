// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// The List layout: categories on the left (recents, favorites, the viewer's lists, pinned
/// groups, then each source's groups) and the chosen category's channels on the right, with
/// what is on and the quality last seen. Also the player's Channels popover. Parity source:
/// RivuletiOS/LiveTV/IOSLiveListView.swift; rows and order are the tvOS List's.
struct MacLiveListView: View {
    enum Mode {
        /// The Live TV page: a click plays, the context menu offers the channel menu.
        case page
        /// The player's Channels popover: a click switches the playing channel.
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
    @Environment(\.dismiss) private var dismiss
    @AppStorage("macLiveListCategory") private var rememberedId = ""
    @State private var model = LiveCategoryList.build(LiveCategoryList.Input(channels: []))
    @State private var selectedId: String?
    @StateObject private var searcher = LiveChannelSearcher()
    /// Counts five-minute steps: For You and the genre rows follow what is on.
    @State private var tick = 0

    private var isPicker: Bool { if case .picker = mode { true } else { false } }
    private var currentId: String? { if case .picker(let current) = mode { current.id } else { nil } }

    private var modelKey: String {
        // The lineup and guide by their change counters (a regroup keeps its size), the time
        // (For You and the genre rows follow what is on), and every other input.
        "\(store.channelsVersion)|\(store.epgVersion)|\(tick)|\(store.favoriteIds.hashValue)|"
            + "\(store.unfavoritedIds.hashValue)|\(store.recentChannelIds.hashValue)|"
            + "\(store.sources.map { "\($0.id)\($0.displayName)" }.hashValue)|"
            + "\(lists.lists.hashValue)|\(lists.pinnedCategoryKeys.hashValue)"
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selectedId) {
                ForEach(model.sections) { section in
                    Section {
                        ForEach(section.rows) { category in
                            LabeledContent {
                                Text(category.channelCount, format: .number).foregroundStyle(.secondary)
                            } label: {
                                Label { Text(verbatim: category.title) } icon: { Image(systemName: icon(for: category)) }
                            }
                            .tag(category.id)
                        }
                    } header: {
                        if let header = section.header { Text(verbatim: header.title) }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: isPicker ? 240 : 280)
            Divider()
            VStack(spacing: 0) {
                TextField("Search Channels", text: $searcher.query)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)
                MacLiveChannelColumn(channels: shownChannels, currentId: currentId, onPick: pick,
                                     menu: menu, canProbe: canProbe)
                    .overlay {
                        if !searcher.query.isEmpty, shownChannels.isEmpty {
                            if searcher.isSearching { ProgressView() } else { ContentUnavailableView.search(text: searcher.query) }
                        }
                    }
            }
        }
        .frame(width: isPicker ? 680 : nil, height: isPicker ? 520 : nil)
        .task(id: modelKey) { rebuild() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                tick += 1
            }
        }
        .onChange(of: selectedId) { _, id in if let id { rememberedId = id; searcher.query = "" } }
        .onDisappear { LiveStreamProber.shared.stop() }
    }

    /// The category's channels, or every channel matching the search.
    private var shownChannels: [UnifiedChannel] {
        guard searcher.query.isEmpty else { return searcher.results }
        return selectedId.map(model.channels(in:)) ?? []
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

/// A category's channels: logo, name, what is on with its progress, what is next and the
/// quality line. Rows on screen have their quality read once they rest there.
struct MacLiveChannelColumn: View {
    let channels: [UnifiedChannel]
    let currentId: String?
    let onPick: (UnifiedChannel) -> Void
    let menu: ((UnifiedChannel) -> [[LiveMenuAction]])?
    let canProbe: () -> Bool
    @ObservedObject private var store = LiveTVDataStore.shared
    @State private var visible: [String: Int] = [:]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            List(Array(channels.enumerated()), id: \.element.id) { index, channel in
                row(channel, now: context.date)
                    .onAppear { visible[channel.id] = index }
                    .onDisappear { visible[channel.id] = nil }
            }
            .listStyle(.inset)
        }
        .task(id: visible.keys.sorted().joined(separator: "\n")) { await probeVisible() }
    }

    private func row(_ channel: UnifiedChannel, now: Date) -> some View {
        let nowNext = LiveNowNext.of(store.epg[channel.id], at: now)
        return Button { onPick(channel) } label: {
            HStack(spacing: 12) {
                MacLiveLogo(url: channel.logoURL).frame(width: 64, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.displayNumberAndName).font(.body.weight(.semibold))
                    if let detail = LiveListText.detail(channel) {
                        Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 160, alignment: .leading)
                Spacer(minLength: 12)
                if let current = nowNext.current {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(current.displayTitle)
                            Spacer(minLength: 6)
                            Text(LiveListText.times(current)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        if let progress = nowNext.progress(at: now) {
                            ProgressView(value: progress).tint(.secondary)
                        }
                        if let next = nowNext.next {
                            Text(LiveListText.next(next)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: 320)
                }
                if channel.id == currentId {
                    Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
                }
            }
            .lineLimit(1)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(channel.id == currentId ? .isSelected : [])
        .contextMenu {
            if let menu { MacLiveMenuContent(sections: menu(channel)) }
        }
    }

    private func probeVisible() async {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, canProbe() else { return }
        let shown = visible.sorted { $0.value < $1.value }.compactMap { entry in
            channels.indices.contains(entry.value) ? channels[entry.value] : nil
        }
        LiveStreamProber.shared.probe(shown, while: canProbe)
    }
}
