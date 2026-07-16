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
    static let timelineSpanHours: Int = 24
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
    /// When true the grid releases focus (e.g. an overlay is presented).
    var menuActive: Bool = false
    var onFocus: (UnifiedChannel?, UnifiedProgram?) -> Void
    var onSelect: (UnifiedChannel, UnifiedProgram?) -> Void
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
        container.setTransparent(transparent)
        return container
    }

    func updateUIView(_ uiView: EPGContainerView, context: Context) {
        context.coordinator.parent = self
        guard let cv = context.coordinator.collectionView,
              let layout = cv.collectionViewLayout as? EPGLayout else { return }
        cv.isUserInteractionEnabled = !menuActive
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

    override func layoutSubviews() {
        super.layoutSubviews()
        collectionView?.frame = CGRect(x: 0, y: contentTopInset,
                                       width: bounds.width,
                                       height: max(bounds.height - contentTopInset, 0))
        let top = EPGTheme.rulerTop + EPGTheme.timelineHeight
        timeFade.frame = CGRect(x: 0, y: top, width: bounds.width, height: 16)
        bottomFade.frame = CGRect(x: 0, y: bounds.height - 70, width: bounds.width, height: 70)
        rightFade.frame = CGRect(x: bounds.width - 48, y: top, width: 48, height: bounds.height - top)
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
            let slotTop = CGFloat(indexPath.section) * rowH
            a.frame = CGRect(x: off.x, y: slotTop, width: colW, height: rowH)
            a.zIndex = 10
            let visibleTop = off.y + rulerTop + headerH + gap
            a.topClip = min(max(0, visibleTop - slotTop), rowH)
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
            occluder.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -gap),
            occluder.leadingAnchor.constraint(equalTo: leadingAnchor),
            occluder.trailingAnchor.constraint(equalTo: trailingAnchor),

            box.topAnchor.constraint(equalTo: topAnchor, constant: gap),
            box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -gap),
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
        logo.image = nil
        if let url = channel.logoURL {
            EPGLogoCache.shared.load(url) { [weak self] image in self?.logo.image = image }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
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
        guard topClip > gap, bounds.height > 0 else { layer.mask = nil; return }
        let rect = CGRect(x: gap, y: topClip,
                          width: max(bounds.width - gap * 2, 0),
                          height: max(bounds.height - gap - topClip, 0))
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
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)

        let gap = EPGTheme.cellSpacing
        let boxH = EPGTheme.timelineBoxHeight
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gap),
            box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -gap),
            box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -gap),
            box.heightAnchor.constraint(equalToConstant: boxH),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
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

// MARK: - Logo cache

final class EPGLogoCache {
    static let shared = EPGLogoCache()
    private let cache = NSCache<NSURL, UIImage>()

    func load(_ url: URL, completion: @escaping (UIImage?) -> Void) {
        if let cached = cache.object(forKey: url as NSURL) { completion(cached); return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = UIImage(data: data) else { return }
            self?.cache.setObject(image, forKey: url as NSURL)
            DispatchQueue.main.async { completion(image) }
        }.resume()
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
        program?.posterURL ?? program?.iconURL ?? program?.landscapeURL
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
