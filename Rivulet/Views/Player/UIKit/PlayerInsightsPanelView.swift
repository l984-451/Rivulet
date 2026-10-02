// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerInsightsPanelView.swift
//  Rivulet
//
//  Cast list content for the Insights rail panel (P1), plus the read-only
//  Trivia section (P2a) appended below it in the same scroll view. Structure
//  and focus behavior mirror UpNextListView: scroll + stack, capped height,
//  pin-first-focus-then-free. Cast rows deep-link to the actor crossfade;
//  trivia rows are plain (non-focusable) text — read-only, scrollable only,
//  no per-fact action yet (Report lands in P2b).
//

import UIKit

final class InsightsCastListView: UIView {

    private enum Metrics {
        static let maxHeight: CGFloat = 620
        // Horizontal inset for the row stack inside the scroll view so the
        // focused row's 1.02 scale doesn't overflow the clipping scroll
        // view's left/right edges. Matches UpNextListView.
        static let rowInset: CGFloat = 8
    }

    /// The panel's overall width is a fixed constant (`PlayerRailPanelView`
    /// presents Insights at width 640 — see `PlayerContainerViewController`),
    /// so the trivia row's final text width is knowable up front rather than
    /// discovered from a layout pass: 640 - 2*20 (PlayerRailPanelView content
    /// padding) - 2*rowInset (this stack's own inset) - 2*18 (row's own
    /// internal padding, `InsightsTriviaRowView`). Computing the row's
    /// intrinsic height from this fixed width up front (instead of waiting
    /// for `layoutSubviews`) avoids the width-before-height circular
    /// dependency that left every trivia row pinned to UIStackView's ~44pt
    /// ambiguous-layout fallback regardless of actual text length.
    static let triviaRowContentWidth: CGFloat = 640 - 2 * 20 - 2 * Metrics.rowInset - 2 * 18

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var castRows: [InsightsCastRowButton] = []
    /// Every focusable row in the CURRENTLY DISPLAYED tab's content, in
    /// display order. Rebuilt on every `setTab`/`init`. Trivia rows are
    /// focusable purely so the tvOS focus engine can scroll to them; without
    /// them here the panel can't scroll past a single-tab's trivia list.
    private var focusableRows: [UIView] = []
    /// Pin focus to the first row only on the FIRST landing of the CURRENT
    /// tab; reset to false on every `setTab` so switching tabs re-lands
    /// focus on that tab's first row rather than leaving it stranded on a
    /// now-hidden row from the previous tab.
    private var hasPinnedInitialFocus = false
    /// The row focus is currently on, held by `preferredFocusEnvironments`
    /// so a denied edge move re-resolves in place instead of looping to the
    /// first row (see there).
    private weak var lastFocusedRow: UIView?
    /// When focus last moved within this list, for `canEscapeUpward`'s
    /// same-press gate. Starts outside any window.
    private var lastFocusMoveTime: CFTimeInterval = -.greatestFiniteMagnitude

    private let cast: [MediaPerson]
    private let trivia: TitleTrivia?
    private let suppressedTriviaIDs: Set<String>
    private let onSelectCast: (MediaPerson) -> Void

    /// Number of trivia fact rows currently in the stack (i.e. for the
    /// currently displayed tab). Internal (not private) so `@testable import
    /// Rivulet` tests can assert tab-scoped row counts without reaching into
    /// UIKit's `UIStackView.arrangedSubviews` directly.
    var triviaRowCount: Int {
        stack.arrangedSubviews.filter { $0 is InsightsTriviaRowView }.count
    }
    /// Whether the current tab's trivia section has any rows. Kept for the
    /// pre-existing `InsightsTriviaPanelTests` graceful-absent assertions
    /// (Task 4 Step 9 rewrites that file for the new tab-scoped API, but
    /// keeps this exact property name/meaning).
    var hasTriviaSection: Bool { triviaRowCount > 0 }
    /// Number of cast rows currently in the stack. Internal for the same
    /// testing reason as `triviaRowCount`.
    var castRowCount: Int {
        stack.arrangedSubviews.filter { $0 is InsightsCastRowButton }.count
    }

    init(
        cast: [MediaPerson],
        trivia: TitleTrivia?,
        suppressedTriviaIDs: Set<String>,
        initialTab: InsightsTab,
        onSelectCast: @escaping (MediaPerson) -> Void
    ) {
        self.cast = cast
        self.trivia = trivia
        self.suppressedTriviaIDs = suppressedTriviaIDs
        self.onSelectCast = onSelectCast
        super.init(frame: .zero)
        setupContent()
        buildRows(for: initialTab)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupContent() {
        stack.axis = .vertical
        stack.spacing = 8
        scrollView.addSubview(stack)
        scrollView.clipsToBounds = true
        // The focus engine's own default scroll-to-visible fights a
        // self-driven offset (see InsightsFilmographyRowView's identical
        // rationale) — and critically, leaving this enabled traps Up/Down
        // spatial focus search inside the scroll view, so it can never
        // escape to a sibling like the tab bar above. Disabling it and
        // driving contentOffset ourselves from didUpdateFocus (below) is
        // both the scroll fix and the fix for focus escaping upward.
        scrollView.isScrollEnabled = false

        [scrollView, stack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(scrollView)

        // Scroll view caps content up to a maxHeight, so a short tab's
        // content hugs its rows while a long one scrolls.
        let scrollHeight = scrollView.heightAnchor.constraint(equalTo: stack.heightAnchor)
        scrollHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollHeight,
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: Metrics.maxHeight),

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: Metrics.rowInset),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -Metrics.rowInset),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -(Metrics.rowInset * 2)),
        ])
    }

    /// Tears down the current tab's rows and builds the given tab's rows in
    /// their place. Resets scroll position and focus-pinning so the existing
    /// pin-first-focus-then-free landing behavior re-runs for the new
    /// content (mirrors how a fresh `UpNextListView` lands focus on reload).
    func setTab(_ tab: InsightsTab) {
        castRows.forEach { $0.cancelImageLoad() }
        castRows.removeAll()
        focusableRows.removeAll()
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        hasPinnedInitialFocus = false
        scrollView.setContentOffset(.zero, animated: false)
        buildRows(for: tab)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func buildRows(for tab: InsightsTab) {
        switch tab {
        case .topTen:
            let facts = trivia?.topTenFacts(suppressed: suppressedTriviaIDs) ?? []
            buildTriviaRows(facts)
            addAttributionFooterIfNeeded()
        case .cast:
            buildCastRows(cast)
        case .category(let category):
            let facts = (trivia?.visibleFacts(suppressed: suppressedTriviaIDs) ?? [])
                .filter { $0.category == category }
            buildTriviaRows(facts)
            addAttributionFooterIfNeeded()
        }
    }

    private func buildTriviaRows(_ facts: [TriviaFact]) {
        for fact in facts {
            let row = InsightsTriviaRowView(fact: fact, contentWidth: Self.triviaRowContentWidth)
            stack.addArrangedSubview(row)
            focusableRows.append(row)
        }
    }

    private func buildCastRows(_ cast: [MediaPerson]) {
        for person in cast {
            let row = InsightsCastRowButton(person: person)
            row.onTap = { [onSelectCast] in onSelectCast(person) }
            stack.addArrangedSubview(row)
            castRows.append(row)
            focusableRows.append(row)
        }
    }

    private func addAttributionFooterIfNeeded() {
        guard let trivia, !trivia.attribution.isEmpty, let last = stack.arrangedSubviews.last else { return }
        let footer = UILabel()
        footer.numberOfLines = 1
        footer.font = .systemFont(ofSize: 15, weight: .regular)
        footer.textColor = UIColor.white.withAlphaComponent(0.35)
        let names = trivia.attribution.map(\.name).joined(separator: " · ")
        footer.text = "Info from \(names)"
        stack.setCustomSpacing(12, after: last)
        stack.addArrangedSubview(footer)
    }

    // MARK: - Teardown

    override func removeFromSuperview() {
        castRows.forEach { $0.cancelImageLoad() }
        super.removeFromSuperview()
    }

    deinit {
        castRows.forEach { $0.cancelImageLoad() }
    }

    // MARK: - Focus

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // After the first landing, hold the CURRENT row so a denied edge move
        // re-resolves in place instead of looping to the first row (see
        // CardTrackListView for the full rationale). Directional row-to-row
        // moves never consult this.
        if hasPinnedInitialFocus {
            return lastFocusedRow.map { [$0] } ?? []
        }
        if let first = focusableRows.first { return [first] }
        return [self]
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        // A SELF-move is not a move (same trap as `InfoScrollView`): Up on the
        // first row has no candidate, so `preferredFocusEnvironments` re-affirms
        // that row and the engine reports an update from it TO ITSELF. Stamping
        // the clock for it re-armed `SamePressFocusGate`, so `canEscapeUpward`
        // was false on every Up press and the tab bar was unreachable.
        guard let next = context.nextFocusedView,
              next !== context.previouslyFocusedView,
              let row = focusableRows.first(where: { next.isDescendant(of: $0) || next === $0 })
        else { return }
        // Once focus enters any of our rows, stop pinning the first row and
        // remember which row holds focus (see preferredFocusEnvironments).
        hasPinnedInitialFocus = true
        lastFocusedRow = row
        lastFocusMoveTime = CACurrentMediaTime()
        scrollFocusedRowIntoView(row, coordinator: coordinator)
    }

    /// Consulted by `InsightsPanelContainerView.pressesBegan` to decide whether
    /// an Up press should escape to the tab bar above (the focus engine's own
    /// directional search does not reliably cross this list's scroll-view
    /// boundary). True when focus is on this list's first row AND the engine did
    /// not just move it there.
    ///
    /// Without that second half, an Up press from row 1 escaped to the tabs:
    /// the engine moves focus to row 0 a few ms before this press arrives, so
    /// the first-row test was already true and row 0 was jumped over. See
    /// `SamePressFocusGate`. Named to match `InfoScrollView.canEscapeUpward`,
    /// which answers the same question for the Info popup.
    var canEscapeUpward: Bool {
        guard !SamePressFocusGate.justMovedFocus(at: lastFocusMoveTime) else { return false }
        guard let focused = UIFocusSystem.focusSystem(for: self)?.focusedItem as? UIView,
              let first = focusableRows.first
        else { return false }
        return focused === first || focused.isDescendant(of: first)
    }

    /// Self-driven vertical scroll (scrollView.isScrollEnabled = false above),
    /// CENTER-anchored — the same feel as the tab bar's pill scroll, adapted
    /// to a vertical list. The focused row is pulled toward the middle of the
    /// visible window, clamped at the content edges: near the top, focus walks
    /// down through the first rows while the list holds still; through the
    /// middle, rows stream up through the centre so a partially-visible next
    /// row always signals there's more below; at the end the list settles on
    /// the true bottom for the last row.
    private func scrollFocusedRowIntoView(_ row: UIView, coordinator: UIFocusAnimationCoordinator) {
        let rowFrameInScroll = row.convert(row.bounds, to: scrollView)
        let targetY = rowFrameInScroll.midY - scrollView.bounds.height / 2
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let clamped = min(max(0, targetY), maxY)
        guard abs(clamped - scrollView.contentOffset.y) > 0.5 else { return }
        coordinator.addCoordinatedAnimations({
            self.scrollView.contentOffset.y = clamped
        }, completion: nil)
    }
}

// MARK: - InsightsCastRowButton

final class InsightsCastRowButton: UIControl {

    var onTap: (() -> Void)?

    private let headshotView = UIImageView()
    private let fallbackIcon = UIImageView(image: UIImage(systemName: "person.crop.circle.fill"))
    private let nameLabel = UILabel()
    private let roleLabel = UILabel()
    private var imageLoadTask: Task<Void, Never>?

    private static let restBackground = UIColor.white.withAlphaComponent(0.06)
    private static let focusedBackground = UIColor.white.withAlphaComponent(0.16)
    private static let restBorder = UIColor.clear.cgColor
    private static let focusedBorder = UIColor.white.withAlphaComponent(0.25).cgColor
    private static let headshotSide: CGFloat = 82

    init(person: MediaPerson) {
        super.init(frame: .zero)
        setupViews(person: person)
        loadHeadshot(person.imageURL)
        applyRestAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        imageLoadTask?.cancel()
    }

    override var canBecomeFocused: Bool { true }

    private func setupViews(person: MediaPerson) {
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = Self.restBorder

        let side = Self.headshotSide
        headshotView.contentMode = .scaleAspectFill
        headshotView.clipsToBounds = true
        headshotView.layer.cornerRadius = side / 2
        headshotView.backgroundColor = UIColor.white.withAlphaComponent(0.08)

        fallbackIcon.tintColor = UIColor.white.withAlphaComponent(0.35)
        fallbackIcon.contentMode = .scaleAspectFit
        headshotView.addSubview(fallbackIcon)

        nameLabel.text = person.name
        nameLabel.font = .systemFont(ofSize: 27, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.numberOfLines = 1

        let role = person.role ?? ""
        roleLabel.text = role
        roleLabel.font = .systemFont(ofSize: 21, weight: .regular)
        roleLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        roleLabel.numberOfLines = 1
        roleLabel.isHidden = role.isEmpty

        let textStack = UIStackView(arrangedSubviews: [nameLabel, roleLabel])
        textStack.axis = .vertical
        textStack.spacing = 4
        textStack.isUserInteractionEnabled = false

        [headshotView, textStack].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        fallbackIcon.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 92),

            headshotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            headshotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            headshotView.widthAnchor.constraint(equalToConstant: side),
            headshotView.heightAnchor.constraint(equalToConstant: side),

            fallbackIcon.centerXAnchor.constraint(equalTo: headshotView.centerXAnchor),
            fallbackIcon.centerYAnchor.constraint(equalTo: headshotView.centerYAnchor),
            fallbackIcon.widthAnchor.constraint(equalToConstant: 34),
            fallbackIcon.heightAnchor.constraint(equalToConstant: 34),

            textStack.leadingAnchor.constraint(equalTo: headshotView.trailingAnchor, constant: 14),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func loadHeadshot(_ url: URL?) {
        guard let url else { return }
        imageLoadTask = Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url)
            guard let self, !Task.isCancelled else { return }
            if let image {
                self.headshotView.image = image
                self.fallbackIcon.isHidden = true
            }
        }
    }

    func cancelImageLoad() {
        imageLoadTask?.cancel()
        imageLoadTask = nil
    }

    private func applyRestAppearance() {
        backgroundColor = Self.restBackground
        layer.borderColor = Self.restBorder
        transform = .identity
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let isFocused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({
            self.backgroundColor = isFocused ? Self.focusedBackground : Self.restBackground
            self.layer.borderColor = isFocused ? Self.focusedBorder : Self.restBorder
            self.transform = isFocused ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
        }, completion: nil)
    }

    // Select does not fire .primaryActionTriggered on plain UIControl on
    // tvOS; handle the press directly (same trap as UpNextRowButton).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .select {
            onTap?()
            return
        }
        super.pressesBegan(presses, with: event)
    }
}

// MARK: - InsightsTriviaRowView

/// One trivia fact row: fact text + a small category label. Read-only, but
/// FOCUSABLE — on tvOS a non-focusable row is unreachable in a focus-driven
/// scroll view, so making the fact rows focusable is what lets the panel scroll
/// through the trivia at all. Focus gives a subtle highlight (no scale, to stay
/// calm and read as read-only vs. the interactive cast rows); Select does
/// nothing yet (Report is P2b).
final class InsightsTriviaRowView: UIView {

    private let textLabel = UILabel()
    private let categoryLabel = UILabel()

    private static let restBackground = UIColor.white.withAlphaComponent(0.06)
    private static let focusedBackground = UIColor.white.withAlphaComponent(0.16)
    private static let focusedBorder = UIColor.white.withAlphaComponent(0.25).cgColor

    /// - Parameter contentWidth: the row's final text width, known up front
    ///   by the caller (see `InsightsCastListView.triviaRowContentWidth`).
    ///   Set as `textLabel.preferredMaxLayoutWidth` so the multi-line label's
    ///   intrinsic height is computed from the real wrap width immediately,
    ///   rather than from a `layoutSubviews` pass that hasn't happened yet —
    ///   avoiding the width-before-height circular dependency that otherwise
    ///   leaves the row pinned to UIStackView's ambiguous-layout fallback
    ///   height regardless of actual text length.
    init(fact: TriviaFact, contentWidth: CGFloat) {
        super.init(frame: .zero)

        backgroundColor = Self.restBackground
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.clear.cgColor

        textLabel.text = fact.text
        textLabel.font = .systemFont(ofSize: 25, weight: .regular)
        textLabel.textColor = .white
        textLabel.numberOfLines = 0
        textLabel.preferredMaxLayoutWidth = contentWidth
        // Required vertical compression resistance so the row NEVER collapses
        // below its wrapped text. The hosting scroll view couples its own
        // (panel-capped) height to the row stack's height at .defaultHigh
        // (see InsightsCastListView.setupContent); on a tab with many facts
        // that coupling tries to shrink the stack to the capped height, and
        // at the label's default resistance (also .defaultHigh) the tie
        // collapsed every row to UIStackView's ~44pt ambiguous fallback —
        // the "same-sized empty containers" bug. Beating that coupling here
        // makes it break instead, so the content stays full-height and
        // scrolls. (Cast rows never hit this: they pin a required height.)
        textLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        categoryLabel.attributedText = NSAttributedString(
            string: fact.category.tabDisplayName.uppercased(),
            attributes: [
                .font: UIFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.45),
                .kern: 1.0,
            ]
        )

        let contentStack = UIStackView(arrangedSubviews: [textLabel, categoryLabel])
        contentStack.axis = .vertical
        contentStack.spacing = 8
        contentStack.isUserInteractionEnabled = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
        ])
    }

    override var canBecomeFocused: Bool { true }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let isFocused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({
            self.backgroundColor = isFocused ? Self.focusedBackground : Self.restBackground
            self.layer.borderColor = isFocused ? Self.focusedBorder : UIColor.clear.cgColor
        }, completion: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
