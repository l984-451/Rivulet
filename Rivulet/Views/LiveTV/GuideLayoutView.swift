// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  GuideLayoutView.swift
//  Rivulet
//
//  UHF-style Live TV guide host. Three layers: the UIKit-backed EPG grid
//  (bottom, virtualized, with its own pinned channel column + time ruler +
//  now-line), the info bar on top, and the fullscreen / PiP player overlay.
//  The grid is `EPGGuide` (see EPGGuideView.swift), ported from PlexGuide and
//  fed by Rivulet's `LiveTVDataStore`.
//

import SwiftUI
import Combine
import UIKit

/// Display mode for the Live TV player in the guide.
enum LiveTVDisplayMode: Equatable {
    case hidden      // No player visible
    case fullscreen  // Player is fullscreen overlay
    case pip         // Player is in PiP (small, top-right)
}

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

    /// Distinct, sorted M3U group titles used as category tabs.
    private var groupTitles: [String] {
        let groups = sourceChannels.compactMap {
            $0.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return Array(Set(groups)).sorted()
    }

    /// Channels shown in the grid: source-filtered, then category-filtered.
    private var channels: [UnifiedChannel] {
        guard let group = selectedGroup else { return sourceChannels }
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

    // Player state
    @State private var activeChannel: UnifiedChannel?
    @State private var playerSessionId = UUID()
    @State private var displayMode: LiveTVDisplayMode = .hidden

    // Guide state
    @State private var timelineStart = Date()
    @State private var now = Date()
    @State private var focusedChannel: UnifiedChannel?
    @State private var focusedProgram: UnifiedProgram?

    // Backdrop transition state. The wash crossfades to the new programme's
    // image while the crisp artwork fades in over it.
    @State private var outgoingBackdropImage: UIImage?
    @State private var incomingBackdropImage: UIImage?
    @State private var backdropProgress: Double = 1
    @State private var displayedArtworkImage: UIImage?
    @State private var artworkOpacity: Double = 0

    /// How long focus has to rest on a programme before its backdrop loads.
    /// Holding a direction to cross the guide should not fire an image load or
    /// a transition per channel.
    private let backdropSettleDelay = Duration.milliseconds(180)
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
                    guideContent
                        .padding(.top, EPGTheme.guideTopPadding)
                        .opacity(displayMode == .fullscreen ? 0 : 1)
                        .disabled(displayMode == .fullscreen)
                }

                // EPG failure banner — surfaced so an empty guide doesn't look
                // like a Rivulet bug when the cause is a broken third-party EPG.
                if !dataStore.epgIssues.isEmpty, displayMode != .fullscreen {
                    EPGIssueBanner(issues: dataStore.epgIssues)
                        .padding(.horizontal, 40)
                        .padding(.top, 16)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .allowsHitTesting(false)
                }

                // Player layer — present when a channel is active.
                if let channel = activeChannel {
                    liveTVPlayerLayer(channel: channel, screenSize: geo.size)
                        .zIndex(displayMode == .fullscreen ? 100 : 10)
                }
            }
        }
        .ignoresSafeArea(edges: [.bottom, .trailing])
        .onAppear(perform: setupStartTime)
        .task {
            if dataStore.channels.isEmpty { await dataStore.loadChannels() }
            if dataStore.epg.isEmpty {
                await dataStore.loadEPG(startDate: timelineStart, hours: EPGTheme.initialGuideHours)
            }
            seedFocus()
        }
        .onChange(of: channels.count) { _, _ in seedFocus() }
        .onReceive(tick) { t in now = t }
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
                menuActive: displayMode == .fullscreen,
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
                topInset: EPGTheme.infoBarHeight + EPGTheme.categoryBarHeight
            )

            GuideInfoBar(channel: focusedChannel, program: focusedProgram)
                .frame(height: EPGTheme.infoBarHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
        }
    }

    /// The focused programme's image, strong at the top and dimming to a faint
    /// ambiance over the grid.
    /// The guide backdrop: a 16:9 landscape programme image that is DISTINCT from
    /// the poster artwork. If the programme's only image is a single reused one
    /// (e.g. a channel logo serving as the programme icon), there's no real
    /// backdrop and the stock settings background shows instead.
    private var guideBackdropURL: URL? {
        guard let prog = focusedProgram, let landscape = prog.landscapeURL else { return nil }
        guard let posterSource = prog.posterURL ?? prog.iconURL else { return landscape }
        return landscape == posterSource ? nil : landscape
    }

    /// A constant full-screen layer. The backdrop image is drawn INSIDE it as an
    /// overlay, so toggling the image (as focus moves between programmes with and
    /// without a backdrop) never changes this layer's geometry — which is what
    /// was nudging the grid. Only a genuine 16:9 image distinct from the poster
    /// is used; otherwise the stock settings background shows through the clear.
    private var ambiance: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                if let outgoingBackdropImage {
                    blurredBackdrop(outgoingBackdropImage, size: geo.size)
                        .opacity(1 - backdropProgress)
                }

                if let incomingBackdropImage {
                    blurredBackdrop(incomingBackdropImage, size: geo.size)
                        .opacity(backdropProgress)
                }

                if let displayedArtworkImage {
                    crispArtwork(displayedArtworkImage, size: geo.size)
                        .opacity(artworkOpacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topTrailing)
        }
        .ignoresSafeArea()
        .task(id: guideBackdropURL) {
            await transitionBackdrop(to: guideBackdropURL)
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

    private func transitionBackdrop(to newURL: URL?) async {
        // Settle first, and mutate nothing before it. `.task(id:)` cancels this
        // on every focus change, so anything written ahead of the first suspend
        // survives a cancel while the rest of the transition never runs —
        // browsing the guide would leave the artwork faded out indefinitely.
        // Returning here instead leaves the current backdrop exactly as it is.
        do {
            try await Task.sleep(for: backdropSettleDelay)
        } catch {
            return
        }

        let newImage = await loadBackdrop(newURL)
        guard !Task.isCancelled else { return }

        // Seed the crossfade without animating: the outgoing wash at full
        // opacity, the incoming at zero. A plain assignment here can be
        // coalesced into the animation below and jump straight to the new blur.
        var seed = Transaction()
        seed.disablesAnimations = true
        withTransaction(seed) {
            // Continue from the most recently shown wash, rather than briefly
            // restoring an older programme's image.
            outgoingBackdropImage = incomingBackdropImage ?? outgoingBackdropImage
            incomingBackdropImage = newImage
            displayedArtworkImage = newImage
            backdropProgress = 0
            artworkOpacity = 0
        }

        // Wash and artwork move together. Staging them sequentially reads as a
        // slow reveal and holds two full-screen blurs on screen for longer.
        withAnimation(.easeInOut(duration: backdropFadeDuration)) {
            backdropProgress = 1
            artworkOpacity = newImage == nil ? 0 : 1
        }

        do {
            try await Task.sleep(for: .seconds(backdropFadeDuration))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        // Drop the outgoing wash so only one blurred layer stays composited.
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

    // MARK: - Player layer (fullscreen + PiP)

    private var pipScale: CGFloat { 0.28 }
    private var pipMargin: CGFloat { 60 }

    @ViewBuilder
    private func liveTVPlayerLayer(channel: UnifiedChannel, screenSize: CGSize) -> some View {
        let player = LiveTVPlayerView(
            channel: channel,
            onDismiss: {
                displayMode = .hidden
                activeChannel = nil
                playerSessionId = UUID()
            },
            onEnterPIP: {
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    displayMode = .pip
                }
            },
            isInteractive: displayMode == .fullscreen  // Disable focus capture in PiP mode
        )
        // Force a fresh player session when changing channels or after exit/reopen.
        .id("\(playerSessionId.uuidString)-\(channel.id)")
        .transaction { transaction in
            transaction.animation = nil
        }
        .animation(nil, value: displayMode)

        if displayMode == .pip {
            // PiP: a small 16:9 box pinned top-right. Integral 16px width steps
            // avoid fractional scaling artifacts (a thin bottom strip).
            let pipWidth = max(16, floor((screenSize.width * pipScale) / 16.0) * 16.0)
            let pipHeight = pipWidth * 9.0 / 16.0
            player
                .frame(width: pipWidth, height: pipHeight)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 10)
                .position(x: screenSize.width - pipMargin - pipWidth / 2,
                          y: pipMargin + pipHeight / 2)
                .allowsHitTesting(false)
        } else {
            // Fullscreen: fill the true screen and ignore the guide's safe-area
            // inset. Sizing to the GeometryReader's (inset) size is what made the
            // player render as a centered box instead of edge-to-edge.
            player
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .allowsHitTesting(true)
        }
    }

    // MARK: - Selection

    private func selectChannel(_ channel: UnifiedChannel) {
        // Live TV plays through Aether (same OSD as Aether VOD): HLS goes
        // straight to AVPlayer, everything else is remuxed by the engine.
        // Presented as a full-screen modal so it escapes the guide's
        // TabView / safe-area insets.
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              let root = (scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first)?.rootViewController
        else { return }

        var top = root
        while let presented = top.presentedViewController { top = presented }

        let vc = LiveTVAetherPlayerViewController(channel: channel)
        vc.modalPresentationStyle = .fullScreen
        top.present(vc, animated: true)
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
