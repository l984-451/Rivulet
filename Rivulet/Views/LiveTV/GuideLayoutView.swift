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
    @FocusState private var focusedCategory: String?

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
        for channel in channels where (epg[channel.id]?.isEmpty ?? true) {
            epg[channel.id] = Self.placeholderPrograms(channelId: channel.id, from: timelineStart)
        }
        return epg
    }

    /// 4-hour "No guide data available." blocks spanning the visible timeline.
    /// Block boundaries are derived from the (fixed) timeline start, so ids
    /// stay stable across the 30s `now` ticks and don't churn the grid.
    private static func placeholderPrograms(channelId: String, from start: Date) -> [UnifiedProgram] {
        let blockSeconds: TimeInterval = 4 * 3600
        let span = TimeInterval(EPGTheme.timelineSpanHours * 3600)
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

    private var totalMinutes: Int { EPGTheme.timelineSpanHours * 60 }

    /// Height of the category tab bar between the info bar and the time ruler.
    private let categoryBarHeight: CGFloat = 64

    // Player state
    @State private var activeChannel: UnifiedChannel?
    @State private var playerSessionId = UUID()
    @State private var displayMode: LiveTVDisplayMode = .hidden

    // Guide state
    @State private var timelineStart = Date()
    @State private var now = Date()
    @State private var focusedChannel: UnifiedChannel?
    @State private var focusedProgram: UnifiedProgram?

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
                await dataStore.loadEPG(startDate: Date(), hours: EPGTheme.timelineSpanHours)
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
                menuActive: displayMode == .fullscreen,
                onFocus: { channel, program in
                    focusedChannel = channel
                    focusedProgram = program
                },
                onSelect: { channel, _ in selectChannel(channel) },
                transparent: true,                 // dark see-through boxes + rounded clipping
                // Reserve the info bar + category bar above the ruler.
                topInset: EPGTheme.infoBarHeight + categoryBarHeight
            )

            VStack(alignment: .leading, spacing: 0) {
                GuideInfoBar(channel: focusedChannel, program: focusedProgram)
                    .frame(height: EPGTheme.infoBarHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)

                categoryBar
                    .frame(height: categoryBarHeight)
            }
        }
    }

    // MARK: - Category bar ("All Channels" + M3U group titles)

    @ViewBuilder private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                categoryButton(title: "All Channels", group: nil)
                ForEach(groupTitles, id: \.self) { group in
                    categoryButton(title: group, group: group)
                }
            }
            .padding(.leading, EPGTheme.cellSpacing)
            .padding(.trailing, 60)
            .padding(.vertical, 10)
        }
        .focusSection()
    }

    private func categoryButton(title: String, group: String?) -> some View {
        let selected = (selectedGroup == group)
        let focused = (focusedCategory == title)
        // White pill when it's the active filter, grey pill when focused,
        // nothing otherwise. The system focus effect is disabled so the pill
        // is the only focus indicator.
        let pillColor: Color = selected ? Color.white
            : (focused ? Color.white.opacity(0.22) : Color.clear)
        let textColor: Color = selected ? EPGTheme.background
            : (focused ? Color.white : EPGTheme.textSecondary)
        return Button {
            if selectedGroup != group {
                selectedGroup = group
                focusedChannel = nil        // reseed focus onto the filtered lineup
                seedFocus()
            }
        } label: {
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(textColor)
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
                .background(Capsule().fill(pillColor))
        }
        .buttonStyle(CategoryTabButtonStyle())
        .focusEffectDisabled()
        .focused($focusedCategory, equals: title)
        .animation(.easeInOut(duration: 0.15), value: focused)
        .animation(.easeInOut(duration: 0.15), value: selected)
    }

    /// The focused programme's image, strong at the top and dimming to a faint
    /// ambiance over the grid.
    /// The guide backdrop: a 16:9 landscape programme image that is DISTINCT from
    /// the poster artwork. If the programme's only image is a single reused one
    /// (e.g. a channel logo serving as the programme icon), there's no real
    /// backdrop and the stock settings background shows instead.
    private var guideBackdropURL: URL? {
        guard let prog = focusedProgram, let landscape = prog.landscapeURL else { return nil }
        let posterSource = prog.posterURL ?? prog.iconURL ?? prog.landscapeURL
        return landscape != posterSource ? landscape : nil
    }

    /// A constant full-screen layer. The backdrop image is drawn INSIDE it as an
    /// overlay, so toggling the image (as focus moves between programmes with and
    /// without a backdrop) never changes this layer's geometry — which is what
    /// was nudging the grid. Only a genuine 16:9 image distinct from the poster
    /// is used; otherwise the stock settings background shows through the clear.
    private var ambiance: some View {
        GeometryReader { geo in
            if let url = guideBackdropURL {
                ZStack(alignment: .topTrailing) {
                    // Vibrant wash: the SOURCE image itself, blurred + stretched
                    // to fill the whole guide, so its real colours bleed across
                    // and down the screen. A left + bottom scrim keeps the
                    // metadata column and grid readable.
                    backdropImage(url)
                        .frame(width: geo.size.width, height: geo.size.height)
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

                    // Crisp image in the top-right quarter; its left + bottom
                    // edges fade into the blurred wash.
                    backdropImage(url)
                        .frame(width: geo.size.width * 0.5, height: geo.size.height * 0.55)
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
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topTrailing)
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder private func backdropImage(_ url: URL) -> some View {
        CachedAsyncImage(url: url) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFill()
            default: Color.clear
            }
        }
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

// MARK: - Category tab button style

/// Renders only the label — no default background, scale, or focus chrome — so
/// the pill (driven by `@FocusState`) is the sole focus indicator.
private struct CategoryTabButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1.0)
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
