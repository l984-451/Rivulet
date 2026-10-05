// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Live TV tab root: What's On or the Guide, over every configured source.
/// The root supplies the NavigationStack.
struct IOSLiveTVView: View {
    @ObservedObject private var store = LiveTVDataStore.shared
    @EnvironmentObject private var playback: IOSPlaybackController
    @StateObject private var recorder = IOSLiveRecorder()
    @AppStorage(IOSLiveLayout.storageKey) private var layoutRaw = IOSLiveLayout.browse.rawValue
    @AppStorage("iosLiveTVGuideFilter") private var guideFilter = ""
    @State private var selection: IOSLiveProgrammeSelection?
    @State private var pendingPlay: UnifiedChannel?
    @State private var showingAddSource = false
    @State private var jumpToken = 0
    @State private var dismissedIssues = ""

    private static let favoritesFilter = "Favorites"

    private var layout: IOSLiveLayout { IOSLiveLayout(rawValue: layoutRaw) ?? .browse }

    var body: some View {
        content
            .navigationTitle("Live TV")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbar }
            .navigationDestination(for: IOSLiveRoute.self) { _ in IOSLiveRecordingsView() }
            .sheet(item: $selection, onDismiss: playPending) { selection in
                IOSLiveProgrammeSheet(selection: selection) { pendingPlay = $0 }
            }
            .sheet(isPresented: $showingAddSource) { IOSLiveAddSourceSheet() }
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
                Button("Add Source") { showingAddSource = true }
                    .buttonStyle(.glassProminent)
            }
        } else if store.channels.isEmpty {
            ScrollView {
                Group {
                    if store.isLoadingChannels {
                        ProgressView()
                    } else {
                        ContentUnavailableView {
                            Label("No Channels", systemImage: "antenna.radiowaves.left.and.right.slash")
                        } description: {
                            Text(store.channelsError ?? "Your Live TV sources returned no channels.")
                        } actions: {
                            Button("Try Again") { Task { await store.refreshChannels() } }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .containerRelativeFrame([.horizontal, .vertical])
            }
            .refreshable { await reloadEverything() }
        } else {
            switch layout {
            case .browse:
                IOSLiveWhatsOnView(onWatch: play, onDetails: { selection = $0 }) { banner }
                    .refreshable { await reloadEverything() }
                    .safeAreaBar(edge: .top) { layoutPicker }
            case .guide:
                VStack(spacing: 0) {
                    banner
                    guide
                }
                .safeAreaBar(edge: .top) { layoutPicker }
            }
        }
    }

    private var layoutPicker: some View {
        Picker("Layout", selection: $layoutRaw) {
            ForEach(IOSLiveLayout.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 360)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    // MARK: Guide

    private var guide: some View {
        IOSLiveGuideView(
            channels: guideChannels,
            epg: store.epg,
            loadedThrough: store.epgLoadedThrough,
            recordingIds: store.recordingProgramIds(in: store.epg),
            jumpToken: jumpToken,
            actions: IOSLiveGuideView.Actions(
                play: play,
                details: { selection = $0 },
                menu: { channel, program in
                    IOSLiveMenu.uiMenu(IOSLiveMenu.sections(
                        channel: channel, program: program, recorder: recorder,
                        watch: play, details: { selection = $0 }
                    ))
                },
                needsMoreGuide: {
                    guard !store.isExtendingEPG else { return }
                    Task { await store.extendEPG(byHours: 6) }
                }
            )
        )
        .ignoresSafeArea(edges: .bottom)
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
        if store.hasConfiguredSources, !store.channels.isEmpty, layout == .guide {
            ToolbarItem(placement: .topBarTrailing) {
                Button { jumpToken += 1 } label: { Text("Now") }
                    .accessibilityLabel("Jump to Now")
            }
            ToolbarItem(placement: .topBarTrailing) { filterMenu }
        }
        if store.hasRecordingSources {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: IOSLiveRoute.recordings) {
                    Label("Recordings", systemImage: "recordingtape")
                }
            }
        }
        IOSAccountToolbarItem()
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
        } label: {
            // The toolbar glass is the circle; an active filter tints the glyph.
            Label("Filter", systemImage: "line.3.horizontal.decrease")
        }
        .tint(active ? .accentColor : nil)
    }

    // MARK: Banner

    /// "Guide data unavailable" with each source's reason, like tvOS. Dismissed per message.
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
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("Dismiss")
            }
            .padding(12)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
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
