// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit

// MARK: - CardTrackListView

/// A choice menu in the rail's glass popup, cloned from AVKit's tvOS 26 tool
/// menus (`AVUnifiedPlayerContextMenuViewController`). Metrics were read from
/// AVKit's live view tree (DEBUG `AVKitScrubProbe`, RIVULET_SCRUBPROBE=menus):
/// a 70pt section header, 66pt rows (86 with a second line), a checkmark column,
/// and a focused row that turns into a white pill. Fills the popup edge to edge;
/// its own insets match AVKit's.
final class CardTrackListView: UIView {

    /// AVKit's menus are a fixed 450pt wide.
    static let menuWidth: CGFloat = 450

    fileprivate enum Metrics {
        static let headerHeight: CGFloat = 70
        static let headerLabelCenterY: CGFloat = 39.5
        static let headerLabelLeading: CGFloat = 35
        static let rowInset: CGFloat = 21
        static let bottomInset: CGFloat = 18
        static let separatorInset: CGFloat = 15
        static let separatorGap: CGFloat = 18
        static let rowHeight: CGFloat = 66
        static let twoLineRowHeight: CGFloat = 86
        static let checkColumnX: CGFloat = 21
        static let checkColumnWidth: CGFloat = 32
        static let titleX: CGFloat = 69
        static let rowRadius: CGFloat = 33
        /// Focused rows grow 4pt each side, and their content scales to match.
        static let focusGrowth: CGFloat = 4
        static let focusScale: CGFloat = 416 / 408
        static let titleFont = UIFont.systemFont(ofSize: 25, weight: .medium)
        static let secondaryFont = UIFont.systemFont(ofSize: 23, weight: .medium)
        /// AVKit draws secondary text white 0.5 and rules white 0.3 plus-lighter over
        /// its glass; these normal-blend alphas land on the same pixels over it.
        static let secondaryColor = UIColor.white.withAlphaComponent(0.8)
        static let separatorColor = UIColor.white.withAlphaComponent(0.46)
    }

    struct Row {
        let title: String
        let subtitle: String?
        let trackId: Int?
        let isSelected: Bool
    }

    private let rows: [Row]
    private let steppers: [CardStepperConfig]
    private let onSelect: (Int?) -> Void
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var rowButtons: [CardTrackRowButton] = []
    private var stepperRows: [CardStepperRowView] = []
    /// Pin focus to the selected row only for the FIRST landing. After focus
    /// has entered the list once, `preferredFocusEnvironments` holds the row
    /// focus is on, so an edge press stops instead of bouncing to the selection.
    private var hasPinnedInitialFocus = false
    /// The control focus is on: a track row or a stepper's -/+ button.
    private weak var lastFocusedControl: UIView?

    convenience init(header: String, tracks: [MediaTrack], selectedTrackId: Int?, showsOffRow: Bool,
                     steppers: [CardStepperConfig] = [], onSelect: @escaping (Int?) -> Void) {
        var rows: [Row] = []
        if showsOffRow {
            rows.append(Row(title: "Off", subtitle: nil, trackId: nil, isSelected: selectedTrackId == nil))
        }
        rows.append(contentsOf: tracks.map { track in
            Row(
                title: track.name,
                subtitle: [track.language, track.codec?.uppercased()].compactMap { $0 }.joined(separator: " • "),
                trackId: track.id,
                isSelected: track.id == selectedTrackId
            )
        })
        self.init(header: header, rows: rows, steppers: steppers, onSelect: onSelect)
    }

    /// A plain list of choices: each row's `trackId` is what `onSelect` receives.
    init(header: String, rows: [Row], steppers: [CardStepperConfig] = [],
         onSelect: @escaping (Int?) -> Void) {
        self.rows = rows
        self.steppers = steppers
        self.onSelect = onSelect
        super.init(frame: .zero)
        setupViews(header: header)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews(header: String) {
        let headerLabel = UILabel()
        headerLabel.text = header
        headerLabel.font = Metrics.secondaryFont
        headerLabel.textColor = Metrics.secondaryColor
        addSubview(headerLabel)

        stack.axis = .vertical
        scrollView.addSubview(stack)
        scrollView.clipsToBounds = true
        addSubview(scrollView)

        [headerLabel, scrollView, stack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        // The scroll view grows with content up to the popup's cap, so short
        // lists hug their rows and long ones scroll. Kept below the header's
        // compression resistance so an overflow scrolls instead of squashing it.
        let scrollHeight = scrollView.heightAnchor.constraint(
            equalTo: stack.heightAnchor, constant: Metrics.bottomInset)
        scrollHeight.priority = .defaultHigh - 1

        NSLayoutConstraint.activate([
            headerLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: Metrics.headerLabelCenterY),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.headerLabelLeading),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.headerLabelLeading),

            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.headerHeight),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollHeight,

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: Metrics.rowInset),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -Metrics.rowInset),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -Metrics.bottomInset),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -2 * Metrics.rowInset),
        ])

        for row in rows {
            let button = CardTrackRowButton(row: row)
            button.onTap = { [weak self] in
                self?.onSelect(row.trackId)
            }
            stack.addArrangedSubview(button)
            rowButtons.append(button)
        }

        // Adjustment steppers (delay / height) sit in their own section below a
        // separator. A press adjusts in place and leaves the popup up, so the
        // user can watch the subtitles move as they step.
        if !steppers.isEmpty, !rowButtons.isEmpty {
            stack.addArrangedSubview(MenuSeparatorView())
        }
        for config in steppers {
            let row = CardStepperRowView(config: config)
            stack.addArrangedSubview(row)
            stepperRows.append(row)
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // After the first landing, hold the CURRENT row: when an edge press
        // finds no in-popup candidate the popup's fence re-resolves through
        // here, and returning the focused row makes focus stop at the edge
        // instead of looping to the top.
        if hasPinnedInitialFocus {
            return lastFocusedControl.map { [$0] } ?? []
        }
        if let first = rowButtons.first(where: { $0.row.isSelected }) {
            return [first]
        }
        if let firstRow = rowButtons.first { return [firstRow] }
        return stepperRows.isEmpty ? [self] : [stepperRows[0]]
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard let next = context.nextFocusedView, next.isDescendant(of: self) else { return }
        if let row = rowButtons.first(where: { next.isDescendant(of: $0) || next === $0 }) {
            hasPinnedInitialFocus = true
            lastFocusedControl = row
        } else if stepperRows.contains(where: { next.isDescendant(of: $0) }) {
            // The stepper row isn't focusable; its -/+ buttons are.
            hasPinnedInitialFocus = true
            lastFocusedControl = next
        }
    }
}

// MARK: - MenuSeparatorView

/// AVKit's section break: an 18pt gap, then a 1pt line inset 15pt from the rows.
private final class MenuSeparatorView: UIView {
    init() {
        super.init(frame: .zero)
        let line = UIView()
        line.backgroundColor = CardTrackListView.Metrics.separatorColor
        addSubview(line)
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: CardTrackListView.Metrics.separatorGap + 1),
            line.heightAnchor.constraint(equalToConstant: 1),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CardTrackListView.Metrics.separatorInset),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CardTrackListView.Metrics.separatorInset),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - CardStepperConfig

/// One adjustment stepper in the menu: a title, a formatted value provider,
/// and a step handler (`-1` / `+1`). The row re-reads `value()` after every
/// press, so the handler owns clamping and persistence.
struct CardStepperConfig {
    let title: String
    let value: () -> String
    let onStep: (Int) -> Void
}

// MARK: - CardStepperRowView

/// `Title        (-)  value  (+)` in a menu row. The -/+ buttons are focusable;
/// the value updates on every press.
final class CardStepperRowView: UIView {

    private let config: CardStepperConfig
    private let valueLabel = UILabel()

    init(config: CardStepperConfig) {
        self.config = config
        super.init(frame: .zero)

        let titleLabel = UILabel()
        titleLabel.text = config.title
        titleLabel.font = CardTrackListView.Metrics.titleFont
        titleLabel.textColor = .white

        let minus = CardStepperButton(symbolName: "minus")
        let plus = CardStepperButton(symbolName: "plus")
        minus.onTap = { [weak self] in self?.step(-1) }
        plus.onTap = { [weak self] in self?.step(+1) }

        valueLabel.text = config.value()
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 23, weight: .medium)
        valueLabel.textColor = CardTrackListView.Metrics.secondaryColor
        valueLabel.textAlignment = .center

        [titleLabel, minus, valueLabel, plus].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        let button: CGFloat = 52
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: CardTrackListView.Metrics.rowHeight),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CardTrackListView.Metrics.titleX),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            plus.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            plus.centerYAnchor.constraint(equalTo: centerYAnchor),
            plus.widthAnchor.constraint(equalToConstant: button),
            plus.heightAnchor.constraint(equalToConstant: button),

            valueLabel.trailingAnchor.constraint(equalTo: plus.leadingAnchor, constant: -8),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 70),

            minus.trailingAnchor.constraint(equalTo: valueLabel.leadingAnchor, constant: -8),
            minus.centerYAnchor.constraint(equalTo: centerYAnchor),
            minus.widthAnchor.constraint(equalToConstant: button),
            minus.heightAnchor.constraint(equalToConstant: button),
            minus.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func step(_ direction: Int) {
        config.onStep(direction)
        valueLabel.text = config.value()
    }
}

// MARK: - CardStepperButton

/// Round -/+ control: faint fill at rest, white with a black glyph when focused.
final class CardStepperButton: UIControl {

    var onTap: (() -> Void)?
    private let symbolView: UIImageView

    init(symbolName: String) {
        symbolView = UIImageView(image: UIImage(
            systemName: symbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .bold)
        ))
        super.init(frame: .zero)

        symbolView.tintColor = .white
        symbolView.contentMode = .center
        addSubview(symbolView)
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            symbolView.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        backgroundColor = UIColor.white.withAlphaComponent(0.1)
        layer.cornerRadius = 26
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFocused: Bool { true }

    // Select does not fire .primaryActionTriggered on a plain UIControl on tvOS.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .select {
            onTap?()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let isFocused = context.nextFocusedView === self
        coordinator.animateFocusChange(gained: isFocused) {
            self.backgroundColor = isFocused ? .white : UIColor.white.withAlphaComponent(0.1)
            self.symbolView.tintColor = isFocused ? .black : .white
            self.transform = isFocused ? CGAffineTransform(scaleX: 1.1, y: 1.1) : .identity
        }
    }
}

// MARK: - CardTrackRowButton

/// One menu row: checkmark column, title, optional second line. Focused, a
/// white pill grows 4pt past the row with AVKit's shadow and the content scales
/// with it.
final class CardTrackRowButton: UIControl {

    let row: CardTrackListView.Row
    var onTap: (() -> Void)?
    private let pill = UIView()
    private let content = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let checkmarkView = UIImageView(image: UIImage(
        systemName: "checkmark",
        // Matches AVKit's glyph by rendered ink, not by its reported 19x17 size.
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)
    ))

    init(row: CardTrackListView.Row) {
        self.row = row
        super.init(frame: .zero)
        typealias M = CardTrackListView.Metrics

        let hasSubtitle = !(row.subtitle?.isEmpty ?? true)

        pill.layer.cornerRadius = M.rowRadius
        pill.layer.cornerCurve = .continuous
        pill.layer.shadowColor = UIColor.black.cgColor
        pill.layer.shadowOffset = CGSize(width: 0, height: 20)
        pill.layer.shadowRadius = 15
        pill.isUserInteractionEnabled = false
        content.isUserInteractionEnabled = false

        titleLabel.text = row.title
        titleLabel.font = M.titleFont
        titleLabel.textColor = .white

        subtitleLabel.text = row.subtitle
        subtitleLabel.font = M.secondaryFont
        subtitleLabel.textColor = M.secondaryColor
        subtitleLabel.isHidden = !hasSubtitle

        checkmarkView.tintColor = .white
        checkmarkView.isHidden = !row.isSelected
        checkmarkView.contentMode = .center

        addSubview(pill)
        addSubview(content)
        [checkmarkView, titleLabel, subtitleLabel].forEach { content.addSubview($0) }

        [content, checkmarkView, titleLabel, subtitleLabel].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        var constraints = [
            heightAnchor.constraint(equalToConstant: hasSubtitle ? M.twoLineRowHeight : M.rowHeight),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),

            checkmarkView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: M.checkColumnX),
            checkmarkView.widthAnchor.constraint(equalToConstant: M.checkColumnWidth),
            checkmarkView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: M.titleX),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -M.checkColumnX),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -M.checkColumnX),
        ]
        if hasSubtitle {
            constraints += [
                titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 13),
                subtitleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 45),
            ]
        } else {
            constraints.append(titleLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        applyFocus(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let isFocused = self.isFocused
        pill.frame = isFocused ? bounds.insetBy(dx: -CardTrackListView.Metrics.focusGrowth,
                                                dy: -CardTrackListView.Metrics.focusGrowth) : bounds
        pill.layer.shadowPath = UIBezierPath(roundedRect: pill.bounds, cornerRadius: pill.layer.cornerRadius).cgPath
    }

    override var canBecomeFocused: Bool { true }

    // Select does not fire .primaryActionTriggered on a plain UIControl
    // on tvOS; handle the press directly.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .select {
            onTap?()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let isFocused = context.nextFocusedView === self
        coordinator.animateFocusChange(gained: isFocused) {
            self.applyFocus(isFocused)
        }
    }

    private func applyFocus(_ focused: Bool) {
        typealias M = CardTrackListView.Metrics
        let growth = focused ? M.focusGrowth : 0
        pill.frame = bounds.insetBy(dx: -growth, dy: -growth)
        pill.layer.cornerRadius = M.rowRadius + growth
        pill.layer.shadowPath = UIBezierPath(roundedRect: pill.bounds, cornerRadius: pill.layer.cornerRadius).cgPath
        pill.backgroundColor = focused ? .white : .clear
        pill.layer.shadowOpacity = focused ? 0.3 : 0
        content.transform = focused ? CGAffineTransform(scaleX: M.focusScale, y: M.focusScale) : .identity
        titleLabel.textColor = focused ? .black : .white
        subtitleLabel.textColor = focused ? UIColor.black.withAlphaComponent(0.6) : M.secondaryColor
        checkmarkView.tintColor = focused ? .black : .white
    }
}
