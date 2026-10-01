// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  GuideLayoutView.swift
//  Rivulet
//
//  UHF-style Live TV guide host. Three layers: the UIKit-backed EPG grid
//  (bottom, virtualized, with its own pinned channel column + time ruler +
//  now-line), the info bar on top, and the corner player after Back.
//  The grid is `EPGGuide` (see EPGGuideView.swift), ported from PlexGuide and
//  fed by Rivulet's `LiveTVDataStore`.
//

import SwiftUI
import Combine
import UIKit

struct GuideLayoutView: View {
    /// Optional source ID to filter channels. nil = show all sources.
    var sourceIdFilter: String?

    @StateObject private var dataStore = LiveTVDataStore.shared

    /// Selected category tab. nil = "All Channels"; otherwise an M3U group title.
    @State private var selectedGroup: String?

    /// Channels for the current source, before category filtering.
    private var sourceChannels: [UnifiedChannel] {
        if let sourceId = sourceIdFilter {
            return dataStore.channels.filter { $0.sourceId == sourceId }
        }
        return dataStore.channels
    }

    /// Tab title for favourites: Rivulet's, from any source, then the source's
    /// own (Plex account favourites). Not a `groupTitle`: a favourite keeps
    /// its tuner group too, and this tab sorts by the order the user arranged
    /// rather than by channel number.
    static let favouritesTab = "Favorites"

    /// Tabs that lead the bar regardless of the alphabet, in this order. A list
    /// the user curated outranks a source's own grouping — burying "Favourites"
    /// under F is the kind of correctness that reads as a bug.
    private static let pinnedGroups = [favouritesTab]

    /// Distinct group titles used as category tabs: pinned ones first, then
    /// everything else alphabetically. Fed by an M3U's `group-title` and, for
    /// Plex sources, by the DVR's user-set tuner name.
    private var groupTitles: [String] {
        let groups = Set(
            sourceChannels
                .compactMap { $0.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        var available = groups
        // Offered only when there are favourites, so no empty tab.
        if !dataStore.favorites(in: sourceChannels).isEmpty {
            available.insert(Self.favouritesTab)
        }
        let pinned = Self.pinnedGroups.filter(available.contains)
        let rest = available.subtracting(pinned).sorted()
        return pinned + rest
    }

    /// Channels shown in the grid: source-filtered, then category-filtered.
    private var channels: [UnifiedChannel] {
        // A tab whose channels vanished on a refresh (favourites are best
        // effort, and a lineup can change) falls back to everything. Filtering
        // to nothing would replace the grid AND its tab bar with a spinner and
        // leave no way to pick another tab.
        guard let group = selectedGroup, groupTitles.contains(group) else { return sourceChannels }

        // Favourites is a view over the flags, not a group match, and it keeps
        // the user's arrangement instead of the merged channel-number sort
        // every other tab inherits.
        if group == Self.favouritesTab {
            return dataStore.favorites(in: sourceChannels)
        }

        return sourceChannels.filter {
            $0.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines) == group
        }
    }

    /// Programmes keyed by channel id (the EPGGuide indexes by `channel.id`).
    /// Channels with no matched guide data get placeholder 4-hour blocks so
    /// their rows still render focusable cells — without them the row has
    /// nothing to land on and the channel can't be selected at all.
    private var programsByChannel: [String: [UnifiedProgram]] {
        var epg = dataStore.epg
        let spanMinutes = totalMinutes
        for channel in channels where (epg[channel.id]?.isEmpty ?? true) {
            epg[channel.id] = Self.placeholderPrograms(
                channelId: channel.id, from: timelineStart, spanMinutes: spanMinutes)
        }
        return epg
    }

    /// 4-hour "No guide data available." blocks spanning the visible timeline.
    /// Block boundaries are derived from the (fixed) timeline start, so ids
    /// stay stable across the 30s `now` ticks and don't churn the grid.
    private static func placeholderPrograms(channelId: String, from start: Date, spanMinutes: Int) -> [UnifiedProgram] {
        let blockSeconds: TimeInterval = 4 * 3600
        let span = TimeInterval(spanMinutes * 60)
        var programs: [UnifiedProgram] = []
        var blockStart = start
        while blockStart < start.addingTimeInterval(span) {
            let blockEnd = blockStart.addingTimeInterval(blockSeconds)
            programs.append(UnifiedProgram(
                id: "\(channelId):placeholder:\(Int(blockStart.timeIntervalSince1970))",
                channelId: channelId,
                title: "No guide data available.",
                startTime: blockStart,
                endTime: blockEnd
            ))
            blockStart = blockEnd
        }
        return programs
    }

    /// Timeline width in minutes, tracking the loaded EPG window so the grid
    /// grows as `extendEPG` pulls more programming. Floors at the initial load
    /// so the first paint has room, and never runs past the placeholder ceiling.
    private var totalMinutes: Int {
        let floor = EPGTheme.initialGuideHours * 60
        let ceiling = EPGTheme.timelineSpanHours * 60
        guard let through = dataStore.epgLoadedThrough else { return floor }
        let loaded = Int(through.timeIntervalSince(timelineStart) / 60)
        return min(max(floor, loaded), ceiling)
    }

    // Guide state
    @State private var timelineStart = Date()
    @State private var now = Date()
    @State private var focusedChannel: UnifiedChannel?
    @State private var focusedProgram: UnifiedProgram?
    /// Set when the player closes, so the grid comes back on the channel that
    /// was playing (issue #317).
    @State private var gridFocusRequest: EPGFocusRequest?

    /// The channel still playing, with sound, in the corner after Back
    /// (issue #318). Owned here until it is handed back full screen, replaced,
    /// or the guide goes away.
    @State private var miniSession: LiveTVSessionHandoff?
    @AppStorage("liveTVKeepPlayingInGuide") private var keepPlayingInGuide = true

    // Backdrop transition state. Each image is one layer (wash plus crisp
    // artwork), and the incoming layer fades in over the outgoing one.
    @State private var outgoingBackdropImage: UIImage?
    @State private var incomingBackdropImage: UIImage?
    @State private var backdropProgress: Double = 1
    /// The measured backdrop for unlabelled programme art: its URL when it is
    /// landscape, nil when not. Keyed to the programme it was measured for so a
    /// late result never paints behind another programme.
    @State private var resolvedLandscape: (programID: String, url: URL?)?

    /// How long focus has to rest on a programme before its backdrop loads.
    /// Holding a direction to cross the guide should not fire an image load or
    /// a transition per channel.
    private let backdropSettleDelay = Duration.milliseconds(300)
    private let backdropFadeDuration = 0.35

    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // No custom base: when the focused programme has no artwork the
                // stock system background (the same one Settings uses) shows
                // through. When artwork exists, `ambiance` paints it on top.
                ambiance

                if channels.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // The info bar, category pills and channel column all start
                    // `cellSpacing` into this, so they line up on the page margin.
                    guideContent
                        .padding(.leading, EPGTheme.pageMargin - EPGTheme.cellSpacing)
                }

                // EPG failure banner — surfaced so an empty guide doesn't look
                // like a Rivulet bug when the cause is a broken third-party EPG.
                if !dataStore.epgIssues.isEmpty {
                    EPGIssueBanner(issues: dataStore.epgIssues)
                        .padding(.horizontal, EPGTheme.pageMargin)
                        .padding(.top, EPGTheme.pageMargin)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .allowsHitTesting(false)
                }

                if let miniSession {
                    LiveMiniPlayerRepresentable(session: miniSession)
                        .frame(width: EPGTheme.miniPlayerSize.width, height: EPGTheme.miniPlayerSize.height)
                        .padding(.top, EPGTheme.pageMargin)
                        .padding(.trailing, EPGTheme.pageMargin)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .allowsHitTesting(false)
                        .zIndex(20)
                }
            }
        }
        // Margins come from `EPGTheme.pageMargin`, like the rest of the app,
        // not from the tvOS safe area (80pt leading, 60pt top).
        .ignoresSafeArea()
        .onAppear(perform: setupStartTime)
        .task {
            if dataStore.channels.isEmpty { await dataStore.loadChannels() }
            if dataStore.epg.isEmpty {
                await dataStore.loadEPG(startDate: timelineStart, hours: EPGTheme.initialGuideHours)
            }
            seedFocus()
            await dataStore.refreshScheduledRecordings()
        }
        .onChange(of: channels.count) { _, _ in seedFocus() }
        .onReceive(tick) { t in now = t }
        .onDisappear {
            // Leaving the guide (another tab, a full-screen page) ends the
            // corner player. Opening the player takes the session first, so
            // this never stops a channel that is being handed back.
            miniSession?.stop()
            miniSession = nil
        }
        .task(id: focusedProgram?.id) {
            await resolveLandscape(for: focusedProgram)
        }
    }

    // MARK: - Guide (grid + info bar)

    private var guideContent: some View {
        ZStack(alignment: .topLeading) {
            EPGGuide(
                channels: channels,
                programsByChannel: programsByChannel,
                timelineStart: timelineStart,
                totalMinutes: totalMinutes,
                now: now,
                categoryTitles: groupTitles,
                selectedCategory: selectedGroup,
                onCategorySelect: { group in
                    guard selectedGroup != group else { return }
                    selectedGroup = group
                    focusedChannel = nil
                    seedFocus()
                },
                onFocus: { channel, program in
                    focusedChannel = channel
                    focusedProgram = program
                },
                onSelect: { channel, _ in selectChannel(channel) },
                onNeedMore: {
                    Task { await dataStore.extendEPG(byHours: EPGTheme.lazyLoadChunkHours) }
                },
                transparent: true,                 // dark see-through boxes + rounded clipping
                // Reserve the info bar + category bar above the ruler.
                topInset: EPGTheme.infoBarHeight + EPGTheme.categoryBarHeight,
                focusRequest: gridFocusRequest,
                onLongPress: { channel, program, frame in
                    presentProgramMenu(channel: channel, program: program, frame: frame)
                },
                recordingProgramIds: dataStore.recordingProgramIds(in: dataStore.epg),
                categoryActionTitle: dataStore.hasRecordingSources ? "Recordings" : nil,
                onCategoryAction: { presentRecordings() }
            )

            GuideInfoBar(channel: focusedChannel, program: focusedProgram)
                .frame(height: EPGTheme.infoBarHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
        }
    }

    /// What the backdrop should show for the focused programme: its declared
    /// 16:9 image, else its unlabelled art once measured as landscape, else
    /// nothing (the stock settings background). `settled` means the settle
    /// delay already passed while the art was measured.
    enum BackdropTarget: Equatable {
        /// Unlabelled art still being measured. The current backdrop stays;
        /// treating this as "no art" faded to the bare background and back.
        case pending
        case image(URL?, settled: Bool)
    }

    private var backdropTarget: BackdropTarget {
        let candidate = focusedProgram.flatMap { $0.iconURL ?? $0.posterURL }
        return Self.backdropTarget(for: focusedProgram, resolved: resolvedLandscape,
                                   kind: EPGImageClassifier.shared.kind(for: candidate))
    }

    /// `kind` is the classifier's cached verdict on the programme's icon or
    /// poster, nil when it has not been measured.
    static func backdropTarget(for program: UnifiedProgram?, resolved: (programID: String, url: URL?)?,
                               kind: EPGImageKind?) -> BackdropTarget {
        guard let program else { return .image(nil, settled: false) }
        if let landscape = program.landscapeURL { return .image(landscape, settled: false) }
        guard let candidate = program.iconURL ?? program.posterURL else { return .image(nil, settled: false) }
        if let resolved, resolved.programID == program.id { return .image(resolved.url, settled: true) }
        switch kind {
        case .landscape?: return .image(candidate, settled: false)
        case .portrait?: return .image(nil, settled: false)
        case nil: return .pending
        }
    }

    /// The outgoing layer stays opaque under an incoming image, so the page
    /// behind never shows through mid-fade (two layers at 50% each cover only
    /// 75%, which read as a dip to black). With no incoming image it fades out.
    static func outgoingBackdropOpacity(progress: Double, hasIncoming: Bool) -> Double {
        hasIncoming ? 1 : 1 - progress
    }

    /// Measures unlabelled programme art after the same settle delay as the
    /// backdrop, so crossing the guide does not download an icon per channel.
    private func resolveLandscape(for program: UnifiedProgram?) async {
        guard let program, program.landscapeURL == nil,
              let candidate = program.iconURL ?? program.posterURL,
              EPGImageClassifier.shared.kind(for: candidate) == nil else { return }
        do {
            try await Task.sleep(for: backdropSettleDelay)
        } catch {
            return
        }
        let kind = await EPGImageClassifier.shared.classify(candidate) {
            await ImageCacheManager.shared.image(for: candidate)?.size
        }
        guard !Task.isCancelled else { return }
        // Recorded either way: a non-landscape verdict must end `.pending` too.
        resolvedLandscape = (program.id, kind == .landscape ? candidate : nil)
    }

    /// A constant full-screen layer. The backdrop image is drawn INSIDE it as an
    /// overlay, so toggling the image (as focus moves between programmes with and
    /// without a backdrop) never changes this layer's geometry — which is what
    /// was nudging the grid. Only landscape programme art is used; otherwise the
    /// stock settings background shows through the clear.
    private var ambiance: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                if let outgoingBackdropImage {
                    backdropLayer(outgoingBackdropImage, size: geo.size)
                        .opacity(Self.outgoingBackdropOpacity(progress: backdropProgress,
                                                              hasIncoming: incomingBackdropImage != nil))
                }

                if let incomingBackdropImage {
                    backdropLayer(incomingBackdropImage, size: geo.size)
                        .opacity(backdropProgress)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topTrailing)
        }
        .ignoresSafeArea()
        .task(id: backdropTarget) {
            guard case .image(let url, let settled) = backdropTarget else { return }
            await transitionBackdrop(to: url, settle: !settled)
        }
    }

    /// The wash with the crisp artwork over it, crossfaded as one layer so the
    /// artwork never blinks out ahead of the wash.
    private func backdropLayer(_ image: UIImage, size: CGSize) -> some View {
        ZStack(alignment: .topTrailing) {
            blurredBackdrop(image, size: size)
            crispArtwork(image, size: size)
        }
    }

    private func blurredBackdrop(_ image: UIImage, size: CGSize) -> some View {
        // Existing main-branch treatment: the source image is blurred and
        // stretched across the guide, with the same readability scrims.
        backdropImage(image)
            .frame(width: size.width, height: size.height)
            .clipped()
            .blur(radius: 70, opaque: true)
            .overlay(
                LinearGradient(
                    colors: [Color.black.opacity(0.72), Color.black.opacity(0.05)],
                    startPoint: .leading, endPoint: .trailing)
            )
            .overlay(
                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.65)],
                    startPoint: .top, endPoint: .bottom)
            )
    }

    private func crispArtwork(_ image: UIImage, size: CGSize) -> some View {
        // Existing main-branch image size and masks are intentionally unchanged.
        backdropImage(image)
            .frame(width: size.width * 0.5, height: size.height * 0.55)
            .clipped()
            .mask(
                LinearGradient(colors: [.clear, .white],
                               startPoint: .leading, endPoint: .trailing)
            )
            .mask(
                LinearGradient(stops: [
                    .init(color: .white, location: 0.0),
                    .init(color: .white, location: 0.45),
                    .init(color: .clear, location: 1.0)
                ], startPoint: .top, endPoint: .bottom)
            )
    }

    private func transitionBackdrop(to newURL: URL?, settle: Bool) async {
        // Settle first, and mutate nothing before it. `.task(id:)` cancels this
        // on every focus change, so anything written ahead of the first suspend
        // survives a cancel while the rest of the transition never runs.
        // Returning here instead leaves the current backdrop exactly as it is.
        if settle {
            do {
                try await Task.sleep(for: backdropSettleDelay)
            } catch {
                return
            }
        }

        let newImage = await loadBackdrop(newURL)
        guard !Task.isCancelled else { return }

        // Same image (a programme change on one channel can reuse its art):
        // nothing to fade.
        guard newImage !== incomingBackdropImage else { return }

        // Seed the crossfade without animating: the outgoing layer at full
        // opacity, the incoming at zero. A plain assignment here can be
        // coalesced into the animation below and jump straight to the new image.
        var seed = Transaction()
        seed.disablesAnimations = true
        withTransaction(seed) {
            // Continue from the most recently shown image, rather than briefly
            // restoring an older programme's.
            outgoingBackdropImage = incomingBackdropImage ?? outgoingBackdropImage
            incomingBackdropImage = newImage
            backdropProgress = 0
        }

        withAnimation(.easeInOut(duration: backdropFadeDuration)) {
            backdropProgress = 1
        }

        do {
            try await Task.sleep(for: .seconds(backdropFadeDuration))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        // Drop the outgoing layer so only one blurred layer stays composited.
        outgoingBackdropImage = nil
    }

    private func loadBackdrop(_ url: URL?) async -> UIImage? {
        guard let url else { return nil }
        return await ImageCacheManager.shared.image(for: url)
    }

    private func backdropImage(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
    }

    // MARK: - Selection

    private func selectChannel(_ channel: UnifiedChannel) {
        // Live TV plays through Aether (same OSD as Aether VOD): HLS goes
        // straight to AVPlayer, everything else is remuxed by the engine.
        // Presented as a full-screen modal so it escapes the guide's
        // TabView / safe-area insets.
        guard let top = LiveProgramMenu.topViewController() else { return }

        // The corner player's channel comes back full screen as it is, with
        // no new tune. Any other channel replaces it.
        var adopting: LiveTVSessionHandoff?
        if let mini = miniSession {
            miniSession = nil
            if mini.channel.id == channel.id {
                adopting = mini
            } else {
                mini.stop()
            }
        }

        let vc = LiveTVAetherPlayerViewController(channel: channel, adopting: adopting)
        vc.modalPresentationStyle = .fullScreen
        if keepPlayingInGuide {
            vc.onMinimize = { session in
                miniSession = session
            }
        }
        vc.onDismiss = { lastChannel in
            // The viewer may have changed channels in the player; land on the
            // one that was on screen, at the programme airing now.
            if !channels.contains(where: { $0.id == lastChannel.id }) {
                selectedGroup = nil
            }
            gridFocusRequest = EPGFocusRequest(channelId: lastChannel.id, token: UUID())
        }
        top.present(vc, animated: true)
    }

    // MARK: - Programme menu and recordings

    private func presentProgramMenu(channel: UnifiedChannel, program: UnifiedProgram?, frame: CGRect?) {
        guard let top = LiveProgramMenu.topViewController() else { return }
        LiveProgramMenu.present(program: program, channel: channel, from: top, sourceFrame: frame) { channel in
            selectChannel(channel)
        }
    }

    private func presentRecordings() {
        guard let top = LiveProgramMenu.topViewController() else { return }
        miniSession?.stop()
        miniSession = nil
        let recordings = LiveRecordingsViewController()
        recordings.modalPresentationStyle = .fullScreen
        top.present(recordings, animated: true)
    }

    // MARK: - Helpers

    private func setupStartTime() {
        let cal = Calendar.current
        let nowDate = Date()
        let minute = cal.component(.minute, from: nowDate)
        timelineStart = cal.date(bySettingHour: cal.component(.hour, from: nowDate),
                                 minute: (minute / 30) * 30, second: 0, of: nowDate) ?? nowDate
    }

    private func seedFocus() {
        guard let first = channels.first else {
            focusedChannel = nil
            focusedProgram = nil
            return
        }
        if focusedChannel == nil {
            focusedChannel = first
            focusedProgram = dataStore.getCurrentProgram(for: first)
                ?? dataStore.epg[first.id]?.first
        }
    }
}

// MARK: - EPG failure banner

private struct EPGIssueBanner: View {
    let issues: [LiveTVDataStore.EPGFetchIssue]

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.yellow.opacity(0.9))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(issues.count == 1
                     ? "Guide data unavailable"
                     : "Guide data unavailable (\(issues.count) sources)")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)

                ForEach(issues) { issue in
                    Text("\(issue.sourceName): \(issue.reason)")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - Corner player

/// Hosts the UIKit corner player that keeps a channel going after Back.
private struct LiveMiniPlayerRepresentable: UIViewRepresentable {
    let session: LiveTVSessionHandoff

    func makeUIView(context: Context) -> LiveMiniPlayerView {
        let view = LiveMiniPlayerView()
        view.show(session)
        return view
    }

    func updateUIView(_ uiView: LiveMiniPlayerView, context: Context) {
        uiView.show(session)
    }

    static func dismantleUIView(_ uiView: LiveMiniPlayerView, coordinator: ()) {
        uiView.release()
    }
}
