// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InfoScrollView.swift
//  Rivulet
//
//  Scroll surface shared by the player's info sheets (Info tab `CardInfoView`
//  and Advanced tab `CardStatsView`), plus the invisible focusable row
//  wrapper (`InfoFocusRowView`) that makes it work on a real Siri Remote.
//
//  The scroll view itself is NOT focusable and never pan-scrolls. Each two-up
//  ROW of a sheet is wrapped in an `InfoFocusRowView`, an ordinary focus target
//  with no visible focus treatment. Swipes and edge clicks are then the same
//  thing — focus moves between rows — and this view reveals the newly focused
//  row by driving `contentOffset` itself from `didUpdateFocus` (same
//  self-driven pattern as `InsightsActorView`).
//
//  Why not a single focusable pan-scrolling sheet: a swipe is never an arrow
//  UIPress, it is an indirect touch the focus engine turns into a focus move.
//  A sheet that pan-scrolls swallows every swipe (focus can never escape to
//  the tab bar above), and one that steps on arrow presses instead is dead to
//  swipes entirely — it only ever worked from clickpad edge clicks. Discrete
//  focus targets give the engine real geometry, so the tab bar ↔ content
//  crossings need no press handling at all.
//
//  Focus targets alone can't reach every pixel, though: a row whose text wraps
//  to more lines than the viewport has no focus target in its lower half, so
//  nothing reveals it (issue #242, which bit far harder when the targets were
//  whole sections). Rows stay the primary mechanism and arrow presses are a
//  SUPPLEMENT, handled here on the responder chain above the focused row: when
//  the engine has somewhere to move focus it consumes the press first and this
//  never runs; only a press the engine declined (end of travel, or inside an
//  over-tall row) reaches us, and then we step the offset ourselves.
//

import UIKit
import os

/// TEMP diagnostic instrumentation — see the matching note in
/// `PlayerInfoTabsView.swift`. Remove once the "can't move Down into the
/// tab's content" report is confirmed and fixed from a captured log.
private let infoTabLog = Logger(subsystem: "com.rivulet.app", category: "PlayerInfoTab")

/// Invisible focus target wrapping ONE two-up row of an info sheet. Carries no
/// focus visuals on purpose — these sheets are read-only, and the feedback is
/// the panel ring plus the reveal scroll.
///
/// Granularity is the whole point. This used to wrap a whole SECTION (label +
/// its entire row grid), which gave a sheet only ~4 focus targets, each
/// possibly taller than the panel. A `UIScrollView` clips, and **a clipped view
/// cannot be focused**, so everything past the first tall section had no
/// reachable target and Down did nothing. Arrow presses were patched around
/// that (`pressesBegan` below), but swipes never emit arrow presses — they are
/// indirect touches the focus engine turns into focus moves — so on a Siri
/// Remote the sheet simply dead-ended. One target per ROW keeps the next target
/// always within reach, which is what makes the Insights/trivia panel work.
///
/// The wrapper persists across rebuilds (see `CardStatsView`, which keeps a
/// pool of these and only ever swaps the labels inside them), so focus survives
/// a live tick that reshuffles which rows are present.
final class InfoFocusRowView: UIView {

    private let stack = UIStackView()

    /// Focusable ONLY while the enclosing sheet needs scrolling.
    ///
    /// Focus in the content exists to scroll it. A sheet that fits on screen
    /// has nothing to scroll, so putting focus in it buys nothing and costs
    /// the user a way back: they walk into a row and then have to find the way
    /// out to the pills again. When everything is visible, focus stays on the
    /// pills and Down does nothing at all.
    /// False for a row that is laid out as an ordinary two-up line INSIDE a
    /// larger focus target. A sheet picks its granularity by choosing which
    /// level carries focus: nesting two focusable levels would make the inner
    /// ones unreachable, since a focusable view is a leaf to a directional
    /// search.
    var isFocusEnabled = true

    override var canBecomeFocused: Bool {
        guard isFocusEnabled else { return false }
        var candidate: UIView? = superview
        while let current = candidate {
            if let scroll = current as? InfoScrollView { return scroll.needsFocusableRows }
            candidate = current.superview
        }
        return true
    }

    /// Focus treatment. The row is otherwise an invisible target, which left the
    /// user with no way to tell where focus was after walking several rows — the
    /// panel ring only says focus is SOMEWHERE in the sheet, and that was
    /// sufficient only while the sheet was one single focus target.
    ///
    /// Drawn as a uniform OUTSET behind the content, never a scale: these rows
    /// are wide and short, so a scale grows them many times more sideways than
    /// vertically and reads as a stretch (same reason the settings rows outset).
    /// Outsetting a backing view also leaves the row's own frame alone, so the
    /// sheet's content height is unchanged.
    private let highlight = UIView()

    enum Focus {
        /// The sheet's scroll view clips, so `InfoScrollView.pinContent` insets
        /// the content by these outsets; otherwise the clip shears the
        /// highlight's rounded sides off and leaves a flat gray rectangle.
        static let outsetX: CGFloat = 10
        static let outsetY: CGFloat = 4
        /// Matches the other rows in the player chrome (track, trivia rows).
        static let cornerRadius: CGFloat = 14
        /// The house focused fill (see the Glass UI style in CLAUDE.md).
        static let fill = UIColor.white.withAlphaComponent(0.18)
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        highlight.translatesAutoresizingMaskIntoConstraints = false
        highlight.backgroundColor = Focus.fill
        highlight.layer.cornerRadius = Focus.cornerRadius
        highlight.layer.cornerCurve = .continuous
        highlight.isUserInteractionEnabled = false
        highlight.alpha = 0
        addSubview(highlight)

        // Two equal columns, top-aligned — the geometry the sheets' two-column
        // grid used to build inline, now owned here so every row is identical.
        stack.axis = .horizontal
        stack.spacing = 20
        stack.distribution = .fillEqually
        stack.alignment = .top
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: -Focus.outsetY),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: Focus.outsetY),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -Focus.outsetX),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: Focus.outsetX),
        ])
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Ride the focus animation coordinator rather than a free-running
    /// animation, so the fade is on the same clock as the engine's own focus
    /// transition.
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let isFocusedNow = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({
            self.highlight.alpha = isFocusedNow ? 1 : 0
        }, completion: nil)
    }

    /// Puts `left` (and `right`, or an empty spacer so a lone final row stays a
    /// half-width left column) into this row. Re-parents the passed views; the
    /// row itself — the focus target — is never torn down.
    func setPair(_ left: UIView, _ right: UIView?) {
        emptyStack()
        stack.addArrangedSubview(left)
        stack.addArrangedSubview(right ?? UIView())
    }

    /// Puts one view across BOTH columns. Prose (the Description tab) reads
    /// badly in a half-width column, and `.fillEqually` gives a lone arranged
    /// subview the full width.
    func setFullWidth(_ view: UIView) {
        emptyStack()
        stack.addArrangedSubview(view)
    }

    private func emptyStack() {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
    }
}

/// One tab's content sheet in the Info popup (`CardDescriptionView`,
/// `CardInfoView`, `CardStatsView`). `PlayerInfoTabsView` drives the
/// pills ↔ sheet focus crossing itself, because the focus engine does not
/// reliably cross the nested scroll views between them — the same conclusion
/// `InsightsPanelContainerView` reached for the trivia panel. Every sheet is an
/// `InfoScrollView` wrapped in some content, and that scroll view owns the
/// focus and scroll mechanics, so exposing it is all the container needs.
protocol InfoTabSheet: UIView {
    var infoScrollView: InfoScrollView { get }
}

final class InfoScrollView: UIScrollView {

    /// Fires when focus enters/leaves this sheet's sections, so the hosting
    /// panel can brighten its own boundary (the sheet draws no focus ring).
    var onFocusChange: ((Bool) -> Void)?

    /// Fires when an Up press has nowhere left to scroll and focus sits on the
    /// first row: the host escapes focus back to the tab bar.
    ///
    /// A callback rather than letting the press bubble to the host's own
    /// `pressesBegan`. Bubbling out of a `UIScrollView` did not get there on
    /// device, and this is the exact spot that knows the press was declined —
    /// re-deriving "at the top, not a same-press artifact" one level up would
    /// duplicate the two gates below.
    var onDeclinedUpPress: (() -> Void)?

    /// Whether this sheet's rows should be focus targets at all: only when the
    /// content overflows the viewport and therefore needs scrolling. Read by
    /// `InfoFocusRowView.canBecomeFocused`.
    var needsFocusableRows: Bool {
        contentSize.height > bounds.height + 0.5
    }

    /// Breathing room above/below a revealed section so it never sits flush
    /// against the clip edge.
    nonisolated static let revealPadding: CGFloat = 12

    /// How far one declined arrow press nudges the sheet. Deliberately less
    /// than a viewport so the reader keeps an overlap line between steps.
    nonisolated static let pressStep: CGFloat = 240

    /// When focus last moved inside this sheet. Gated through
    /// `SamePressFocusGate`: without it every section hop would also step the
    /// offset and overshoot, because the press arrives after the move it caused.
    private var lastFocusMoveTime: CFTimeInterval = -.greatestFiniteMagnitude

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Focus-driven scrolling: the engine's own focus-scroll fights a
        // self-driven offset, and a pan-scrolling sheet swallows the very
        // swipes the focus engine needs (see header). Scroll is driven from
        // didUpdateFocus below, plus the declined-press fallback in
        // pressesBegan for content no focus target can reach.
        isScrollEnabled = false

        // Swipe twin of the declined-Up escape in pressesBegan. Claimable
        // only when a step up would not move AND focus sits on the first
        // row (canEscapeUpward) — there the engine has no upward candidate,
        // so the swipe steals nothing; anywhere else the gate declines and
        // the engine keeps its row hops. The iPhone Remote emits no arrow
        // presses, so this is its only way back up to the pills.
        escapeSwipe = DirectionalInputBinding(
            gatedSwipesOn: self,
            directions: [.up],
            shouldHandle: { [weak self] _ in
                guard let self else { return false }
                return !self.canStepUp && self.canEscapeUpward
            },
            onSwipe: { [weak self] _ in self?.onDeclinedUpPress?() }
        )
    }

    private var escapeSwipe: DirectionalInputBinding?

    /// Pins a sheet's content into the scrollable area, inset by the row
    /// highlight's outset so a focused row's highlight is never clipped.
    /// Hosts widen the sheet by the same `outsetX` (see `PlayerInfoTabsView`)
    /// so the text itself stays where it was.
    func pinContent(_ content: UIView) {
        let outset = InfoFocusRowView.Focus.self
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor, constant: outset.outsetY),
            content.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor, constant: outset.outsetX),
            content.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor, constant: -outset.outsetX),
            content.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor, constant: -outset.outsetY),
            content.widthAnchor.constraint(equalTo: frameLayoutGuide.widthAnchor, constant: -2 * outset.outsetX),
        ])
    }

    /// Read-only mirror of `step(by: -pressStep)`'s would-it-move math.
    private var canStepUp: Bool {
        let target = Self.steppedOffsetY(
            current: contentOffset.y,
            delta: -Self.pressStep,
            viewportHeight: bounds.height,
            contentHeight: contentSize.height
        )
        return abs(target - contentOffset.y) > 0.5
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let wasInside = context.previouslyFocusedView.map { $0.isDescendant(of: self) } ?? false
        let isInside = context.nextFocusedView.map { $0.isDescendant(of: self) } ?? false
        if isInside != wasInside {
            infoTabLog.notice("InfoScrollView focus \(isInside ? "ENTERED" : "LEFT", privacy: .public)")
            if isInside { flashScrollIndicators() }
            onFocusChange?(isInside)
        }
        // A SELF-move is not a move. `next !== previous` is load-bearing: at the
        // top row an Up press has no candidate above, so the host's
        // `preferredFocusEnvironments` re-affirms the focused row and the engine
        // reports an update from that row TO ITSELF. Stamping the clock for that
        // re-armed the same-press gate, which is the sole gate on
        // `canEscapeUpward` once `canStepUp` is false — so every Up press blocked
        // the next one and focus could never leave the sheet. Measured as
        // `justMoved=true canEscape=false` on every press, with
        // `focused === first`.
        guard isInside,
              let next = context.nextFocusedView,
              next !== context.previouslyFocusedView
        else { return }
        lastFocusMoveTime = CACurrentMediaTime()
        reveal(rowContaining: next)
    }

    // MARK: - Declined-press scrolling

    /// Steps the offset for an arrow press the focus engine declined. This
    /// override sits on the responder chain ABOVE the focused section, so a
    /// press that did move focus has already been acted on by the engine —
    /// `lastFocusMoveTime` detects that case and leaves the offset to
    /// `reveal(sectionContaining:)`. What is left is exactly the content no
    /// focus target can reach: the interior of a section taller than the
    /// viewport, and the tail below the last section.
    ///
    /// Swipes never produce an arrow press, so this adds nothing for them and
    /// (crucially) takes nothing away — the section hops they rely on are
    /// untouched. Up is not swallowed at the top edge: the tab bar sits above
    /// and must stay reachable.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.type {
            case .upArrow:
                if step(by: -Self.pressStep) { return }
                // Nowhere left to scroll: hand the way out to the host.
                if canEscapeUpward {
                    onDeclinedUpPress?()
                    return
                }
            case .downArrow:
                if step(by: Self.pressStep) { return }
            default: continue
            }
        }
        super.pressesBegan(presses, with: event)
    }

    /// Moves `contentOffset.y` by `delta`, clamped to the scrollable range.
    /// Returns false — leaving the press to bubble — when the engine just
    /// moved focus for this same press, or when there is nowhere to scroll.
    private func step(by delta: CGFloat) -> Bool {
        guard !SamePressFocusGate.justMovedFocus(at: lastFocusMoveTime) else { return false }
        let target = Self.steppedOffsetY(
            current: contentOffset.y,
            delta: delta,
            viewportHeight: bounds.height,
            contentHeight: contentSize.height
        )
        guard abs(target - contentOffset.y) > 0.5 else { return false }
        UIView.animate(withDuration: FocusScrollMotion.settleDuration, delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
            self.contentOffset.y = target
        }
        return true
    }

    // MARK: - Upward escape

    /// True when an Up press should leave this sheet for the tab bar: focus
    /// sits on the FIRST row and the engine did not just move it there.
    ///
    /// That second half is not optional: without it a single Up press that
    /// moves focus row-2 → row-1 would also be read as an escape, and focus
    /// would shoot past the row to the pills. See `SamePressFocusGate`.
    var canEscapeUpward: Bool {
        guard !SamePressFocusGate.justMovedFocus(at: lastFocusMoveTime) else { return false }
        guard let focused = UIFocusSystem.focusSystem(for: self)?.focusedItem as? UIView,
              focused.isDescendant(of: self),
              let first = Self.firstRow(in: self) else { return false }
        return focused === first || focused.isDescendant(of: first)
    }

    /// First non-hidden `InfoFocusRowView` in subview (document) order. Hidden
    /// branches are skipped whole: the Advanced sheet keeps a pool of rows and
    /// hides the ones the current telemetry has no values for, so the first
    /// row in the hierarchy is not necessarily the first row on screen.
    private static func firstRow(in view: UIView) -> InfoFocusRowView? {
        for subview in view.subviews where !subview.isHidden {
            if let row = subview as? InfoFocusRowView { return row }
            if let found = firstRow(in: subview) { return found }
        }
        return nil
    }

    private func reveal(rowContaining view: UIView) {
        var candidate: UIView? = view
        while let current = candidate, !(current is InfoFocusRowView), current !== self {
            candidate = current.superview
        }
        guard let section = candidate as? InfoFocusRowView else { return }
        let frame = section.convert(section.bounds, to: self)
        let target = Self.revealOffsetY(
            current: contentOffset.y,
            sectionMinY: frame.minY,
            sectionMaxY: frame.maxY,
            viewportHeight: bounds.height,
            contentHeight: contentSize.height
        )
        guard abs(target - contentOffset.y) > 0.5 else { return }
        // Shared focus-scroll duration/curve rather than the focus
        // coordinator's own ~0.2s animation, which reads as an abrupt snap —
        // same choice as InsightsActorView.
        UIView.animate(withDuration: FocusScrollMotion.settleDuration, delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
            self.contentOffset.y = target
        }
    }

    /// Target offset that reveals a focused section: minimal movement when
    /// the (padded) section fits the viewport; top-aligned when it is taller
    /// and focus arrives from above, bottom-aligned when focus returns from
    /// below (keeps the reading position); always clamped to the scrollable
    /// range. Pure so it is unit-testable (`InfoSectionRevealTests`).
    nonisolated static func revealOffsetY(
        current: CGFloat,
        sectionMinY: CGFloat,
        sectionMaxY: CGFloat,
        viewportHeight: CGFloat,
        contentHeight: CGFloat
    ) -> CGFloat {
        let paddedMinY = sectionMinY - revealPadding
        let paddedMaxY = sectionMaxY + revealPadding
        let maxOffset = max(0, contentHeight - viewportHeight)
        let target: CGFloat
        if paddedMaxY - paddedMinY <= viewportHeight {
            // Fits: scroll just enough that the whole section is visible.
            target = min(max(current, paddedMaxY - viewportHeight), paddedMinY)
        } else {
            target = paddedMinY < current ? paddedMaxY - viewportHeight : paddedMinY
        }
        return min(max(0, target), maxOffset)
    }

    /// Target offset for a declined arrow press: the current offset moved by
    /// `delta` and clamped to the scrollable range (which is empty when the
    /// content fits, so a short sheet never moves). Pure so it is
    /// unit-testable alongside `revealOffsetY`.
    nonisolated static func steppedOffsetY(
        current: CGFloat,
        delta: CGFloat,
        viewportHeight: CGFloat,
        contentHeight: CGFloat
    ) -> CGFloat {
        let maxOffset = max(0, contentHeight - viewportHeight)
        return min(max(0, current + delta), maxOffset)
    }
}
