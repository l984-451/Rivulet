import UIKit

// MARK: - CardTrackListView (Task 6 — ported from PlayerTrackPopupView)

/// In-card track list panel for Subtitles/Audio. Ported from
/// PlayerTrackPopupView: same row model, scroll+stack layout, and
/// system-picker row focus treatment, minus the glass background and
/// AnchoredPopupPresenting conformance/Menu handling — the card owns
/// Menu and framing now.
final class CardTrackListView: UIView {

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
    /// has entered the list once, `preferredFocusEnvironments` yields no
    /// preference so the focus engine leaves focus on whatever row the user
    /// navigated to — otherwise reaching the bottom and pressing Down would
    /// re-resolve focus back up to the selected row (the "bounce").
    private var hasPinnedInitialFocus = false
    /// The control focus is currently on (a track row or a stepper button),
    /// tracked so `preferredFocusEnvironments` can hold it (see there).
    private weak var lastFocusedControl: UIView?

    init(header: String, tracks: [MediaTrack], selectedTrackId: Int?, showsOffRow: Bool,
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
        headerLabel.font = .systemFont(ofSize: 26, weight: .bold)
        headerLabel.textColor = .white
        addSubview(headerLabel)

        stack.axis = .vertical
        stack.spacing = 2
        scrollView.addSubview(stack)
        scrollView.clipsToBounds = true
        addSubview(scrollView)

        [headerLabel, scrollView, stack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        // The scroll view grows with content up to a cap, so short lists
        // hug their rows and long ones scroll.
        let scrollHeight = scrollView.heightAnchor.constraint(equalTo: stack.heightAnchor)
        scrollHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: topAnchor),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollHeight,

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])

        for row in rows {
            let button = CardTrackRowButton(row: row)
            button.onTap = { [weak self] in
                self?.onSelect(row.trackId)
            }
            stack.addArrangedSubview(button)
            rowButtons.append(button)
        }

        // Adjustment steppers (delay / height) under the track rows, each
        // with a small section label. Presses adjust in place — the panel
        // stays up so the user can see the subtitles move as they step.
        for config in steppers {
            let sectionLabel = UILabel()
            sectionLabel.text = config.title
            sectionLabel.font = .systemFont(ofSize: 17, weight: .semibold)
            sectionLabel.textColor = UIColor.white.withAlphaComponent(0.55)
            stack.addArrangedSubview(sectionLabel)
            stack.setCustomSpacing(14, after: stepperRows.last ?? rowButtons.last ?? sectionLabel)
            stack.setCustomSpacing(6, after: sectionLabel)

            let row = CardStepperRowView(config: config)
            stack.addArrangedSubview(row)
            stepperRows.append(row)
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // After the first landing, hold the CURRENT row (not `[]`, not the
        // selected row). When Down at the last row / Up at the first finds
        // no in-panel candidate, the panel's focus fence denies the exit and
        // the engine re-resolves focus via this preference — returning `[]`
        // let it fall back to the first focusable, so the list "looped" from
        // bottom to top. Returning the row focus already sits on makes that
        // re-resolution a no-op: focus simply STOPS at the edge. It doesn't
        // interfere with row-to-row moves (directional focus never consults
        // preferredFocusEnvironments).
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
        // Once focus enters any of our controls, stop pinning the selected
        // row and remember which control holds focus (see
        // preferredFocusEnvironments). Stepper +/- buttons count too —
        // holding a track row here instead would yank focus off the stepper
        // whenever an edge press re-resolves through the panel fence.
        guard let next = context.nextFocusedView, next.isDescendant(of: self) else { return }
        if let row = rowButtons.first(where: { next.isDescendant(of: $0) || next === $0 }) {
            hasPinnedInitialFocus = true
            lastFocusedControl = row
        } else if stepperRows.contains(where: { next.isDescendant(of: $0) }) {
            hasPinnedInitialFocus = true
            lastFocusedControl = next
        }
    }
}

// MARK: - CardStepperConfig

/// One adjustment stepper in the panel: a section title, a formatted value
/// provider, and a step handler (`-1` / `+1`). The row re-reads `value()`
/// after every press, so the handler owns clamping and persistence.
struct CardStepperConfig {
    let title: String
    let value: () -> String
    let onStep: (Int) -> Void
}

// MARK: - CardStepperRowView

/// `[-]   value   [+]` — the minus/plus ends are focusable; the centre label
/// shows the current value ("0.0s", "+3", …) and updates on every press.
final class CardStepperRowView: UIView {

    private let config: CardStepperConfig
    private let valueLabel = UILabel()

    init(config: CardStepperConfig) {
        self.config = config
        super.init(frame: .zero)

        let minus = CardStepperButton(symbolName: "minus")
        let plus = CardStepperButton(symbolName: "plus")
        minus.onTap = { [weak self] in self?.step(-1) }
        plus.onTap = { [weak self] in self?.step(+1) }

        valueLabel.text = config.value()
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 23, weight: .medium)
        valueLabel.textColor = .white
        valueLabel.textAlignment = .center

        [minus, valueLabel, plus].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 60),

            minus.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            minus.centerYAnchor.constraint(equalTo: centerYAnchor),
            minus.widthAnchor.constraint(equalToConstant: 64),
            minus.heightAnchor.constraint(equalToConstant: 52),

            plus.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            plus.centerYAnchor.constraint(equalTo: centerYAnchor),
            plus.widthAnchor.constraint(equalToConstant: 64),
            plus.heightAnchor.constraint(equalToConstant: 52),

            valueLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: minus.trailingAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: plus.leadingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func step(_ direction: Int) {
        config.onStep(direction)
        valueLabel.text = config.value()
    }
}

// MARK: - CardStepperButton

/// Round-rect +/- control matching the track rows' focus treatment
/// (white fill, black glyph when focused).
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

        backgroundColor = UIColor.white.withAlphaComponent(0.08)
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFocused: Bool { true }

    // Same tvOS trap as CardTrackRowButton: Select never fires
    // .primaryActionTriggered on a plain UIControl — handle the press.
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
        coordinator.addCoordinatedAnimations({
            self.backgroundColor = isFocused ? .white : UIColor.white.withAlphaComponent(0.08)
            self.symbolView.tintColor = isFocused ? .black : .white
        }, completion: nil)
    }
}

// MARK: - CardTrackRowButton (verbatim port of PopupRowButton)

final class CardTrackRowButton: UIControl {

    let row: CardTrackListView.Row
    var onTap: (() -> Void)?
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let checkmarkView = UIImageView(image: UIImage(
        systemName: "checkmark",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold)
    ))
    private let vStack = UIStackView()

    init(row: CardTrackListView.Row) {
        self.row = row
        super.init(frame: .zero)

        titleLabel.text = row.title
        titleLabel.font = .systemFont(ofSize: 23, weight: .medium)
        titleLabel.textColor = .white

        subtitleLabel.text = row.subtitle
        subtitleLabel.font = .systemFont(ofSize: 17, weight: .regular)
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        subtitleLabel.isHidden = row.subtitle == nil || row.subtitle?.isEmpty == true

        vStack.axis = .vertical
        vStack.spacing = 2
        vStack.isUserInteractionEnabled = false
        vStack.addArrangedSubview(titleLabel)
        vStack.addArrangedSubview(subtitleLabel)

        // Leading checkmark column, reserved for every row so titles
        // align whether or not a row is selected (system-picker layout).
        checkmarkView.tintColor = .white
        checkmarkView.isHidden = !row.isSelected
        checkmarkView.contentMode = .center

        addSubview(checkmarkView)
        addSubview(vStack)

        [vStack, checkmarkView].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            checkmarkView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            checkmarkView.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkmarkView.widthAnchor.constraint(equalToConstant: 26),

            vStack.leadingAnchor.constraint(equalTo: checkmarkView.trailingAnchor, constant: 14),
            vStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            vStack.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            vStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),

            heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])

        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        coordinator.addCoordinatedAnimations({
            // System-picker focus treatment: white fill, black content.
            self.backgroundColor = isFocused ? .white : .clear
            self.titleLabel.textColor = isFocused ? .black : .white
            self.subtitleLabel.textColor = isFocused
                ? UIColor.black.withAlphaComponent(0.6)
                : UIColor.white.withAlphaComponent(0.6)
            self.checkmarkView.tintColor = isFocused ? .black : .white
        }, completion: nil)
    }
}
