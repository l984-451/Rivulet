// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EPGGuideView.swift
//  Rivulet
//
//  UHF-style Live TV guide ported from the PlexGuide (Flume) project.
//
//  High-performance EPG grid backed by a UIKit `UICollectionView` with a custom
//  layout: virtualized (fast with large lineups), a sticky channel column
//  (pinned left, scrolls vertically), a sticky time ruler (pinned top, scrolls
//  horizontally), a single "now" line, and a fade where cells pass under the
//  column. Adapted to Rivulet's `UnifiedChannel` / `UnifiedProgram` data and
//  Rivulet's player (selection is handed back to SwiftUI via `onSelect`).
//

import SwiftUI
import UIKit

// MARK: - Theme

/// Colors and layout metrics for the guide, matching the PlexGuide look.
enum EPGTheme {
    // MARK: Colors
    static let background = Color(red: 0.10, green: 0.10, blue: 0.115)
    static let surface = Color(red: 0.21, green: 0.21, blue: 0.23)
    /// Channel column box: lighter than the background, darker than guide cells.
    static let columnFill = Color(red: 0.17, green: 0.17, blue: 0.19)
    /// Shared corner radius for every guide box (timeline, date, logo, cells)
    /// and the rounded clip where cells tuck under the column / ruler.
    static let columnCorner: CGFloat = 8
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.55)

    // MARK: Guide layout metrics (in points)
    /// Horizontal density of the timeline. Tuned so ~4 hours of programming is
    /// visible at once.
    static let pointsPerMinute: CGFloat = 7.5
    /// Width of the sticky channel column on the left.
    static let channelColumnWidth: CGFloat = 129
    /// Height of each channel row.
    static let rowHeight: CGFloat = 94
    /// Height of the sticky timeline header.
    static let timelineHeight: CGFloat = 54
    /// Height of the slim rounded boxes inside the timeline / date row.
    static let timelineBoxHeight: CGFloat = 34
    /// Height of the fixed info bar (top layer) the grid scrolls beneath.
    static let infoBarHeight: CGFloat = 300
    /// Height of the UIKit category pills between the info bar and time ruler.
    static let categoryBarHeight: CGFloat = 64
    /// Vertical breathing room below the UIKit navigation chrome.
    static let guideTopPadding: CGFloat = 35
    /// Gap between the info bar and the time ruler.
    static let rulerGap: CGFloat = 0
    /// Extra gap between the time ruler and the first row.
    static let gridTopGap: CGFloat = 0
    /// Screen Y where the time ruler / corner pin.
    static var rulerTop: CGFloat { infoBarHeight + rulerGap }
    /// Top content inset of the grid (first row rests below the ruler + fade).
    static var gridTopInset: CGFloat { rulerTop + timelineHeight + gridTopGap }
    /// Vertical gap between rows / horizontal gap between cells.
    static let cellSpacing: CGFloat = 4
    /// How far the guide timeline spans, starting at the current half hour.
    /// Now the CEILING / placeholder span rather than the fixed load window —
    /// the live guide loads `initialGuideHours` up front and lazily extends.
    /// Keep in sync with `LiveTVDataStore.epgMaxHoursAhead` (the fetch ceiling).
    static let timelineSpanHours: Int = 72
    /// EPG hours fetched up front when the guide first opens. Small so the grid
    /// paints fast; `extendEPG` fills more in as the user scrolls right.
    static let initialGuideHours: Int = 6
    /// Hours pulled per lazy extension when scroll nears the loaded edge.
    static let lazyLoadChunkHours: Int = 6
    /// Fire the lazy-load request once the LEFT visible edge comes within this
    /// many minutes of the loaded end. Covers the visible width (~4 h) plus a
    /// preload buffer, while staying under the initial window so the first
    /// paint isn't immediately followed by a second fetch.
    static let lazyLoadLookaheadMinutes: Double = 300
}

// MARK: - Program helpers

private extension UnifiedProgram {
    var start: Date { startTime }
    var stop: Date { endTime }
    func isLive(at date: Date = Date()) -> Bool { date >= startTime && date < endTime }
}

// MARK: - SwiftUI wrapper

struct EPGGuide: UIViewRepresentable {
    let channels: [UnifiedChannel]
    let programsByChannel: [String: [UnifiedProgram]]
    let timelineStart: Date
    let totalMinutes: Int
    let now: Date
    let categoryTitles: [String]
    let selectedCategory: String?
    let onCategorySelect: (String?) -> Void
    /// When true the grid releases focus (e.g. an overlay is presented).
    var menuActive: Bool = false
    var onFocus: (UnifiedChannel?, UnifiedProgram?) -> Void
    var onSelect: (UnifiedChannel, UnifiedProgram?) -> Void
    /// Fired when horizontal scroll (or focus) nears the loaded right edge, so
    /// the host can fetch another chunk of EPG. Throttled to one call per
    /// loaded-window size by the coordinator. nil = no lazy loading.
    var onNeedMore: (() -> Void)? = nil
    /// Transparent overlay mode: see-through cells over an ambient backdrop.
    var transparent: Bool = true
    /// Space reserved above the time ruler (the info bar lives there).
    var topInset: CGFloat? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> EPGContainerView {
        let layout = EPGLayout()
        // The info bar's height insets the WHOLE collection view down, so a
        // focused cell can never be obscured by the info bar (the focus engine
        // keeps cells within the CV's bounds).
        let infoBarInset = topInset ?? (transparent ? 0 : EPGTheme.infoBarHeight)
        layout.topOffset = 0
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .clear
        cv.contentInsetAdjustmentBehavior = .never
        cv.contentInset = UIEdgeInsets(top: layout.gridTopInset,
                                       left: EPGTheme.channelColumnWidth,
                                       bottom: 120, right: 60)
        cv.showsVerticalScrollIndicator = false
        cv.showsHorizontalScrollIndicator = false
        cv.bounces = false
        cv.remembersLastFocusedIndexPath = true
        cv.dataSource = context.coordinator
        cv.delegate = context.coordinator
        cv.register(ProgramCellView.self, forCellWithReuseIdentifier: ProgramCellView.reuseID)
        cv.register(ChannelColumnView.self,
                    forSupplementaryViewOfKind: EPGLayout.kindChannel,
                    withReuseIdentifier: ChannelColumnView.reuseID)
        cv.register(TimeRulerView.self,
                    forSupplementaryViewOfKind: EPGLayout.kindTime,
                    withReuseIdentifier: TimeRulerView.reuseID)
        cv.register(CornerView.self,
                    forSupplementaryViewOfKind: EPGLayout.kindCorner,
                    withReuseIdentifier: CornerView.reuseID)

        context.coordinator.collectionView = cv
        context.coordinator.apply(self, to: layout)

        // Play/Pause jumps back to the now-airing programme.
        let jump = UITapGestureRecognizer(target: context.coordinator,
                                          action: #selector(Coordinator.jumpToNow))
        jump.allowedPressTypes = [NSNumber(value: UIPress.PressType.playPause.rawValue)]
        cv.addGestureRecognizer(jump)

        let container = EPGContainerView()
        container.contentTopInset = infoBarInset
        container.install(collectionView: cv)
        container.configureCategories(
            titles: categoryTitles,
            selected: selectedCategory,
            onSelect: onCategorySelect)
        container.setTransparent(transparent)
        return container
    }

    func updateUIView(_ uiView: EPGContainerView, context: Context) {
        context.coordinator.parent = self
        guard let cv = context.coordinator.collectionView,
              let layout = cv.collectionViewLayout as? EPGLayout else { return }
        uiView.isUserInteractionEnabled = !menuActive
        uiView.configureCategories(
            titles: categoryTitles,
            selected: selectedCategory,
            onSelect: onCategorySelect)
        let dataChanged = context.coordinator.apply(self, to: layout)
        if dataChanged {
            cv.reloadData()
            if transparent, !context.coordinator.didRestScroll {
                context.coordinator.didRestScroll = true
                cv.contentOffset = CGPoint(x: -EPGTheme.channelColumnWidth, y: -layout.gridTopInset)
            }
        } else {
            // Likely just `now` advanced — move the now-line without a reload.
            layout.invalidateLayout()
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        var parent: EPGGuide
        weak var collectionView: UICollectionView?
        private(set) var sections: [UnifiedChannel] = []
        private(set) var programs: [[UnifiedProgram]] = []
        private var lastSignature: Int = 0
        private var currentSection = 0
        private var pendingFocus: IndexPath?
        var didRestScroll = false
        /// The committed horizontal offset. The timeline only moves sideways on a
        /// deliberate left/right move (or drag); during channel changes and when
        /// focus enters the grid the offset is pinned here, so a programme wider
        /// than the screen can't drag the guide away from the current time.
        private var lockedX: CGFloat = 0
        private var lockedXInitialized = false
        /// Loaded-window size (parent.totalMinutes) that the last `onNeedMore`
        /// request was fired for. Throttles lazy loading to one request per
        /// window: once the window grows, the guard opens for the next edge.
        private var requestedMoreForMinutes: Int = -1
        /// While `Date() < freeScrollUntil` the timeline may scroll horizontally.
        private var freeScrollUntil: Date = .distantPast
        private(set) var currentFocusedIsLive = false

        init(_ parent: EPGGuide) { self.parent = parent }

        /// Pushes data into the layout. Returns true if channels/programs changed.
        @discardableResult
        func apply(_ p: EPGGuide, to layout: EPGLayout) -> Bool {
            let ppm = EPGTheme.pointsPerMinute
            let total = Double(p.totalMinutes)
            var rows: [[EPGLayout.Span]] = []
            var progs: [[UnifiedProgram]] = []
            var chans: [UnifiedChannel] = []

            for channel in p.channels {
                let minStart = -Double(EPGTheme.channelColumnWidth) / Double(ppm)
                let ranges = (p.programsByChannel[channel.id] ?? []).compactMap { program -> (cs: Double, ce: Double, prog: UnifiedProgram)? in
                    let startMin = program.start.timeIntervalSince(p.timelineStart) / 60
                    let endMin = program.stop.timeIntervalSince(p.timelineStart) / 60
                    guard endMin > 0, startMin < total else { return nil }
                    return (max(minStart, startMin), min(total, endMin), program)
                }.sorted { $0.cs < $1.cs }

                var spans: [EPGLayout.Span] = []
                var rowProgs: [UnifiedProgram] = []
                for (idx, r) in ranges.enumerated() {
                    let x = CGFloat(r.cs) * ppm
                    var w = CGFloat(r.ce - r.cs) * ppm
                    if idx + 1 < ranges.count {
                        w = min(w, CGFloat(ranges[idx + 1].cs) * ppm - x)
                    }
                    spans.append(EPGLayout.Span(x: x, width: max(w, 2)))
                    rowProgs.append(r.prog)
                }
                rows.append(spans)
                progs.append(rowProgs)
                chans.append(channel)
            }

            // Signature to detect data changes. Includes logoURL so a late
            // channel-logo patch triggers a reload, and per-channel programme
            // counts so EPG arriving AFTER the channels (Rivulet loads them
            // separately) reloads the grid and the rows populate.
            var sig = Hasher()
            sig.combine(p.channels.count)
            for c in p.channels {
                sig.combine(c.id)
                sig.combine(c.logoURL)
                sig.combine(p.programsByChannel[c.id]?.count ?? 0)
            }
            sig.combine(p.timelineStart)
            let signature = sig.finalize()
            let changed = signature != lastSignature
            lastSignature = signature

            sections = chans
            programs = progs
            layout.configure(rows: rows,
                             channelCount: chans.count,
                             totalMinutes: p.totalMinutes,
                             timelineStart: p.timelineStart,
                             now: p.now)
            return changed
        }

        func numberOfSections(in collectionView: UICollectionView) -> Int { programs.count }

        func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            programs[safe: section]?.count ?? 0
        }

        func collectionView(_ cv: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = cv.dequeueReusableCell(withReuseIdentifier: ProgramCellView.reuseID, for: indexPath) as! ProgramCellView
            cell.transparent = parent.transparent
            if let program = programs[safe: indexPath.section]?[safe: indexPath.item] {
                cell.configure(program)
            }
            return cell
        }

        func collectionView(_ cv: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
            switch kind {
            case EPGLayout.kindChannel:
                let v = cv.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: ChannelColumnView.reuseID, for: indexPath) as! ChannelColumnView
                if let channel = sections[safe: indexPath.section] { v.configure(channel, transparent: parent.transparent) }
                return v
            case EPGLayout.kindTime:
                let v = cv.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: TimeRulerView.reuseID, for: indexPath) as! TimeRulerView
                v.configure(start: parent.timelineStart, totalMinutes: parent.totalMinutes, transparent: parent.transparent)
                return v
            default:
                let v = cv.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: CornerView.reuseID, for: indexPath) as! CornerView
                v.configure(date: parent.timelineStart, transparent: parent.transparent)
                return v
            }
        }

        // Focus → update the info bar; hold the timeline's horizontal position
        // across channel changes so wide programmes don't drag the guide sideways.
        func collectionView(_ cv: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            guard let ip = context.nextFocusedIndexPath,
                  let channel = sections[safe: ip.section],
                  let program = programs[safe: ip.section]?[safe: ip.item] else { return }
            let now = parent.now
            currentSection = ip.section
            currentFocusedIsLive = program.isLive(at: now)
            parent.onFocus(channel, program)

            let prev = context.previouslyFocusedIndexPath
            let sameChannel = (prev != nil && prev!.section == ip.section)
            if sameChannel {
                freeScrollUntil = Date().addingTimeInterval(0.6)
            } else {
                freeScrollUntil = .distantPast
                if let layout = cv.collectionViewLayout as? EPGLayout {
                    let inset = layout.rulerBottomInset
                    let rowH = EPGTheme.rowHeight
                    let margin = rowH
                    let rowTop = CGFloat(ip.section) * rowH
                    let rowBottom = rowTop + rowH
                    let visibleTop = cv.contentOffset.y + inset
                    let visibleBottom = cv.contentOffset.y + cv.bounds.height - cv.contentInset.bottom
                    var targetY = cv.contentOffset.y
                    if rowTop - margin < visibleTop {
                        targetY = rowTop - inset - margin
                    } else if rowBottom + margin > visibleBottom {
                        let rows = ((rowBottom + margin - visibleBottom) / rowH).rounded(.up)
                        targetY = cv.contentOffset.y + rows * rowH
                    }
                    targetY = max(targetY, -cv.contentInset.top)
                    if abs(targetY - cv.contentOffset.y) > 0.5 || abs(lockedX - cv.contentOffset.x) > 0.5 {
                        cv.setContentOffset(CGPoint(x: lockedX, y: targetY), animated: true)
                    }
                }
            }
        }

        /// Hold Left at the start of the timeline instead of letting it escape
        /// to the sidebar. `apply` builds one section per channel and sorts that
        /// channel's programmes by start time, so `item == 0` is the earliest
        /// programme in the row: the leftmost cell. There is nothing focusable
        /// to its left, so the focus engine walks up the chain and hands focus
        /// to the enclosing `.sidebarAdaptable` TabView. That is the sidebar
        /// opening on its own, which is what makes the guide feel like it
        /// cannot be scrolled back left once the user has moved right.
        ///
        /// This is deliberately `shouldUpdateFocusIn` and NOT `pressesBegan`.
        /// Siri Remote swipes arrive as indirect touches and never synthesize
        /// arrow `UIPress` events, so a press handler would only catch the
        /// click wheel (and a keyboard in the Simulator) and would silently do
        /// nothing for anyone who swipes. Both input paths ultimately request a
        /// focus update, so vetoing here covers both.
        ///
        /// There is also no backward scrolling to offer. `setupStartTime` pins
        /// `timelineStart` to the current half hour and fetching only ever runs
        /// forward, so there is no past programming loaded to reveal; scrolling
        /// left would just expose empty grid. Do not "fix" this by allowing the
        /// move through. The edge is a real boundary, not a missing feature.
        func collectionView(_ collectionView: UICollectionView,
                            shouldUpdateFocusIn context: UICollectionViewFocusUpdateContext) -> Bool {
            guard context.focusHeading == .left,
                  let prev = context.previouslyFocusedIndexPath,
                  prev.item == 0
            else { return true }

            // Only swallow the move when focus is actually leaving the grid. If
            // the engine already found another cell inside the collection view
            // it has picked a sensible neighbour and we stay out of its way.
            let nextIsInside = context.nextFocusedView?.isDescendant(of: collectionView) ?? false
            guard !nextIsInside else { return true }

            // A plain no-op. Only `.left` headings reach here, so Up, Down and
            // Right at this same cell are untouched, and Menu is not a focus
            // heading at all and still escapes to the sidebar as usual.
            return false
        }

        // Snap horizontal scrolling so a full 30-min cell sits next to the date.
        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                       targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            targetContentOffset.pointee.x = Coordinator.snappedX(for: targetContentOffset.pointee.x)
            if let layout = collectionView?.collectionViewLayout as? EPGLayout {
                let inset = layout.rulerBottomInset
                let rowH = EPGTheme.rowHeight
                let y = targetContentOffset.pointee.y
                targetContentOffset.pointee.y = (((y + inset) / rowH).rounded() * rowH) - inset
            }
        }

        /// Offset whose left grid edge lands on a 30-minute boundary.
        static func snappedX(for x: CGFloat) -> CGFloat {
            let slot = 30 * EPGTheme.pointsPerMinute
            let colW = EPGTheme.channelColumnWidth
            let snappedLeft = ((x + colW) / slot).rounded() * slot
            return snappedLeft - colW
        }

        // Update the date box as the visible time crosses into another day.
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let cv = collectionView else { return }
            if !lockedXInitialized { lockedX = cv.contentOffset.x; lockedXInitialized = true }
            if cv.isDragging || cv.isDecelerating || Date() < freeScrollUntil {
                lockedX = cv.contentOffset.x
            } else if abs(cv.contentOffset.x - lockedX) > 0.5 {
                cv.contentOffset.x = lockedX
            }
            let minutesIn = (cv.contentOffset.x + EPGTheme.channelColumnWidth) / EPGTheme.pointsPerMinute
            let leftDate = parent.timelineStart.addingTimeInterval(Double(minutesIn) * 60)
            if let corner = cv.supplementaryView(forElementKind: EPGLayout.kindCorner,
                                                 at: IndexPath(item: 0, section: 0)) as? CornerView {
                corner.configure(date: leftDate, transparent: parent.transparent)
            }
            maybeRequestMore(leftMinutes: Double(minutesIn))
        }

        /// Lazy horizontal loading: when the left visible edge comes within the
        /// look-ahead window of the loaded end, ask the host for more EPG. The
        /// `requestedMoreForMinutes` guard fires at most once per loaded-window
        /// size, so a scroll that lingers near the edge does not spam requests;
        /// the guard reopens when the window grows and totalMinutes changes.
        private func maybeRequestMore(leftMinutes: Double) {
            guard parent.onNeedMore != nil,
                  requestedMoreForMinutes != parent.totalMinutes,
                  Double(parent.totalMinutes) - leftMinutes < EPGTheme.lazyLoadLookaheadMinutes
            else { return }
            requestedMoreForMinutes = parent.totalMinutes
            parent.onNeedMore?()
        }

        func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard let channel = sections[safe: indexPath.section] else { return }
            let now = parent.now
            let row = programs[safe: indexPath.section] ?? []
            let current = row.first { $0.isLive(at: now) } ?? row.last { $0.start <= now }
            // Hand selection back to SwiftUI, which launches Rivulet's player.
            parent.onSelect(channel, current)
        }

        // Play/Pause → move focus to the now-playing programme in the current row.
        @objc func jumpToNow() {
            guard let cv = collectionView,
                  currentSection < programs.count else { return }
            let row = programs[currentSection]
            let now = parent.now
            let item = row.firstIndex { $0.isLive(at: now) }
                ?? row.lastIndex { $0.start <= now }
                ?? 0
            guard !row.isEmpty else { return }
            pendingFocus = IndexPath(item: item, section: currentSection)
            cv.setNeedsFocusUpdate()
            cv.updateFocusIfNeeded()
        }

        func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
            defer { pendingFocus = nil }
            return pendingFocus
        }
    }
}

// Note: `Array.subscript(safe:)` is defined in MultiStreamViewModel.swift and
// reused here.

// MARK: - Container (collection view + fade under the column)

final class EPGContainerView: UIView {
    private var collectionView: UICollectionView?
    private let categoryBar = GuideCategoryBarView()
    private weak var pendingGridFocusTarget: UIView?
    private weak var pendingCategoryFocusTarget: UIView?
    private var gridUpSwipeBinding: DirectionalInputBinding?
    private let timeFade = CAGradientLayer()
    private let bottomFade = CAGradientLayer()
    private let rightFade = CAGradientLayer()
    /// The grid starts this far below the top, so the info bar above it can never
    /// obscure a focused cell.
    var contentTopInset: CGFloat = 0 { didSet { setNeedsLayout() } }

    /// Transparent overlay mode hides the page-coloured fades (they'd dim video).
    func setTransparent(_ t: Bool) {
        timeFade.isHidden = t
        bottomFade.isHidden = t
        rightFade.isHidden = t
    }

    func install(collectionView cv: UICollectionView) {
        self.collectionView = cv
        addSubview(cv)
        addSubview(categoryBar)
        categoryBar.onMoveDown = { [weak self] in self?.moveFocusIntoGrid() }
        gridUpSwipeBinding = DirectionalInputBinding(
            gatedSwipesOn: cv,
            directions: [.up],
            shouldHandle: { [weak cv] direction in
                guard direction == .up, let cv,
                      let focused = UIFocusSystem.focusSystem(for: cv)?.focusedItem as? UICollectionViewCell,
                      let indexPath = cv.indexPath(for: focused)
                else { return false }
                return indexPath.section == 0
            },
            onSwipe: { [weak self] _ in
                self?.moveFocusToCategories()
            })

        let bg = UIColor(EPGTheme.background)

        timeFade.colors = [bg.cgColor, bg.withAlphaComponent(0).cgColor]
        timeFade.startPoint = CGPoint(x: 0.5, y: 0)
        timeFade.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(timeFade)

        bottomFade.colors = [bg.withAlphaComponent(0).cgColor, bg.cgColor]
        bottomFade.startPoint = CGPoint(x: 0.5, y: 0)
        bottomFade.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(bottomFade)

        rightFade.colors = [bg.withAlphaComponent(0).cgColor, bg.cgColor]
        rightFade.startPoint = CGPoint(x: 0, y: 0.5)
        rightFade.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(rightFade)
    }

    func configureCategories(
        titles: [String],
        selected: String?,
        onSelect: @escaping (String?) -> Void
    ) {
        categoryBar.configure(titles: titles, selected: selected, onSelect: onSelect)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let pendingGridFocusTarget {
            return [pendingGridFocusTarget]
        }
        if let pendingCategoryFocusTarget {
            return [pendingCategoryFocusTarget]
        }
        return super.preferredFocusEnvironments
    }

    /// Complete the category-to-grid handoff after the directional focus update
    /// that requested it has ended. Calling `updateFocusIfNeeded` inline from a
    /// focus delegate is ignored by UIKit because an update is already active.
    private func moveFocusIntoGrid() {
        guard pendingGridFocusTarget == nil, let cv = collectionView else { return }
        cv.layoutIfNeeded()
        pendingGridFocusTarget = firstVisibleProgramCell(in: cv) ?? cv

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setNeedsFocusUpdate()
            self.updateFocusIfNeeded()
            self.pendingGridFocusTarget = nil
        }
    }

    /// Symmetric boundary handoff from the top programme row back to the last
    /// focused category pill. Called only for a declined Up press or a gated
    /// indirect-touch Up swipe while section zero owns focus.
    func moveFocusToCategories() {
        guard pendingCategoryFocusTarget == nil,
              let target = categoryBar.preferredFocusTarget()
        else { return }
        pendingCategoryFocusTarget = target

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setNeedsFocusUpdate()
            self.updateFocusIfNeeded()
            self.pendingCategoryFocusTarget = nil
        }
    }

    /// Prefer the programme crossing the visible timeline's leading edge in
    /// the first visible channel row. This is the natural "current programme"
    /// landing point even when an almost-finished cell is only a few points wide.
    private func firstVisibleProgramCell(in cv: UICollectionView) -> UIView? {
        let visible = cv.indexPathsForVisibleItems
        guard let firstSection = visible.map(\.section).min() else { return nil }
        let entryX = cv.contentOffset.x + EPGTheme.channelColumnWidth + EPGTheme.cellSpacing

        let target = visible
            .filter { $0.section == firstSection }
            .min { lhs, rhs in
                distance(from: entryX, to: cv.layoutAttributesForItem(at: lhs)?.frame)
                    < distance(from: entryX, to: cv.layoutAttributesForItem(at: rhs)?.frame)
            }
        return target.flatMap { cv.cellForItem(at: $0) }
    }

    private func distance(from x: CGFloat, to frame: CGRect?) -> CGFloat {
        guard let frame else { return .greatestFiniteMagnitude }
        if frame.minX...frame.maxX ~= x { return 0 }
        return min(abs(x - frame.minX), abs(x - frame.maxX))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        categoryBar.frame = CGRect(
            x: 0,
            y: EPGTheme.infoBarHeight,
            width: bounds.width,
            height: EPGTheme.categoryBarHeight)
        collectionView?.frame = CGRect(x: 0, y: contentTopInset,
                                       width: bounds.width,
                                       height: max(bounds.height - contentTopInset, 0))
        let top = EPGTheme.rulerTop + EPGTheme.timelineHeight
        timeFade.frame = CGRect(x: 0, y: top, width: bounds.width, height: 16)
        bottomFade.frame = CGRect(x: 0, y: bounds.height - 70, width: bounds.width, height: 70)
        rightFade.frame = CGRect(x: bounds.width - 48, y: top, width: 48, height: bounds.height - top)
    }
}

// MARK: - UIKit category bar

/// Native category pills hosted beside the native programme collection view.
/// Keeping both focusable regions in one UIKit environment lets tvOS move Down
/// into the guide and Up back to the filters without a cross-framework bridge.
final class GuideCategoryBarView: UIView {
    private struct Item: Equatable {
        let title: String
        let group: String?
    }

    private var items: [Item] = []
    private var selectedGroup: String?
    private var onSelect: ((String?) -> Void)?
    private var lastFocusedIndexPath: IndexPath?
    var onMoveDown: (() -> Void)?
    private var downSwipeBinding: DirectionalInputBinding?

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 14
        layout.minimumInteritemSpacing = 14
        layout.sectionInset = UIEdgeInsets(
            top: 10,
            left: EPGTheme.cellSpacing,
            bottom: 10,
            right: 60)

        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.contentInsetAdjustmentBehavior = .never
        view.showsHorizontalScrollIndicator = false
        view.showsVerticalScrollIndicator = false
        view.remembersLastFocusedIndexPath = true
        view.dataSource = self
        view.delegate = self
        view.register(
            GuideCategoryPillCell.self,
            forCellWithReuseIdentifier: GuideCategoryPillCell.reuseIdentifier)
        return view
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(collectionView)
        downSwipeBinding = DirectionalInputBinding(
            gatedSwipesOn: collectionView,
            directions: [.down],
            shouldHandle: { [weak self] direction in
                guard let self else { return false }
                let focused = UIFocusSystem.focusSystem(for: self)?.focusedItem as? UIView
                return direction == .down
                    && (focused?.isDescendant(of: self.collectionView) ?? false)
            },
            onSwipe: { [weak self] _ in
                self?.onMoveDown?()
            })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        collectionView.frame = bounds
    }

    func configure(
        titles: [String],
        selected: String?,
        onSelect: @escaping (String?) -> Void
    ) {
        let nextItems = [Item(title: "All Channels", group: nil)]
            + titles.map { Item(title: $0, group: $0) }
        let itemsChanged = items != nextItems
        let selectionChanged = selectedGroup != selected

        items = nextItems
        selectedGroup = selected
        self.onSelect = onSelect

        if itemsChanged {
            collectionView.reloadData()
        } else if selectionChanged {
            refreshVisiblePills()
        }
    }

    private func refreshVisiblePills() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let item = items[safe: indexPath.item],
                  let cell = collectionView.cellForItem(at: indexPath) as? GuideCategoryPillCell
            else { continue }
            cell.configure(title: item.title, selected: item.group == selectedGroup)
        }
    }

    func preferredFocusTarget() -> UIView? {
        collectionView.layoutIfNeeded()
        let selectedIndex = items.firstIndex { $0.group == selectedGroup }
            .map { IndexPath(item: $0, section: 0) }
        let targetIndex = lastFocusedIndexPath ?? selectedIndex ?? IndexPath(item: 0, section: 0)
        return collectionView.cellForItem(at: targetIndex)
    }
}

extension GuideCategoryBarView: UICollectionViewDataSource,
                                UICollectionViewDelegate,
                                UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: GuideCategoryPillCell.reuseIdentifier,
            for: indexPath) as! GuideCategoryPillCell
        if let item = items[safe: indexPath.item] {
            cell.configure(title: item.title, selected: item.group == selectedGroup)
        }
        cell.onDeclinedDownPress = { [weak self] in
            self?.onMoveDown?()
        }
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        guard let title = items[safe: indexPath.item]?.title else { return .zero }
        let font = UIFont.systemFont(ofSize: 24, weight: .semibold)
        let width = ceil((title as NSString).size(withAttributes: [.font: font]).width) + 44
        return CGSize(width: width, height: 44)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = items[safe: indexPath.item],
              item.group != selectedGroup
        else { return }
        onSelect?(item.group)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
        with coordinator: UIFocusAnimationCoordinator
    ) {
        if let next = context.nextFocusedIndexPath { lastFocusedIndexPath = next }
    }
}

final class GuideCategoryPillCell: UICollectionViewCell {
    static let reuseIdentifier = "GuideCategoryPillCell"

    private let titleLabel = UILabel()
    private var selectedCategory = false
    var onDeclinedDownPress: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        contentView.layer.cornerRadius = 22
        contentView.layer.cornerCurve = .continuous
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -22),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHighlighted: Bool {
        didSet { contentView.alpha = isHighlighted ? 0.75 : 1 }
    }

    /// Discrete arrows reach the focused responder only when the focus engine
    /// declines to move. That is precisely the dead-end handoff we need here;
    /// touch-remotes use the gated swipe twin installed on the category bar.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .downArrow }) {
            onDeclinedDownPress?()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    func configure(title: String, selected: Bool) {
        titleLabel.text = title
        selectedCategory = selected
        applyAppearance(focused: isFocused)
    }

    override func didUpdateFocus(
        in context: UIFocusUpdateContext,
        with coordinator: UIFocusAnimationCoordinator
    ) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations { self.applyAppearance(focused: focused) }
    }

    private func applyAppearance(focused: Bool) {
        if selectedCategory {
            contentView.backgroundColor = .white
            titleLabel.textColor = UIColor(EPGTheme.background)
        } else if focused {
            contentView.backgroundColor = UIColor.white.withAlphaComponent(0.22)
            titleLabel.textColor = .white
        } else {
            contentView.backgroundColor = .clear
            titleLabel.textColor = UIColor(EPGTheme.textSecondary)
        }
    }
}

// MARK: - Custom layout

/// Cell attributes that also carry how far to push the title in so it stays
/// visible when the cell is partly tucked under the column / off the left edge.
final class EPGCellAttributes: UICollectionViewLayoutAttributes {
    var titleInset: CGFloat = 0
    var leftClip: CGFloat = 0
    var topClip: CGFloat = 0
    var pastWidth: CGFloat = 0

    override func copy(with zone: NSZone? = nil) -> Any {
        let c = super.copy(with: zone) as! EPGCellAttributes
        c.titleInset = titleInset
        c.leftClip = leftClip
        c.topClip = topClip
        c.pastWidth = pastWidth
        return c
    }
    override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? EPGCellAttributes else { return false }
        return super.isEqual(object) && o.titleInset == titleInset
            && o.leftClip == leftClip && o.topClip == topClip
            && o.pastWidth == pastWidth
    }
}

final class EPGLayout: UICollectionViewLayout {
    struct Span { let x: CGFloat; let width: CGFloat }

    override class var layoutAttributesClass: AnyClass { EPGCellAttributes.self }

    static let kindChannel = "channel"
    static let kindTime = "time"
    static let kindCorner = "corner"

    private var rows: [[Span]] = []
    private var channelCount = 0
    private var totalMinutes = 0
    private var timelineStart = Date()
    private var now = Date()

    private let colW = EPGTheme.channelColumnWidth
    private let rowH = EPGTheme.rowHeight
    private let headerH = EPGTheme.timelineHeight
    var topOffset: CGFloat = EPGTheme.infoBarHeight
    private var rulerTop: CGFloat { topOffset + EPGTheme.rulerGap }
    var gridTopInset: CGFloat { rulerTop + EPGTheme.timelineHeight + EPGTheme.gridTopGap }
    var rulerBottomInset: CGFloat { rulerTop + headerH }
    private let ppm = EPGTheme.pointsPerMinute
    private let gap = EPGTheme.cellSpacing

    override init() {
        super.init()
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(rows: [[Span]], channelCount: Int, totalMinutes: Int,
                   timelineStart: Date, now: Date) {
        self.rows = rows
        self.channelCount = channelCount
        self.totalMinutes = totalMinutes
        self.timelineStart = timelineStart
        self.now = now
        invalidateLayout()
    }

    private var contentWidth: CGFloat { CGFloat(totalMinutes) * ppm }
    private var contentHeight: CGFloat { CGFloat(channelCount) * rowH }

    override var collectionViewContentSize: CGSize {
        CGSize(width: contentWidth, height: contentHeight)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { true }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let span = rows[safe: indexPath.section]?[safe: indexPath.item] else { return nil }
        let frameX = span.x + gap
        let frameY = CGFloat(indexPath.section) * rowH + gap
        let width = max(span.width - gap * 2, 1)
        let height = rowH - gap * 2
        let a = EPGCellAttributes(forCellWith: indexPath)
        a.frame = CGRect(x: frameX, y: frameY, width: width, height: height)
        a.zIndex = 0
        let nowX = CGFloat(now.timeIntervalSince(timelineStart) / 60) * ppm
        a.pastWidth = min(max(nowX - frameX, 0), width)
        if let off = collectionView?.contentOffset {
            let visibleLeft = off.x + colW + gap
            let raw = visibleLeft - frameX
            a.titleInset = min(max(0, raw), max(0, width - 120))
            a.leftClip = min(max(0, raw), width)
            let visibleTop = off.y + rulerTop + headerH + gap
            a.topClip = min(max(0, visibleTop - frameY), height)
        }
        return a
    }

    override func layoutAttributesForSupplementaryView(ofKind elementKind: String, at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let cv = collectionView else { return nil }
        let off = cv.contentOffset
        let a = EPGCellAttributes(forSupplementaryViewOfKind: elementKind, with: indexPath)
        switch elementKind {
        case Self.kindChannel:
            // Use the exact same vertical frame as the programme cells. Keeping
            // the row inset in layout attributes (rather than applying it later
            // inside the supplementary view) avoids a subtle top-row rounding /
            // clipping mismatch at the pinned ruler edge.
            let frameY = CGFloat(indexPath.section) * rowH + gap
            a.frame = CGRect(x: off.x, y: frameY, width: colW, height: rowH - gap * 2)
            a.zIndex = 10
            let visibleTop = off.y + rulerTop + headerH + gap
            a.topClip = min(max(0, visibleTop - frameY), a.frame.height)
        case Self.kindTime:
            a.frame = CGRect(x: 0, y: off.y + rulerTop, width: contentWidth, height: headerH)
            a.zIndex = 12
            a.leftClip = max(0, colW + off.x)
        case Self.kindCorner:
            a.frame = CGRect(x: off.x, y: off.y + rulerTop, width: colW, height: headerH)
            a.zIndex = 20
        default:
            return nil
        }
        return a
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard channelCount > 0 else { return nil }
        var result: [UICollectionViewLayoutAttributes] = []

        let first = max(0, Int(rect.minY / rowH))
        let last = min(channelCount - 1, Int(rect.maxY / rowH))
        if last >= first {
            for s in first...last {
                for (i, span) in (rows[safe: s] ?? []).enumerated() where span.x <= rect.maxX && (span.x + span.width) >= rect.minX {
                    if let a = layoutAttributesForItem(at: IndexPath(item: i, section: s)) { result.append(a) }
                }
                if let c = layoutAttributesForSupplementaryView(ofKind: Self.kindChannel, at: IndexPath(item: 0, section: s)) {
                    result.append(c)
                }
            }
        }
        if let t = layoutAttributesForSupplementaryView(ofKind: Self.kindTime, at: IndexPath(item: 0, section: 0)) { result.append(t) }
        if let cor = layoutAttributesForSupplementaryView(ofKind: Self.kindCorner, at: IndexPath(item: 0, section: 0)) { result.append(cor) }
        return result
    }
}

// MARK: - Cells

final class ProgramCellView: UICollectionViewCell {
    static let reuseID = "ProgramCellView"
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let stack = UIStackView()
    private let card = UIView()
    private var stackLeading: NSLayoutConstraint!
    private let baseLeading: CGFloat = 14

    /// Hide text below this width so short programmes stay blank (no overlap).
    private let minTextWidth: CGFloat = 96

    /// When true (overlay), cells are see-through over the video.
    var transparent = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.backgroundColor = .clear
        card.layer.cornerRadius = EPGTheme.columnCorner
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        elapsedLayer.backgroundColor = UIColor(white: 1, alpha: 0.07).cgColor
        elapsedLayer.isHidden = true
        card.layer.insertSublayer(elapsedLayer, at: 0)

        titleLabel.font = .systemFont(ofSize: 23, weight: .semibold)
        titleLabel.textColor = UIColor(EPGTheme.textPrimary)
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 19, weight: .regular)
        subtitleLabel.textColor = UIColor(EPGTheme.textSecondary)
        subtitleLabel.numberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail

        stack.axis = .vertical
        stack.spacing = 2
        stack.alignment = .leading
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        stackLeading = stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: baseLeading)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stackLeading,
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private let elapsedLayer = CALayer()
    private var pastWidth: CGFloat = 0

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        let attrs = layoutAttributes as? EPGCellAttributes
        stackLeading.constant = baseLeading + (attrs?.titleInset ?? 0)
        leftClip = attrs?.leftClip ?? 0
        topClip = attrs?.topClip ?? 0
        pastWidth = attrs?.pastWidth ?? 0
        applyClip()
        applyElapsed()
    }

    private func applyElapsed() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let w = min(pastWidth, bounds.width)
        elapsedLayer.frame = CGRect(x: 0, y: 0, width: max(w, 0), height: bounds.height)
        elapsedLayer.isHidden = w <= 0.5
        CATransaction.commit()
    }

    private var leftClip: CGFloat = 0
    private var topClip: CGFloat = 0
    private let clipMask = CAShapeLayer()
    private func applyClip() {
        guard transparent, bounds.width > 0, bounds.height > 0,
              (leftClip > 0 || topClip > 0) else {
            contentView.layer.mask = nil
            return
        }
        let rect = CGRect(x: leftClip, y: topClip,
                          width: max(bounds.width - leftClip, 0),
                          height: max(bounds.height - topClip, 0))
        var corners: UIRectCorner = []
        if leftClip > 0 { corners.formUnion([.topLeft, .bottomLeft]) }
        if topClip > 0 { corners.formUnion([.topLeft, .topRight]) }
        let r = EPGTheme.columnCorner
        clipMask.path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners,
                                     cornerRadii: CGSize(width: r, height: r)).cgPath
        contentView.layer.mask = clipMask
    }

    func configure(_ program: UnifiedProgram) {
        titleLabel.text = program.title
        let sub = program.subtitle
        subtitleLabel.text = sub
        subtitleLabel.isHidden = (sub?.isEmpty ?? true)
        applyFocus(false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        stack.isHidden = bounds.width < minTextWidth
        applyClip()
        applyElapsed()
    }

    override var canBecomeFocused: Bool { true }

    /// An Up arrow reaches the focused cell only after the focus engine has
    /// declined it. At section zero, hand it back to the category collection;
    /// all other presses continue through the normal responder chain.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .upArrow }),
           let cv = enclosingCollectionView,
           cv.indexPath(for: self)?.section == 0,
           let container = enclosingEPGContainer {
            container.moveFocusToCategories()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    private var enclosingCollectionView: UICollectionView? {
        var view = superview
        while let current = view {
            if let collection = current as? UICollectionView { return collection }
            view = current.superview
        }
        return nil
    }

    private var enclosingEPGContainer: EPGContainerView? {
        var view = superview
        while let current = view {
            if let container = current as? EPGContainerView { return container }
            view = current.superview
        }
        return nil
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = (context.nextFocusedView == self)
        coordinator.addCoordinatedAnimations({ self.applyFocus(focused) })
    }

    private func applyFocus(_ focused: Bool) {
        card.backgroundColor = focused ? UIColor(white: 0.96, alpha: 1) : UIColor(white: 0, alpha: 0.32)
        titleLabel.textColor = focused ? UIColor(white: 0.08, alpha: 1) : .white
        subtitleLabel.textColor = focused ? UIColor(white: 0.08, alpha: 0.6) : UIColor(white: 1, alpha: 0.7)
    }
}

final class ChannelColumnView: UICollectionReusableView {
    static let reuseID = "ChannelColumnView"
    private let occluder = UIView()   // opaque; rounded only on the right
    private let box = UIView()        // coloured logo box; rounded all corners
    private let logo = UIImageView()
    private var logoLoadTask: Task<Void, Never>?
    private var currentLogoURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)

        occluder.backgroundColor = UIColor(EPGTheme.background)
        occluder.layer.cornerRadius = EPGTheme.columnCorner
        occluder.layer.cornerCurve = .continuous
        occluder.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        occluder.layer.masksToBounds = true
        occluder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(occluder)

        box.backgroundColor = UIColor(EPGTheme.columnFill)
        box.layer.cornerRadius = EPGTheme.columnCorner
        box.layer.cornerCurve = .continuous
        box.layer.masksToBounds = true
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)

        logo.contentMode = .scaleAspectFit
        logo.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(logo)

        let gap = EPGTheme.cellSpacing
        NSLayoutConstraint.activate([
            occluder.topAnchor.constraint(equalTo: topAnchor),
            occluder.bottomAnchor.constraint(equalTo: bottomAnchor),
            occluder.leadingAnchor.constraint(equalTo: leadingAnchor),
            occluder.trailingAnchor.constraint(equalTo: trailingAnchor),

            box.topAnchor.constraint(equalTo: topAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor),
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gap),
            box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -gap),

            logo.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 86),
            logo.heightAnchor.constraint(equalToConstant: 62),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ channel: UnifiedChannel, transparent: Bool = false) {
        occluder.backgroundColor = transparent ? .clear : UIColor(EPGTheme.background)
        box.backgroundColor = transparent ? UIColor(white: 0, alpha: 0.28) : UIColor(EPGTheme.columnFill)

        // Reused cells get reconfigured rapidly during fast guide scrolling.
        // Track the URL each in-flight load belongs to and cancel on change,
        // so a slow response can never land its logo on the wrong channel.
        let nextLogoURL = channel.logoURL
        if let nextLogoURL,
           currentLogoURL == nextLogoURL,
           logo.image != nil || logoLoadTask != nil {
            return
        }

        logoLoadTask?.cancel()
        logoLoadTask = nil
        logo.image = nil
        currentLogoURL = nextLogoURL
        guard let url = currentLogoURL else { return }

        logoLoadTask = Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url, quality: .thumb)
            guard let self,
                  !Task.isCancelled,
                  self.currentLogoURL == url
            else { return }
            self.logo.image = image
            self.logoLoadTask = nil
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        logoLoadTask?.cancel()
        logoLoadTask = nil
        currentLogoURL = nil
        logo.image = nil
    }

    private var topClip: CGFloat = 0
    private let clipMask = CAShapeLayer()
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        topClip = (layoutAttributes as? EPGCellAttributes)?.topClip ?? 0
        applyClip()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        applyClip()
    }
    private func applyClip() {
        let gap = EPGTheme.cellSpacing
        guard topClip > 0.5, bounds.height > 0 else { layer.mask = nil; return }
        let rect = CGRect(x: gap, y: topClip,
                          width: max(bounds.width - gap * 2, 0),
                          height: max(bounds.height - topClip, 0))
        let r = EPGTheme.columnCorner
        clipMask.path = UIBezierPath(roundedRect: rect, byRoundingCorners: [.topLeft, .topRight],
                                     cornerRadii: CGSize(width: r, height: r)).cgPath
        layer.mask = clipMask
    }
}

final class TimeRulerView: UICollectionReusableView {
    static let reuseID = "TimeRulerView"
    private var boxes: [UIView] = []
    private var start = Date()
    private var totalMinutes = 0
    private var transparent = false

    func configure(start: Date, totalMinutes: Int, transparent: Bool = false) {
        backgroundColor = transparent ? .clear : UIColor(EPGTheme.background)
        guard start != self.start || totalMinutes != self.totalMinutes || transparent != self.transparent else { return }
        self.start = start
        self.totalMinutes = totalMinutes
        self.transparent = transparent
        boxes.forEach { $0.removeFromSuperview() }
        boxes.removeAll()

        let ppm = EPGTheme.pointsPerMinute
        let gap = EPGTheme.cellSpacing
        let slot = 30
        let fill = transparent ? UIColor(white: 0, alpha: 0.28) : UIColor(EPGTheme.columnFill)
        let boxH = EPGTheme.timelineBoxHeight
        var minute = 0
        while minute < totalMinutes {
            let box = UIView()
            box.backgroundColor = fill
            box.layer.cornerRadius = EPGTheme.columnCorner
            box.layer.cornerCurve = .continuous
            box.frame = CGRect(x: CGFloat(minute) * ppm + gap,
                               y: EPGTheme.timelineHeight - gap - boxH,
                               width: CGFloat(slot) * ppm - gap * 2, height: boxH)
            let label = UILabel()
            label.font = .systemFont(ofSize: 18, weight: .semibold)
            label.textColor = .white
            label.text = start.addingTimeInterval(Double(minute) * 60)
                .formatted(.dateTime.hour().minute())
            label.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
                label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            ])
            addSubview(box)
            boxes.append(box)
            minute += slot
        }
    }

    private var leftClip: CGFloat = 0
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        leftClip = (layoutAttributes as? EPGCellAttributes)?.leftClip ?? 0
        applyClip()
    }
    override func layoutSubviews() { super.layoutSubviews(); applyClip() }
    private func applyClip() {
        guard leftClip > 0, bounds.width > leftClip else { layer.mask = nil; return }
        let m = CALayer()
        m.backgroundColor = UIColor.white.cgColor
        m.frame = CGRect(x: leftClip, y: 0, width: bounds.width - leftClip, height: bounds.height)
        layer.mask = m
    }
}

final class CornerView: UICollectionReusableView {
    static let reuseID = "CornerView"
    private let box = UIView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        box.layer.cornerRadius = EPGTheme.columnCorner
        box.layer.cornerCurve = .continuous
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        label.font = .systemFont(ofSize: 20, weight: .bold)
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)

        let gap = EPGTheme.cellSpacing
        let boxH = EPGTheme.timelineBoxHeight
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gap),
            box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -gap),
            box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -gap),
            box.heightAnchor.constraint(equalToConstant: boxH),
            label.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Shows "TODAY" when the timeline starts today, otherwise the weekday.
    func configure(date d: Date, transparent: Bool = false) {
        box.backgroundColor = transparent ? UIColor(white: 0, alpha: 0.28) : UIColor(EPGTheme.columnFill)
        if Calendar.current.isDateInToday(d) {
            label.text = "TODAY"
        } else {
            label.text = d.formatted(.dateTime.weekday(.abbreviated)).uppercased()
        }
    }
}

// MARK: - Info bar

/// Plex-style guide header: a poster + details on the left, scrolling beneath
/// the grid. Uses the focused programme's icon (from XMLTV) or the channel logo.
struct GuideInfoBar: View {
    let channel: UnifiedChannel?
    let program: UnifiedProgram?

    /// Programme artwork for the poster, prioritising a 2:3 portrait image and
    /// falling back to any programme icon. The channel logo is handled
    /// separately so it can be letterboxed into a 2:3 frame.
    private var programImageURL: URL? {
        program?.posterURL ?? program?.iconURL
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Fixed poster height; width follows the image's own aspect ratio so a
    /// 2:3 poster shows 2:3 and a 16:9 fallback shows 16:9 (never cropped).
    private let posterHeight: CGFloat = 252

    private var content: some View {
        HStack(alignment: .top, spacing: 30) {
            poster

            VStack(alignment: .leading, spacing: 10) {
                if let channel {
                    Text(channelLine(channel))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(EPGTheme.textSecondary)
                }
                Text(program?.title ?? "Select a programme")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(EPGTheme.textPrimary)
                    .lineLimit(1)
                if let program {
                    Text(timeRange(program))
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(EPGTheme.textSecondary)
                }
                if let desc = program?.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 22))
                        .foregroundStyle(EPGTheme.textSecondary)
                        .lineLimit(3)
                        .frame(maxWidth: 820, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, EPGTheme.cellSpacing)
        .padding(.trailing, 48)
        .padding(.top, 39)
        .padding(.bottom, 9)
    }

    /// 2:3 poster box width.
    private var posterWidth: CGFloat { posterHeight * 2.0 / 3.0 }

    /// Fixed 2:3 poster slot. Everything (programme artwork, the logo fallback,
    /// the placeholder) is aspect-fit into the same frame, so the layout never
    /// jumps when an image finishes loading, and nothing is stretched or cropped
    /// (wider images get transparent bars).
    @ViewBuilder private var poster: some View {
        ZStack {
            EPGTheme.surface            // blank grey 2:3 card behind the artwork
            posterContent
        }
        .frame(width: posterWidth, height: posterHeight)
        .clipShape(RoundedRectangle(cornerRadius: EPGTheme.columnCorner))
        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
    }

    @ViewBuilder private var posterContent: some View {
        if let url = programImageURL {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fit)
                default:
                    logoInset
                }
            }
        } else {
            logoInset
        }
    }

    /// Channel logo (or a glyph) inset on the blank grey card with padding, fit
    /// without stretching or cropping.
    @ViewBuilder private var logoInset: some View {
        if let logo = channel?.logoURL {
            CachedAsyncImage(url: logo) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fit).padding(24)
                default:
                    placeholderGlyph
                }
            }
        } else {
            placeholderGlyph
        }
    }

    /// Placeholder glyph, shown while loading or when no artwork/logo exists.
    private var placeholderGlyph: some View {
        Image(systemName: "tv").font(.system(size: 40)).foregroundStyle(EPGTheme.textSecondary)
    }

    private func channelLine(_ channel: UnifiedChannel) -> String {
        if let number = channel.channelNumber { return "\(number) · \(channel.name)" }
        return channel.name
    }

    private func timeRange(_ program: UnifiedProgram) -> String {
        let f = Date.FormatStyle.dateTime.hour().minute()
        return "\(program.startTime.formatted(f)) — \(program.endTime.formatted(f))"
    }
}
