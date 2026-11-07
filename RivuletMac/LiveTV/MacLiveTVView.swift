// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// Live TV: What's On or the Guide over every configured source, recordings, add-source.
/// Parity source: RivuletiOS/LiveTV/ (IOSLiveTVView and friends). Shared logic is in
/// RivuletCore/LiveTV (LiveClient.swift, LiveTVDataStore).
struct MacLiveTVView: View {
    @ObservedObject private var store = LiveTVDataStore.shared
    @StateObject private var recorder = LiveRecorder()
    @AppStorage(LiveLayout.storageKey) private var layoutRaw = LiveLayout.browse.rawValue
    @AppStorage("macLiveTVGuideFilter") private var guideFilter = ""
    @State private var selection: LiveProgrammeSelection?
    @State private var pendingPlay: UnifiedChannel?
    @State private var jumpToken = 0
    @State private var dismissedIssues = ""
    @EnvironmentObject private var playback: MacPlaybackController

    private static let favoritesFilter = "Favorites"

    private var layout: LiveLayout { LiveLayout(rawValue: layoutRaw) ?? .browse }
    private var showsToolbar: Bool { store.hasConfiguredSources && !store.channels.isEmpty }

    var body: some View {
        content
            .navigationTitle("Live TV")
            .toolbar { toolbar }
            .macPageRefresh { Task { await reloadEverything() } }
            .sheet(item: $selection, onDismiss: playPending) { selection in
                MacLiveProgrammeSheet(selection: selection) { pendingPlay = $0 }
            }
            .liveRecorder(recorder)
            .environmentObject(recorder)
            .task(id: store.hasConfiguredSources) {
                guard store.hasConfiguredSources else { return }
                await store.elevatePreloadPriority()
                await store.refreshIfStale()
                await store.refreshScheduledRecordings()
            }
    }

    // MARK: States

    @ViewBuilder
    private var content: some View {
        if !store.hasConfiguredSources {
            ContentUnavailableView {
                Label("Add a Live TV Source", systemImage: "play.tv")
            } description: {
                Text("Connect Plex Live TV, Dispatcharr, or a playlist from your provider.")
            } actions: {
                SettingsLink { Text("Add Source") }
                    .buttonStyle(.borderedProminent)
            }
        } else if store.channels.isEmpty {
            if store.isLoadingChannels {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("No Channels", systemImage: "antenna.radiowaves.left.and.right.slash")
                } description: {
                    Text(store.channelsError ?? String(localized: "Your Live TV sources returned no channels."))
                } actions: {
                    Button("Try Again") { Task { await store.refreshChannels() } }
                }
            }
        } else {
            switch layout {
            case .browse:
                MacLiveWhatsOnView(onWatch: play, onDetails: { selection = $0 }) { banner }
            case .guide:
                VStack(spacing: 0) {
                    banner
                    guide
                }
            }
        }
    }

    // MARK: Guide

    private var guide: some View {
        MacLiveGuideView(
            channels: guideChannels,
            epg: store.epg,
            loadedThrough: store.epgLoadedThrough,
            recordingIds: store.recordingProgramIds(in: store.epg),
            jumpToken: jumpToken,
            actions: MacLiveGuideView.Actions(
                play: play,
                details: { selection = $0 },
                menu: { channel, program in
                    LiveMenu.sections(channel: channel, program: program, recorder: recorder,
                                      watch: play, details: { selection = $0 })
                }
            )
        )
    }

    private var groups: [String] {
        Set(store.channels.compactMap { $0.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The filtered lineup. A filter whose channels vanished falls back to all.
    private var guideChannels: [UnifiedChannel] {
        if guideFilter == Self.favoritesFilter {
            let favorites = store.favorites(in: store.channels)
            return favorites.isEmpty ? store.channels : favorites
        }
        guard !guideFilter.isEmpty else { return store.channels }
        let matching = store.channels.filter {
            $0.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines) == guideFilter
        }
        return matching.isEmpty ? store.channels : matching
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if showsToolbar {
            ToolbarItem {
                Picker("Layout", selection: $layoutRaw) {
                    ForEach(LiveLayout.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .help("Switch between What's On and the Guide")
            }
            if layout == .guide {
                ToolbarItem {
                    Button { jumpToken += 1 } label: { Label("Now", systemImage: "clock") }
                        .keyboardShortcut("j", modifiers: .command)
                        .help("Jump to Now")
                }
                ToolbarItem { filterMenu }
            }
        }
        if store.hasRecordingSources {
            ToolbarItem {
                NavigationLink(value: MacRoute.liveRecordings) {
                    Label("Recordings", systemImage: "recordingtape")
                }
                .help("Recordings")
            }
        }
    }

    private var filterMenu: some View {
        let hasFavorites = !store.favorites(in: store.channels).isEmpty
        let active = guideChannels.count != store.channels.count || guideFilter == Self.favoritesFilter
        return Menu {
            Picker("Channels", selection: $guideFilter) {
                Text("All Channels").tag("")
                if hasFavorites {
                    Label("Favorites", systemImage: "star").tag(Self.favoritesFilter)
                }
                ForEach(groups, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Filter", systemImage: active
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .help("Filter Channels")
    }

    // MARK: Banner

    /// "Guide data unavailable" with each source's reason. Dismissed per message.
    @ViewBuilder
    private var banner: some View {
        let lines = issueLines
        let key = lines.joined(separator: "\n")
        if !lines.isEmpty, key != dismissedIssues {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.epgIssues.isEmpty ? "Some channels didn't load" : "Guide data unavailable")
                        .font(.subheadline.weight(.semibold))
                    ForEach(lines, id: \.self) { line in
                        Text(line).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation { dismissedIssues = key }
                } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
            }
            .padding(12)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, MacMetrics.pageMargin)
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
        }
    }

    private var issueLines: [String] {
        let epg = store.epgIssues.map { "\($0.sourceName): \($0.reason)" }
        let channels = store.channelsError.map { $0.components(separatedBy: "\n") } ?? []
        return channels + epg
    }

    // MARK: Actions

    private func play(_ channel: UnifiedChannel) {
        playback.playLive(channel)
    }

    private func playPending() {
        guard let channel = pendingPlay else { return }
        pendingPlay = nil
        play(channel)
    }

    private func reloadEverything() async {
        await store.refreshChannels()
        await store.loadEPG(startDate: Date(), hours: LiveTVDataStore.refreshWindowHours)
        await store.refreshScheduledRecordings()
    }
}
