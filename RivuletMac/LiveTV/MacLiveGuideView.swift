// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import AppKit
import Combine
import SwiftUI

/// The programme grid. One two-axis scroll view holds only the blocks near the viewport;
/// the channel column, time ruler and now line are overlays placed from the scroll offset.
/// The window runs from two hours ago to the loaded guide (8 days at most).
struct MacLiveGuideView: View {
    struct Actions {
        let play: (UnifiedChannel) -> Void
        let details: (LiveProgrammeSelection) -> Void
        let menu: (UnifiedChannel, UnifiedProgram?) -> [[LiveMenuAction]]
    }

    let channels: [UnifiedChannel]
    let epg: [String: [UnifiedProgram]]
    let loadedThrough: Date?
    let recordingIds: Set<String>
    let jumpToken: Int
    let actions: Actions

    private struct Viewport: Equatable {
        var offset: CGPoint = .zero
        var size: CGSize = .zero
    }

    /// The pinned overlays sit inside the safe area, so the offset adds the scroll insets (the container size already excludes them).
    private static func viewport(of geometry: ScrollGeometry) -> Viewport {
        let inset = geometry.contentInsets
        return Viewport(
            offset: CGPoint(x: geometry.contentOffset.x + inset.leading, y: geometry.contentOffset.y + inset.top),
            size: geometry.containerSize)
    }

    private struct Span: Identifiable {
        let program: UnifiedProgram?
        let channelIndex: Int
        let startMinute: CGFloat
        let minutes: CGFloat
        var id: String { "\(channelIndex)|\(program?.id ?? "none")" }
    }

    private static let historyMinutes: TimeInterval = 120
    private static let maxHoursAhead = TimeInterval(LiveTVDataStore.epgMaxHoursAhead)
    private let rowHeight: CGFloat = 56
    private let channelWidth: CGFloat = 148
    private let rulerHeight: CGFloat = 30
    private let pointsPerMinute: CGFloat = 5
    private let gap: CGFloat = 3

    @State private var viewport = Viewport()
    @State private var position = ScrollPosition()
    @State private var windowStart = Self.freshWindowStart()
    @State private var now = Date()
    @State private var hasPositioned = false
    @State private var lastJump = 0
    private static let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: contentSize.width, height: contentSize.height)
                ForEach(visibleSpans) { span in block(span) }
                nowLine
            }
            .frame(width: contentSize.width, height: contentSize.height, alignment: .topLeading)
        }
        .scrollPosition($position)
        .scrollTargetBehavior(HalfHourSnap(column: 30 * pointsPerMinute))
        .onScrollGeometryChange(for: Viewport.self, of: Self.viewport(of:)) { _, new in
            viewport = new
            guard !hasPositioned, new.size.width > 0, new.size.height > 0 else { return }
            hasPositioned = true
            Task { @MainActor in jumpToNow(animated: false) }
        }
        .overlay(alignment: .topLeading) { channelColumn }
        .overlay(alignment: .topLeading) { ruler }
        .overlay(alignment: .topLeading) { corner }
        .background(.background)
        .onReceive(Self.clock) { _ in now = Date() }
        .onAppear(perform: recentreIfStale)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in recentreIfStale() }
        .onChange(of: jumpToken) { _, token in
            guard token != lastJump else { return }
            lastJump = token
            jumpToNow(animated: true)
        }
    }

    // MARK: Window

    private static func freshWindowStart() -> Date {
        floorToHalfHour(Date()).addingTimeInterval(-historyMinutes * 60)
    }

    static func floorToHalfHour(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 1800).rounded(.down) * 1800)
    }

    private var windowEnd: Date {
        let floor = Self.floorToHalfHour(now)
        let loaded = max(loadedThrough ?? floor, floor.addingTimeInterval(6 * 3600))
        return min(loaded, now.addingTimeInterval(Self.maxHoursAhead * 3600))
    }

    private var totalMinutes: CGFloat { CGFloat(windowEnd.timeIntervalSince(windowStart) / 60) }

    private var contentSize: CGSize {
        CGSize(width: channelWidth + totalMinutes * pointsPerMinute,
               height: rulerHeight + CGFloat(channels.count) * rowHeight)
    }

    private func minuteX(_ minute: CGFloat) -> CGFloat { channelWidth + minute * pointsPerMinute }

    /// After a long sleep the window is hours back: move it to now without waiting for the Now button.
    private func recentreIfStale() {
        guard hasPositioned, Date().timeIntervalSince(windowStart) > (Self.historyMinutes + 30) * 60 else { return }
        now = Date()
        jumpToNow(animated: false)
    }

    private func jumpToNow(animated: Bool) {
        if Date().timeIntervalSince(windowStart) > (Self.historyMinutes + 30) * 60 {
            windowStart = Self.freshWindowStart()
        }
        let minutes = CGFloat(Self.floorToHalfHour(Date()).timeIntervalSince(windowStart) / 60)
        let maxX = max(0, contentSize.width - viewport.size.width)
        let x = min(max(0, minutes * pointsPerMinute), maxX)
        if animated {
            withAnimation(.easeInOut(duration: 0.3)) { position.scrollTo(x: x, y: viewport.offset.y) }
        } else {
            position.scrollTo(x: x, y: viewport.offset.y)
        }
    }

    // MARK: Spans

    /// Spans for the rows and minutes near the viewport. The store keeps each channel's guide sorted.
    private var visibleSpans: [Span] {
        guard viewport.size.width > 0, !channels.isEmpty else { return [] }
        let firstRow = max(0, Int(((viewport.offset.y - rulerHeight) / rowHeight).rounded(.down)) - 1)
        let lastRow = min(channels.count - 1,
                          Int(((viewport.offset.y + viewport.size.height - rulerHeight) / rowHeight).rounded(.down)) + 1)
        guard firstRow <= lastRow else { return [] }
        let buffer = viewport.size.width
        let fromMinute = (viewport.offset.x - buffer) / pointsPerMinute
        let toMinute = (viewport.offset.x + viewport.size.width + buffer) / pointsPerMinute
        let end = windowEnd
        let total = totalMinutes
        var result: [Span] = []
        for row in firstRow...lastRow {
            let programs = epg[channels[row].id] ?? []
            var any = false
            for program in programs where program.endTime > windowStart && program.startTime < end {
                let from = max(program.startTime, windowStart)
                let start = CGFloat(from.timeIntervalSince(windowStart) / 60)
                let minutes = CGFloat(min(program.endTime, end).timeIntervalSince(from) / 60)
                any = true
                guard start <= toMinute, start + minutes >= fromMinute else { continue }
                result.append(Span(program: program, channelIndex: row, startMinute: start, minutes: minutes))
            }
            // No guide data: one block across the window, still clickable.
            if !any { result.append(Span(program: nil, channelIndex: row, startMinute: 0, minutes: total)) }
        }
        return result
    }

    private func block(_ span: Span) -> some View {
        let x = minuteX(span.startMinute) + gap / 2
        let width = max(2, span.minutes * pointsPerMinute - gap)
        let hidden = max(0, viewport.offset.x + channelWidth - x)
        let channel = channels[span.channelIndex]
        return MacLiveGuideBlock(
            program: span.program,
            isRecording: span.program.map { recordingIds.contains($0.id) } ?? false,
            isPast: (span.program?.endTime ?? .distantFuture) <= now,
            textInset: 8 + min(hidden, max(0, width - 40)),
            actions: actions,
            channel: channel
        )
        .frame(width: width, height: rowHeight - gap)
        .offset(x: x, y: rulerHeight + CGFloat(span.channelIndex) * rowHeight + gap / 2)
    }

    // MARK: Pinned overlays

    private var channelColumn: some View {
        let first = max(0, Int(((viewport.offset.y - rulerHeight) / rowHeight).rounded(.down)))
        let last = min(channels.count - 1, Int(((viewport.offset.y + viewport.size.height) / rowHeight).rounded(.down)))
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(.background)
            if first <= last {
                ForEach(first...last, id: \.self) { row in
                    MacLiveGuideChannelCell(channel: channels[row], nowTitle: currentTitle(channels[row]), actions: actions)
                        .frame(width: channelWidth, height: rowHeight)
                        .offset(y: rulerHeight + CGFloat(row) * rowHeight - viewport.offset.y)
                }
            }
        }
        .frame(width: channelWidth, height: viewport.size.height, alignment: .topLeading)
        .clipped()
    }

    private func currentTitle(_ channel: UnifiedChannel) -> String? {
        (epg[channel.id] ?? []).first { $0.startTime <= now && $0.endTime > now }?.displayTitle
    }

    private var ruler: some View {
        let column = 30 * pointsPerMinute
        let columns = Int((totalMinutes / 30).rounded(.up))
        let first = max(0, Int(((viewport.offset.x - channelWidth) / column).rounded(.down)))
        let last = min(columns - 1, Int(((viewport.offset.x + viewport.size.width - channelWidth) / column).rounded(.down)))
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(.background)
            if first <= last {
                ForEach(first...last, id: \.self) { index in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.separator).frame(width: 1, height: rulerHeight * 0.4)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                        Text(windowStart.addingTimeInterval(TimeInterval(index * 30 * 60)).formatted(.dateTime.hour().minute()))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 6)
                    }
                    .frame(width: column, height: rulerHeight, alignment: .leading)
                    .offset(x: channelWidth + CGFloat(index) * column - viewport.offset.x)
                }
            }
            Rectangle().fill(.red).frame(width: 10, height: 10).clipShape(Circle())
                .offset(x: minuteX(CGFloat(now.timeIntervalSince(windowStart) / 60)) - viewport.offset.x - 5,
                        y: rulerHeight - 5)
                .opacity(nowIsVisible ? 1 : 0)
        }
        .frame(width: viewport.size.width, height: rulerHeight, alignment: .topLeading)
        .clipped()
        .accessibilityHidden(true)
    }

    private var nowIsVisible: Bool {
        minuteX(CGFloat(now.timeIntervalSince(windowStart) / 60)) - viewport.offset.x >= channelWidth
    }

    private var corner: some View {
        let date = windowStart.addingTimeInterval(TimeInterval(viewport.offset.x / pointsPerMinute * 60))
        return Text(Calendar.current.isDateInToday(date) ? String(localized: "Today") : date.formatted(.dateTime.weekday(.abbreviated)))
            .font(.caption.weight(.bold))
            .frame(width: channelWidth, height: rulerHeight)
            .background(.background)
    }

    private var nowLine: some View {
        let x = minuteX(CGFloat(now.timeIntervalSince(windowStart) / 60))
        return Rectangle()
            .fill(.red)
            .frame(width: 2, height: max(0, contentSize.height - rulerHeight))
            .offset(x: x - 1, y: rulerHeight)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Settles horizontal scrolling on half-hour columns, like the ruler (and iOS).
private struct HalfHourSnap: ScrollTargetBehavior {
    let column: CGFloat

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let maxX = max(0, context.contentSize.width - context.containerSize.width)
        target.rect.origin.x = min((target.rect.origin.x / column).rounded() * column, maxX)
    }
}

// MARK: - Blocks

private struct MacLiveGuideBlock: View {
    let program: UnifiedProgram?
    let isRecording: Bool
    let isPast: Bool
    let textInset: CGFloat
    let actions: MacLiveGuideView.Actions
    let channel: UnifiedChannel
    @State private var hovering = false

    private var airing: Bool { program?.isCurrentlyAiring ?? true }

    var body: some View {
        Button {
            if airing {
                actions.play(channel)
            } else {
                actions.details(LiveProgrammeSelection(channel: channel, program: program))
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(program?.displayTitle ?? String(localized: "No guide data"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(isPast ? .secondary : .primary)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .padding(.leading, textInset)
                .padding(.trailing, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                if isRecording {
                    Circle().fill(.red).frame(width: 7, height: 7).padding(6)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary.opacity(isPast ? 0.5 : 1)))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu { MacLiveMenuContent(sections: actions.menu(channel, program)) }
        .help(helpText)
        .accessibilityLabel(program?.displayTitle ?? String(localized: "No guide data"))
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(airing ? String(localized: "Plays the channel") : String(localized: "Shows details"))
    }

    private var subtitle: String? {
        let text = [program?.guideDetail, program?.guideTag].compactMap { $0 }.joined(separator: " · ")
        return text.isEmpty ? nil : text
    }

    private var helpText: String {
        guard let program else { return channel.name }
        return [program.displayTitle, program.timeRange].joined(separator: "\n")
    }

    private var accessibilityValue: String {
        var value = program.map { [$0.timeRange] } ?? []
        if program?.isCurrentlyAiring == true { value.append(String(localized: "On now")) }
        if isRecording { value.append(String(localized: "Recording")) }
        return value.joined(separator: ", ")
    }
}

private struct MacLiveGuideChannelCell: View {
    let channel: UnifiedChannel
    let nowTitle: String?
    let actions: MacLiveGuideView.Actions
    @State private var hovering = false

    var body: some View {
        Button { actions.play(channel) } label: {
            VStack(spacing: 2) {
                if channel.logoURL != nil {
                    MacLiveLogo(url: channel.logoURL).frame(maxHeight: 22)
                } else {
                    Text(channel.name).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                }
                if let number = channel.channelNumber {
                    Text(String(number)).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary))
            )
            .padding(.leading, 6)
            .padding(.trailing, 3)
            .padding(.vertical, 1.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            MacLiveMenuContent(sections: actions.menu(channel, nil))
        }
        .help(channel.numberAndName)
        .accessibilityLabel(channel.numberAndName)
        .accessibilityValue(nowTitle ?? "")
        .accessibilityHint(String(localized: "Plays the channel"))
    }
}
