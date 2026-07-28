// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ShelfRowCell.swift
//  Rivulet
//
//  One horizontal shelf row (Continue Watching / Recently Added /
//  Recommendations / Watchlist) hosting its own horizontal collection view.
//
//  Why not an orthogonal compositional section: measured behavior of the
//  embedded orthogonal scroller on tvOS (settle-log verified, 2026-06-10) is
//  that focus-driven landings always pin a tile's leading edge to the RAW
//  screen edge — section contentInsets, scroller contentInset, and
//  isScrollEnabled are all ignored or reverted by the layout. That makes a
//  tile peeking in from the left geometrically impossible and loses the
//  at-rest margin on the first scroll.
//
//  Here the row owns its scroll instead (isScrollEnabled = false, offsets
//  driven from didUpdateFocus — the same pattern as the detail page's
//  FocusScrollControlledCollectionView, applied horizontally). Every resting
//  position is exact:
//
//      contentOffset.x = firstVisibleColumn × (tileWidth + gap)
//
//  which, with the shelf equation in MediaRowMetrics
//  (1920 = 2·rowLeading + N·tile + (N−1)·gap), shows N full tiles with equal
//  slivers peeking in from BOTH screen edges, and tile k+1 landing exactly
//  where tile k was.
//

import UIKit

final class ShelfRowCell: UICollectionViewCell {
    static let reuseID = "ShelfRowCell"

    enum TileKind {
        case continueWatching
        case poster
        case music   // 1:1 square (same width as poster)

        var tileWidth: CGFloat {
            switch self {
            case .continueWatching: return MediaRowMetrics.cwWidth
            case .poster:           return MediaRowMetrics.posterWidth
            case .music:            return MediaRowMetrics.musicWidth
            }
        }
        var tileHeight: CGFloat {
            switch self {
            case .continueWatching: return MediaRowMetrics.cwHeight
            case .poster:           return MediaRowMetrics.posterHeight
            case .music:            return MediaRowMetrics.musicHeight
            }
        }
        var gap: CGFloat { self == .continueWatching ? MediaRowMetrics.cwGap : MediaRowMetrics.posterGap }
        var fullCount: Int { self == .continueWatching ? MediaRowMetrics.cwFullCount : MediaRowMetrics.posterFullCount }
        var pitch: CGFloat { tileWidth + gap }
    }

    // MARK: Callbacks to the owning controller (reset on every configure)

    /// Dequeues + configures the cell for an item index. The skeleton
    /// placeholder (when active) is the LAST index.
    var cellProvider: ((UICollectionView, IndexPath) -> UICollectionViewCell)?
    var onSelect: ((Int) -> Void)?
    var onWillDisplayItem: ((Int) -> Void)?
    /// Select long-press on a tile (the tile action menu). Driven by our own
    /// recognizer — the system context-menu path never engages on tvOS 26
    /// (see TileMenuPopupViewController's header).
    var onLongPressItem: ((Int) -> Void)?
    /// Reports resting offsets so the owner can restore them across reuse.
    var onOffsetChanged: ((CGFloat) -> Void)?

    /// Index of the tile that currently holds focus inside this row, or nil if
    /// focus is elsewhere or has landed on the skeleton placeholder. The owning
    /// controller needs this to service a Play/Pause press: unlike Select and
    /// long-press, a Play/Pause press is delivered to the focused view and
    /// bubbles up to the outer view controller, so there is no per-tile
    /// callback to hang the lookup off. The controller has to pull the focused
    /// index out of whichever row owns it.
    func focusedItemIndex() -> Int? {
        guard let indexPath = TileLongPress.focusedCell(in: rowCollectionView),
              indexPath.item < realCount
        else { return nil }
        return indexPath.item
    }

    // MARK: State

    private(set) var rowCollectionView: UICollectionView!
    private let flow = UICollectionViewFlowLayout()
    private var tileKind: TileKind = .poster
    /// Real item count (excludes the skeleton placeholder).
    private var realCount = 0
    private var hasSkeleton = false
    /// Identity of the configured content; a change forces a full reload.
    private var contentToken: Int = 0
    /// False until the first configure after init/reuse. Distinguishes an
    /// in-place content change (cross-dissolved) from binding a freshly
    /// (re)used cell (instant).
    private var hasBoundContent = false
    /// How far this cell extends PAST the visible panel on each side (the
    /// expanded detail's below-fold is translated/widened off-screen by a
    /// constant pull). The shelf margin + equation are panel-relative: the
    /// overshoot is simply added to the inner content insets so tiles, peeks
    /// and landings line up with the panel exactly like the home rows.
    private var panelOvershoot: (left: CGFloat, right: CGFloat) = (0, 0)

    /// When true, the leading inset (row AND header) is computed every layout
    /// pass from the cell's ACTUAL on-screen x, so the first tile lands at
    /// `MediaRowMetrics.rowLeading` in SCREEN space regardless of any container
    /// translation. The expanded detail's below-fold is translated by a
    /// state-dependent amount (different for the in-carousel expand vs the
    /// standalone expand), so a fixed overshoot constant can't be right for
    /// both — self-measuring is. Home rows leave this false (cell already at
    /// screen x = 0, so the static inset already lands at rowLeading).
    var screenAlignsLeading = false {
        didSet { setNeedsLayout() }
    }

    /// Optional in-cell header title (the below-fold Related row draws its
    /// "Related" header here so it self-aligns with the tiles; the home rows
    /// keep using the section's supplementary header and leave this nil).
    var headerTitle: String? {
        didSet {
            headerLabel.text = headerTitle
            let show = !(headerTitle?.isEmpty ?? true)
            headerLabel.isHidden = !show
            headerHeightConstraint.constant = show ? Self.headerHeight : 0
        }
    }

    static let headerHeight: CGFloat = 44

    private let headerLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 32, weight: .semibold)
        l.textColor = .white
        l.isHidden = true
        return l
    }()
    private var headerLeadingConstraint: NSLayoutConstraint!
    private var headerHeightConstraint: NSLayoutConstraint!
    private var rowWidthConstraint: NSLayoutConstraint!

    /// Item index to route focus to on the next focus update (preview-dismiss
    /// restoration). One-shot.
    private var pendingFocusIndex: Int?

    // Driven offset settle (CADisplayLink), sharing FocusScrollMotion's
    // duration + curve with the vertical focus-scroll so horizontal and
    // vertical row motion feel identical. (The focus coordinator's default
    // animation is much faster and reads as a jump cut.)
    private var offsetLink: CADisplayLink?
    private var animStartX: CGFloat = 0
    private var animTargetX: CGFloat = 0
    private var animStartTime: CFTimeInterval = 0

    private var displayCount: Int { realCount + (hasSkeleton ? 1 : 0) }

    // MARK: Init

    override init(frame: CGRect) {
        super.init(frame: frame)

        flow.scrollDirection = .horizontal
        applyMetrics(for: .poster)  // matches the default tileKind
        rowCollectionView = UICollectionView(frame: bounds, collectionViewLayout: flow)
        rowCollectionView.translatesAutoresizingMaskIntoConstraints = false
        rowCollectionView.backgroundColor = .clear
        rowCollectionView.dataSource = self
        rowCollectionView.delegate = self
        // We own the scroll: the engine's focus-scroll is disabled so it can't
        // land at arbitrary offsets, and didUpdateFocus drives pitch-aligned
        // offsets instead. Programmatic offsets still work when disabled.
        rowCollectionView.isScrollEnabled = false
        // No per-row focus memory: entering a row should land on the tile in
        // the same SCREEN column you came from (the engine's geometric pick),
        // like ATV+ — not on whatever tile this row last had focused.
        rowCollectionView.remembersLastFocusedIndexPath = false
        // The focused tile's scale + the peeking slivers must not clip.
        rowCollectionView.clipsToBounds = false
        clipsToBounds = false
        contentView.clipsToBounds = false

        rowCollectionView.addGestureRecognizer(
            TileLongPress.makeRecognizer(target: self, action: #selector(handleTileLongPress(_:))))

        rowCollectionView.register(PosterCell.self, forCellWithReuseIdentifier: PosterCell.reuseID)
        rowCollectionView.register(ContinueWatchingCell.self, forCellWithReuseIdentifier: ContinueWatchingCell.reuseID)
        rowCollectionView.register(WatchlistPosterCell.self, forCellWithReuseIdentifier: WatchlistPosterCell.reuseID)
        rowCollectionView.register(PosterSkeletonCell.self, forCellWithReuseIdentifier: PosterSkeletonCell.reuseID)

        contentView.addSubview(headerLabel)
        contentView.addSubview(rowCollectionView)
        headerLeadingConstraint = headerLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: MediaRowMetrics.rowLeading)
        headerHeightConstraint = headerLabel.heightAnchor.constraint(equalToConstant: 0)
        // Width is constraint-driven (not a trailing pin): when screen-aligned
        // the inner collection must reach the screen's RIGHT edge even if the
        // host cell is narrower than the screen, otherwise the peeking tile's
        // frame falls outside the collection's bounds and its cell is never
        // realized ("pops into place" instead of sliding in). Defaults to the
        // cell width (home behavior); updated in layoutSubviews.
        rowWidthConstraint = rowCollectionView.widthAnchor.constraint(equalToConstant: MediaRowMetrics.posterWidth)
        rowWidthConstraint.priority = .required
        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: contentView.topAnchor),
            headerLeadingConstraint,
            headerHeightConstraint,
            // Row fills below the header (header height is 0 when no title, so
            // the row reclaims the full cell — home behavior unchanged).
            rowCollectionView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor),
            rowCollectionView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            rowCollectionView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rowWidthConstraint,
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Default: inner collection spans the cell (home behavior).
        var targetWidth = bounds.width
        if screenAlignsLeading, let window {
            // Cell origin in screen space — negative when the container is
            // translated left past the screen edge.
            let screenMinX = convert(CGPoint.zero, to: window).x
            let targetInset = MediaRowMetrics.rowLeading - screenMinX
            if abs(flow.sectionInset.left - targetInset) > 0.5 {
                flow.sectionInset.left = targetInset
                flow.invalidateLayout()
            }
            if abs(headerLeadingConstraint.constant - targetInset) > 0.5 {
                headerLeadingConstraint.constant = targetInset
            }
            // Reach the screen's right edge + one pitch of buffer so the
            // right-peek tile always has a realized cell.
            let screenWidth = window.bounds.width
            targetWidth = (screenWidth - screenMinX) + tileKind.pitch
        }
        if abs(rowWidthConstraint.constant - targetWidth) > 0.5 {
            rowWidthConstraint.constant = targetWidth
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The row container itself never takes focus — its tiles do.
    override var canBecomeFocused: Bool { false }

    override func prepareForReuse() {
        super.prepareForReuse()
        pendingFocusIndex = nil
        hasBoundContent = false
        offsetLink?.invalidate()
        offsetLink = nil
    }

    // MARK: Configure

    /// Full (re)bind. `contentToken` identifies the content (hash of item
    /// IDs); reload only happens when it changes, so reconfiguring with the
    /// same data is cheap and focus-safe.
    func configure(kind: TileKind,
                   realCount: Int,
                   hasSkeleton: Bool,
                   contentToken: Int,
                   initialOffset: CGFloat,
                   panelOvershoot: (left: CGFloat, right: CGFloat) = (0, 0)) {
        let kindChanged = kind != tileKind || panelOvershoot != self.panelOvershoot
        tileKind = kind
        self.panelOvershoot = panelOvershoot
        if kindChanged {
            applyMetrics(for: kind)
        }

        if kindChanged || contentToken != self.contentToken {
            // In-place content change on a row the user can see (a refresh
            // reordered Continue Watching, advanced a progress bar, …) gets a
            // cross-dissolve instead of a hard-cut reload. First binds and
            // post-reuse binds stay instant — fading those would flash every
            // row scrolled into view.
            let isVisibleRebind = hasBoundContent && !kindChanged && window != nil
            self.contentToken = contentToken
            self.realCount = realCount
            self.hasSkeleton = hasSkeleton
            hasBoundContent = true
            let applyContent = {
                self.rowCollectionView.reloadData()
                self.rowCollectionView.layoutIfNeeded()
                self.setOffset(clampedTo: initialOffset)
            }
            if isVisibleRebind {
                UIView.transition(with: rowCollectionView,
                                  duration: 0.35,
                                  options: [.transitionCrossDissolve, .allowUserInteraction],
                                  animations: applyContent)
            } else {
                applyContent()
            }
        } else {
            updateCounts(realCount: realCount, hasSkeleton: hasSkeleton)
        }
    }

    /// Single-tile removal without nuking focus: delete the tile at the
    /// captured index inside a batch update so the survivors slide over to
    /// fill the gap. UIKit keeps focus coherent through a batch delete (it
    /// tracks the focused cell across the update, landing on the slot's new
    /// occupant when the focused tile itself was deleted) — which a
    /// crossfade reload does not: the reload re-binds cell instances and
    /// strands focus on whatever cell object the engine was holding. Falls
    /// back to a plain reload when the caller's expectation doesn't match
    /// the collection's actual shape (racing refresh).
    func animateRemoval(at index: Int, newRealCount: Int, newSkeleton: Bool, contentToken: Int) {
        let oldReal = realCount
        let oldSkeleton = hasSkeleton
        self.contentToken = contentToken
        realCount = newRealCount
        hasSkeleton = newSkeleton
        guard index >= 0, index < oldReal, newRealCount == oldReal - 1,
              rowCollectionView.numberOfItems(inSection: 0) == oldReal + (oldSkeleton ? 1 : 0)
        else {
            rowCollectionView.reloadData()
            rowCollectionView.layoutIfNeeded()
            return
        }
        let keepOffset = rowCollectionView.contentOffset.x
        rowCollectionView.performBatchUpdates {
            rowCollectionView.deleteItems(at: [IndexPath(item: index, section: 0)])
            // Reconcile the skeleton placeholder (just past the real items) in
            // the same batch, expressed in old-index space like the delete.
            if oldSkeleton, !newSkeleton {
                rowCollectionView.deleteItems(at: [IndexPath(item: oldReal, section: 0)])
            } else if !oldSkeleton, newSkeleton {
                rowCollectionView.insertItems(at: [IndexPath(item: newRealCount, section: 0)])
            }
        } completion: { [weak self] _ in
            self?.setOffset(clampedTo: keepOffset)
        }
    }

    /// Append-only growth (pagination) without nuking focus: inserts the new
    /// trailing items; the skeleton placeholder (an unchanged trailing item)
    /// shifts to the new end automatically.
    func updateCounts(realCount newReal: Int, hasSkeleton newSkeleton: Bool) {
        guard newReal != realCount || newSkeleton != hasSkeleton else { return }
        let oldReal = realCount
        let oldSkeleton = hasSkeleton
        guard newReal >= oldReal,
              rowCollectionView.numberOfItems(inSection: 0) == oldReal + (oldSkeleton ? 1 : 0)
        else {
            // Shrunk or out of sync — full reload, clamp the offset back into
            // the new range.
            realCount = newReal
            hasSkeleton = newSkeleton
            rowCollectionView.reloadData()
            rowCollectionView.layoutIfNeeded()
            setOffset(clampedTo: rowCollectionView.contentOffset.x)
            return
        }

        realCount = newReal
        hasSkeleton = newSkeleton
        rowCollectionView.performBatchUpdates {
            if newReal > oldReal {
                rowCollectionView.insertItems(at: (oldReal..<newReal).map { IndexPath(item: $0, section: 0) })
            }
            if oldSkeleton, !newSkeleton {
                rowCollectionView.deleteItems(at: [IndexPath(item: oldReal, section: 0)])
            } else if !oldSkeleton, newSkeleton {
                rowCollectionView.insertItems(at: [IndexPath(item: newReal, section: 0)])
            }
        }
    }

    /// Route the next focus update to a specific item (preview-dismiss
    /// restoration): jump the window so the item is visible, then prefer its
    /// cell.
    func prepareFocusRestore(on itemIndex: Int) {
        pendingFocusIndex = itemIndex
        prepareFocusRestoreLayout(on: itemIndex)
        setNeedsFocusUpdate()
    }

    /// Jump the row's horizontal window so `itemIndex` is realized/visible
    /// without changing the pending focus target yet. Used while a modal is
    /// still covering Home, so the eventual focus update has no visible
    /// scroll jump when the modal disappears.
    func prepareFocusRestoreLayout(on itemIndex: Int) {
        setOffset(clampedTo: snappedOffset(toShow: itemIndex), animated: false)
        rowCollectionView.layoutIfNeeded()
    }

    /// Clear any stranded focus transforms from visible non-target tiles.
    /// The currently focused Home tile can keep its TVPosterView/TVCardView
    /// visual state after focus moves into a modal; clear it while Home is
    /// still covered so the old tile is not visibly focused beside the new
    /// restore target when the modal disappears.
    func resetVisibleFocusAppearance(except itemIndex: Int?) {
        for cell in rowCollectionView.visibleCells {
            let index = rowCollectionView.indexPath(for: cell)?.item
            guard index != itemIndex else { continue }
            Self.clearFocusAppearance(in: cell)
        }
    }

    static func clearFocusAppearance(in view: UIView) {
        view.layer.removeAllAnimations()
        if !view.transform.isIdentity { view.transform = .identity }
        if !CATransform3DIsIdentity(view.layer.transform) { view.layer.transform = CATransform3DIdentity }
        view.motionEffects.forEach { view.removeMotionEffect($0) }
        view.subviews.forEach { clearFocusAppearance(in: $0) }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let index = pendingFocusIndex,
           let cell = rowCollectionView.cellForItem(at: IndexPath(item: index, section: 0)) {
            pendingFocusIndex = nil
            return [cell]
        }
        return [rowCollectionView]
    }

    /// Window-frame of an item's tile, for preview entry-morphs.
    func frameInWindow(forItem index: Int) -> CGRect? {
        guard let attrs = rowCollectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0)),
              let window = window else { return nil }
        return rowCollectionView.convert(attrs.frame, to: window)
    }

    /// Snapshots of every realized, visible source tile. The owning controller
    /// maps row item indices to preview item indices before presenting the
    /// carousel so the modal can animate the row into carousel geometry.
    func visibleEntrySnapshots(itemIndexMap: [Int: Int]? = nil) -> [PreviewEntrySnapshot] {
        guard let window else { return [] }
        rowCollectionView.layoutIfNeeded()

        let visible = rowCollectionView.indexPathsForVisibleItems.sorted { $0.item < $1.item }

        let visibleBounds = window.bounds.insetBy(dx: -80, dy: -80)
        return visible
            .compactMap { indexPath -> PreviewEntrySnapshot? in
                let targetIndex: Int
                if let itemIndexMap {
                    guard let mappedIndex = itemIndexMap[indexPath.item] else { return nil }
                    targetIndex = mappedIndex
                } else {
                    targetIndex = indexPath.item
                }
                guard indexPath.item < realCount,
                      let cell = rowCollectionView.cellForItem(at: indexPath),
                      let snapshot = cell.snapshotView(afterScreenUpdates: false)
                else { return nil }

                let frame = cell.convert(cell.bounds, to: window)
                guard frame.intersects(visibleBounds), frame.width > 1, frame.height > 1 else { return nil }
                return PreviewEntrySnapshot(
                    itemIndex: targetIndex,
                    sourceFrame: frame,
                    snapshotView: snapshot
                )
            }
    }

    private func applyMetrics(for kind: TileKind) {
        flow.itemSize = CGSize(width: kind.tileWidth, height: kind.tileHeight)
        flow.minimumLineSpacing = kind.gap
        flow.minimumInteritemSpacing = kind.gap
        flow.sectionInset = UIEdgeInsets(
            top: 0,
            left: MediaRowMetrics.rowLeading + panelOvershoot.left,
            bottom: 0,
            right: MediaRowMetrics.rowTrailing + panelOvershoot.right
        )
    }

    // MARK: Offset math

    /// First fully-visible column implied by an offset (offsets only ever
    /// hold pitch multiples; rounding guards float fuzz).
    private func column(for offset: CGFloat) -> Int {
        Int((offset / tileKind.pitch).rounded())
    }

    private func maxColumn() -> Int {
        max(0, displayCount - tileKind.fullCount)
    }

    /// Smallest window shift that brings `itemIndex` fully into view. While a
    /// settle is in flight the logical position is its TARGET (the visual
    /// offset is mid-glide and would round to a stale column under held
    /// presses).
    private func snappedOffset(toShow itemIndex: Int) -> CGFloat {
        let logicalX = offsetLink != nil ? animTargetX : rowCollectionView.contentOffset.x
        let fCur = column(for: logicalX)
        var f = min(max(fCur, itemIndex - (tileKind.fullCount - 1)), itemIndex)
        f = min(max(0, f), maxColumn())
        return CGFloat(f) * tileKind.pitch
    }

    private func setOffset(clampedTo x: CGFloat, animated: Bool = false) {
        offsetLink?.invalidate()
        offsetLink = nil
        let maxOffset = CGFloat(maxColumn()) * tileKind.pitch
        let clamped = min(max(0, x), maxOffset)
        rowCollectionView.setContentOffset(CGPoint(x: clamped, y: 0), animated: animated)
        onOffsetChanged?(clamped)
    }

    /// Driven settle to a pitch-aligned offset: per-frame CADisplayLink with
    /// the shared FocusScrollMotion duration + cubic ease-out. Retargets
    /// continue from the current (mid-flight) position so held presses glide.
    private func animateOffset(to x: CGFloat) {
        offsetLink?.invalidate()
        animStartX = rowCollectionView.contentOffset.x
        animTargetX = x
        animStartTime = CACurrentMediaTime()
        // Weak proxy: CADisplayLink retains its target; a cell deallocated
        // mid-flight would otherwise leak with a live link.
        let link = CADisplayLink(target: LinkProxy(self), selector: #selector(LinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        offsetLink = link
    }

    fileprivate func stepOffset(_ link: CADisplayLink) {
        let t = min(1, (CACurrentMediaTime() - animStartTime) / FocusScrollMotion.settleDuration)
        let e = CGFloat(FocusScrollMotion.ease(t))
        rowCollectionView.contentOffset.x = animStartX + (animTargetX - animStartX) * e
        if t >= 1 {
            link.invalidate()
            if offsetLink === link { offsetLink = nil }
        }
    }

    private final class LinkProxy: NSObject {
        private weak var owner: ShelfRowCell?
        init(_ owner: ShelfRowCell) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.stepOffset(link)
        }
    }
}

// MARK: - Inner collection plumbing

extension ShelfRowCell: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        displayCount
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        cellProvider?(collectionView, indexPath) ?? collectionView.dequeueReusableCell(withReuseIdentifier: PosterCell.reuseID, for: indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard indexPath.item < realCount else { return }  // skeleton: ignore
        onSelect?(indexPath.item)
    }

    func collectionView(_ collectionView: UICollectionView,
                        willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        onWillDisplayItem?(indexPath.item)
    }

    /// Select long-press → tile action menu, from the focused tile.
    @objc private func handleTileLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        guard let indexPath = TileLongPress.focusedCell(in: rowCollectionView),
              indexPath.item < realCount else { return }
        onLongPressItem?(indexPath.item)
    }

    /// The one driver of horizontal scroll: shift the window only as far as
    /// needed to keep the focused tile inside the N fully-visible columns
    /// (ATV+ feel — no scroll while moving within view, a one-pitch shift
    /// when crossing the window edge). Driven with the shared
    /// FocusScrollMotion settle so it matches the vertical row scroll.
    func collectionView(_ collectionView: UICollectionView,
                        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        guard let next = context.nextFocusedIndexPath else { return }
        let target = snappedOffset(toShow: next.item)
        guard abs(target - collectionView.contentOffset.x) > 0.5 else { return }
        animateOffset(to: target)
        onOffsetChanged?(target)
    }

    /// Keep a Left press at the window edge from escaping to the sidebar
    /// while older items exist offscreen-left (they're virtualized out of the
    /// focus chain). Mirror of the home's orthogonal-row interceptor: block
    /// the escape, shift the window one pitch, and let the engine re-poll.
    func collectionView(_ collectionView: UICollectionView,
                        shouldUpdateFocusIn context: UICollectionViewFocusUpdateContext) -> Bool {
        guard context.focusHeading == .left,
              let prev = context.previouslyFocusedIndexPath,
              prev.item > 0
        else { return true }
        let nextIsInside = context.nextFocusedView?.isDescendant(of: collectionView) ?? false
        guard !nextIsInside else { return true }

        setOffset(clampedTo: snappedOffset(toShow: prev.item - 1), animated: false)
        collectionView.layoutIfNeeded()
        DispatchQueue.main.async { [weak self] in
            self?.setNeedsFocusUpdate()
            self?.updateFocusIfNeeded()
        }
        return false
    }
}
