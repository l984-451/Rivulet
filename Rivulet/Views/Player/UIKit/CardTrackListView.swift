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
final class CardTrackListView: UIView, RailPanelMenuHandling {

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
        var title: String
        var subtitle: String?
        var trackId: Int?
        var isSelected: Bool
        var isEnabled = true
        var wrapsSubtitle = false
    }

    private var rows: [Row]
    private let actions: [CardActionConfig]
    private let choices: [CardChoiceConfig]
    private let toggles: [CardToggleConfig]
    private let steppers: [CardStepperConfig]
    private let onSelect: (Int?) -> Void
    private let onBack: (() -> Void)?
    private let header: String
    private let headerLabel = UILabel()
    /// The choice whose options are showing in place of the menu, AVKit's submenu.
    private var openChoice: Int?
    private weak var pendingFocus: UIView?
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var rowButtons: [CardTrackRowButton] = []
    private var actionButtons: [CardTrackRowButton] = []
    /// The rows built from `rows` (tracks and Off), wherever they sit in the menu.
    private var trackButtons: [CardTrackRowButton] = []
    /// Set: the adjustments lead under `header`, the tracks follow under this.
    private let trackHeader: String?
    private var stepperRows: [CardStepperRowView] = []
    /// AVKit's Language submenu: the tracks, one level in from On and Off. Empty: tracks list in place.
    private var languageRows: [Row]
    private var languageValue: String?
    private var showsLanguages = false
    private weak var languageButton: CardTrackRowButton?
    /// Pin focus to the selected row only for the FIRST landing. After focus
    /// has entered the list once, `preferredFocusEnvironments` holds the row
    /// focus is on, so an edge press stops instead of bouncing to the selection.
    private var hasPinnedInitialFocus = false
    /// The control focus is on: a track row or a stepper's -/+ button.
    private weak var lastFocusedControl: UIView?

    /// `audio` titles each row by language with a format line ("TrueHD 7.1 Atmos").
    convenience init(header: String, tracks: [MediaTrack], selectedTrackId: Int?, showsOffRow: Bool,
                     audio: Bool = false, trackHeader: String? = nil,
                     actions: [CardActionConfig] = [], choices: [CardChoiceConfig] = [],
                     toggles: [CardToggleConfig] = [], steppers: [CardStepperConfig] = [],
                     onSelect: @escaping (Int?) -> Void) {
        var rows: [Row] = []
        if showsOffRow {
            rows.append(Row(title: "Off", subtitle: nil, trackId: nil, isSelected: selectedTrackId == nil))
        }
        rows.append(contentsOf: tracks.map { track in
            Row(
                title: audio ? track.audioMenuTitle : track.name,
                subtitle: audio ? track.audioMenuSubtitle : Self.subtitleLine(track),
                trackId: track.id,
                isSelected: track.id == selectedTrackId
            )
        })
        self.init(header: header, rows: rows, actions: actions, choices: choices, toggles: toggles,
                  steppers: steppers, trackHeader: trackHeader, onSelect: onSelect)
    }

    private static func subtitleLine(_ track: MediaTrack) -> String {
        [track.language, track.codec?.uppercased()].compactMap { $0 }.joined(separator: " • ")
    }

    /// AVKit's subtitles menu: On and Off, then Language (the tracks) and Style one level in.
    /// `onTrackId` is what On turns on; nil leaves only Off.
    static func subtitleMenu(tracks: [MediaTrack], selectedTrackId: Int?, onTrackId: Int?,
                             actions: [CardActionConfig] = [], steppers: [CardStepperConfig] = [],
                             onSelect: @escaping (Int?) -> Void) -> CardTrackListView {
        var rows = [Row(title: "Off", subtitle: nil, trackId: nil, isSelected: selectedTrackId == nil)]
        var languageRows: [Row] = []
        if let onTrackId {
            rows.insert(Row(title: "On", subtitle: nil, trackId: onTrackId, isSelected: selectedTrackId != nil), at: 0)
            languageRows = tracks.map {
                Row(title: $0.name, subtitle: subtitleLine($0), trackId: $0.id, isSelected: $0.id == selectedTrackId)
            }
        }
        let value = tracks.first { $0.id == (selectedTrackId ?? onTrackId) }?.name
        return CardTrackListView(header: "Subtitles", rows: rows, actions: actions,
                                 choices: [CardChoiceConfig.captionStyle()].compactMap { $0 },
                                 steppers: steppers, languageRows: languageRows, languageValue: value,
                                 onSelect: onSelect)
    }

    /// The audio menu in the TV app's order: Audio Adjustments, then Audio Track.
    static func audioMenu(tracks: [MediaTrack], selectedTrackId: Int?,
                          onSelect: @escaping (Int?) -> Void) -> CardTrackListView {
        let choices = SystemAudioAdjustment.menuChoices
        let toggles = SystemAudioAdjustment.menuToggles
        let adjusts = !choices.isEmpty || !toggles.isEmpty
        return CardTrackListView(header: adjusts ? "Audio Adjustments" : "Audio Track", tracks: tracks,
                                 selectedTrackId: selectedTrackId, showsOffRow: false, audio: true,
                                 trackHeader: adjusts ? "Audio Track" : nil,
                                 choices: choices, toggles: toggles, onSelect: onSelect)
    }

    /// A plain list of choices: each row's `trackId` is what `onSelect` receives.
    init(header: String, rows: [Row], actions: [CardActionConfig] = [], choices: [CardChoiceConfig] = [],
         toggles: [CardToggleConfig] = [], steppers: [CardStepperConfig] = [],
         trackHeader: String? = nil, languageRows: [Row] = [], languageValue: String? = nil,
         onBack: (() -> Void)? = nil,
         onSelect: @escaping (Int?) -> Void) {
        self.rows = rows
        self.languageRows = languageRows
        self.languageValue = languageValue
        self.trackHeader = trackHeader
        self.actions = actions
        self.choices = choices
        self.toggles = toggles
        self.steppers = steppers
        self.onSelect = onSelect
        self.onBack = onBack
        self.header = header
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
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
            equalTo: stack.heightAnchor, constant: Metrics.focusGrowth + Metrics.bottomInset)
        scrollHeight.priority = .defaultHigh - 1

        NSLayoutConstraint.activate([
            headerLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: Metrics.headerLabelCenterY),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.headerLabelLeading),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.headerLabelLeading),

            // Starts focusGrowth early, with the rows that far down its content, so the
            // top row's focused pill isn't clipped by the scroll view.
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.headerHeight - Metrics.focusGrowth),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollHeight,

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: Metrics.focusGrowth),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: Metrics.rowInset),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -Metrics.rowInset),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -Metrics.bottomInset),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -2 * Metrics.rowInset),
        ])
        buildRows()
    }

    /// Change a track row in place (a download's progress, a pick that keeps the menu open).
    func updateTrack(_ trackId: Int, title: String? = nil, subtitle: String) {
        if languageRows.isEmpty {
            for index in rows.indices where rows[index].trackId == trackId {
                rows[index].subtitle = subtitle
                if let title { rows[index].title = title }
            }
        } else {
            for index in languageRows.indices where languageRows[index].trackId == trackId {
                languageRows[index].subtitle = subtitle
                if let title { languageRows[index].title = title }
            }
        }
        if let button = trackButtons.first(where: { $0.row.trackId == trackId }) {
            if let title { button.setTitle(title) }
            button.setSubtitle(subtitle)
        }
    }

    func refreshActionAvailability() {
        for (config, button) in zip(actions, actionButtons) {
            let enabled = config.isEnabled?() ?? true
            button.isEnabled = enabled
            button.alpha = enabled ? 1 : 0.4
        }
    }

    func checkTrack(_ trackId: Int?) {
        for index in rows.indices {
            if languageRows.isEmpty {
                rows[index].isSelected = rows[index].trackId == trackId
            } else {
                let isOn = rows[index].trackId != nil
                rows[index].isSelected = isOn == (trackId != nil)
                if isOn, let trackId { rows[index].trackId = trackId }
            }
        }
        for index in languageRows.indices {
            languageRows[index].isSelected = languageRows[index].trackId == trackId
        }
        if let selected = languageRows.first(where: { $0.trackId == trackId }) {
            languageValue = selected.title
            languageButton?.setSubtitle(selected.title)
        }
        if !languageRows.isEmpty, !showsLanguages, openChoice == nil {
            for button in rowButtons.prefix(rows.count) {
                button.isChecked = (button.row.trackId != nil) == (trackId != nil)
            }
        } else {
            trackButtons.forEach { $0.isChecked = $0.row.trackId == trackId }
        }
    }

    private func buildRows() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowButtons = []
        trackButtons = []
        actionButtons = []
        stepperRows = []
        hasPinnedInitialFocus = false
        // The rows below are a different length; an offset left over from a long
        // list would sit past the end of a short one and show nothing.
        scrollView.contentOffset = .zero

        if let index = openChoice {
            buildSubmenu(choices[index])
            return
        }
        if showsLanguages {
            headerLabel.text = "Language"
            for row in languageRows { addTrackButton(row) }
            return
        }
        headerLabel.text = header

        // AVKit's subtitles menu: On, Off | Language, Style | actions | steppers.
        if !languageRows.isEmpty {
            buildTracks()
            stack.addArrangedSubview(MenuSeparatorView())
            let language = CardTrackRowButton(row: Row(title: "Language", subtitle: languageValue,
                                                       trackId: nil, isSelected: false),
                                              showsChevron: true)
            language.onTap = { [weak self] in self?.showLanguages(true) }
            stack.addArrangedSubview(language)
            rowButtons.append(language)
            languageButton = language
            buildAdjustments(separated: false)
            buildActions()
            buildSteppers()
            return
        }

        // The TV app's audio menu: adjustments first, then the tracks under their own header.
        if let trackHeader {
            buildAdjustments()
            stack.addArrangedSubview(MenuSeparatorView())
            stack.addArrangedSubview(MenuSectionHeaderView(title: trackHeader))
            buildTracks()
            return
        }
        buildTracks()
        buildActions()
        buildAdjustments()
        buildSteppers()
    }

    /// Actions (Search for Subtitles) get their own section; the handler
    /// decides what happens to the popup.
    private func buildActions() {
        if !actions.isEmpty, !rowButtons.isEmpty {
            stack.addArrangedSubview(MenuSeparatorView())
        }
        for config in actions {
            let button = CardTrackRowButton(
                row: Row(title: config.title, subtitle: config.subtitle, trackId: nil, isSelected: false),
                showsChevron: config.showsChevron)
            button.onTap = { [weak button] in
                guard let button else { return }
                config.run(button)
            }
            stack.addArrangedSubview(button)
            rowButtons.append(button)
            actionButtons.append(button)
            let enabled = config.isEnabled?() ?? true
            button.isEnabled = enabled
            button.alpha = enabled ? 1 : 0.4
        }
    }

    /// Adjustment steppers (delay / height) sit in their own section below a
    /// separator. A press adjusts in place and leaves the popup up, so the
    /// user can watch the subtitles move as they step.
    private func buildSteppers() {
        if !steppers.isEmpty, !rowButtons.isEmpty {
            stack.addArrangedSubview(MenuSeparatorView())
        }
        for config in steppers {
            let row = CardStepperRowView(config: config)
            stack.addArrangedSubview(row)
            stepperRows.append(row)
        }
    }

    /// Choices (Enhance Dialogue levels) open their options in place, like AVKit's
    /// submenu; toggles flip in place and leave the popup up, in one section with them.
    private func buildAdjustments(separated: Bool = true) {
        if separated, !choices.isEmpty, !rowButtons.isEmpty {
            stack.addArrangedSubview(MenuSeparatorView())
        }
        for (index, config) in choices.enumerated() {
            let button = CardTrackRowButton(row: Row(title: config.title,
                                                     subtitle: config.options.indices.contains(config.selected())
                                                         ? config.options[config.selected()] : nil,
                                                     trackId: nil, isSelected: false),
                                            showsChevron: true)
            button.onTap = { [weak self] in self?.showChoice(index) }
            stack.addArrangedSubview(button)
            rowButtons.append(button)
        }

        if !toggles.isEmpty, !rowButtons.isEmpty, choices.isEmpty {
            stack.addArrangedSubview(MenuSeparatorView())
        }
        for config in toggles {
            let button = CardTrackRowButton(row: Row(title: config.title, subtitle: nil, trackId: nil,
                                                     isSelected: config.isOn()))
            button.onTap = { [weak button] in
                guard let button else { return }
                let on = !button.isChecked
                config.onToggle(on)
                button.isChecked = on
            }
            stack.addArrangedSubview(button)
            rowButtons.append(button)
        }
    }

    private func buildTracks() {
        for row in rows { addTrackButton(row) }
    }

    /// A row that hands its `trackId` to `onSelect`. On and Off are not the tracks
    /// `checkTrack` and `updateTrack` address once the tracks sit in Language.
    private func addTrackButton(_ row: Row) {
        let button = CardTrackRowButton(row: row)
        button.isEnabled = row.isEnabled
        button.alpha = row.isEnabled || row.wrapsSubtitle ? 1 : 0.4
        button.onTap = { [weak self] in
            self?.onSelect(row.trackId)
        }
        stack.addArrangedSubview(button)
        rowButtons.append(button)
        if languageRows.isEmpty || showsLanguages { trackButtons.append(button) }
    }

    private func showLanguages(_ show: Bool) {
        showsLanguages = show
        buildRows()
        if !show { pendingFocus = languageButton }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func buildSubmenu(_ config: CardChoiceConfig) {
        headerLabel.text = config.title
        let selected = config.selected()
        for (index, title) in config.options.enumerated() {
            let button = CardTrackRowButton(row: Row(title: title, subtitle: nil, trackId: nil,
                                                     isSelected: index == selected))
            button.onTap = { [weak self] in
                config.onSelect(index)
                self?.showChoice(nil)
            }
            stack.addArrangedSubview(button)
            rowButtons.append(button)
        }
    }

    /// Swaps between the menu and a choice's options; focus lands on the
    /// selected option going in and on the choice's row coming back.
    private func showChoice(_ index: Int?) {
        let returning = openChoice
        openChoice = index
        buildRows()
        if index == nil, let returning {
            pendingFocus = rowButtons.first { $0.showsChevron && $0.row.title == choices[returning].title }
        }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    func handleMenuPress() -> Bool {
        if showsLanguages {
            showLanguages(false)
            return true
        }
        guard openChoice != nil else {
            guard let onBack else { return false }
            onBack()
            return true
        }
        showChoice(nil)
        return true
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let pendingFocus {
            self.pendingFocus = nil
            return [pendingFocus]
        }
        // After the first landing, hold the CURRENT row: when an edge press
        // finds no in-popup candidate the popup's fence re-resolves through
        // here, and returning the focused row makes focus stop at the edge
        // instead of looping to the top.
        if hasPinnedInitialFocus {
            return lastFocusedControl.map { [$0] } ?? []
        }
        if let first = trackButtons.first(where: { $0.isEnabled && $0.row.isSelected })
            ?? rowButtons.first(where: { $0.isEnabled && $0.row.isSelected }) {
            return [first]
        }
        if let firstRow = rowButtons.first(where: \.isEnabled) { return [firstRow] }
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

/// A section title inside a menu, set like the menu's own header (the TV app's "Audio Track").
private final class MenuSectionHeaderView: UIView {
    init(title: String) {
        super.init(frame: .zero)
        let label = UILabel()
        label.text = title
        label.font = CardTrackListView.Metrics.secondaryFont
        label.textColor = CardTrackListView.Metrics.secondaryColor
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: CardTrackListView.Metrics.headerHeight),
            label.centerYAnchor.constraint(equalTo: topAnchor, constant: CardTrackListView.Metrics.headerLabelCenterY),
            label.leadingAnchor.constraint(equalTo: leadingAnchor,
                                           constant: CardTrackListView.Metrics.headerLabelLeading - CardTrackListView.Metrics.rowInset),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - CardChoiceConfig

/// A one-of-N submenu: `selected` and `onSelect` use option indices.
struct CardChoiceConfig {
    let title: String
    let options: [String]
    let selected: () -> Int
    let onSelect: (Int) -> Void
}

extension CardChoiceConfig {
    /// AVKit's Style row: the system caption styles, applied system-wide as Settings does.
    static func captionStyle() -> CardChoiceConfig? {
        let styles = CaptionAppearance.styles()
        guard styles.count > 1 else { return nil }
        return CardChoiceConfig(
            title: "Style",
            options: styles.map(\.name),
            selected: { styles.firstIndex { $0.id == CaptionAppearance.activeStyleID } ?? -1 },
            onSelect: { CaptionAppearance.activeStyleID = styles[$0].id })
    }
}

// MARK: - CardActionConfig

/// A row that runs `run`, which receives the row so it can retitle it.
struct CardActionConfig {
    let title: String
    var subtitle: String? = nil
    var showsChevron = false
    var isEnabled: (() -> Bool)? = nil
    let run: (CardTrackRowButton) -> Void
}

// MARK: - CardToggleConfig

struct CardToggleConfig {
    let title: String
    let isOn: () -> Bool
    let onToggle: (Bool) -> Void
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
    let showsChevron: Bool
    var onTap: (() -> Void)?
    var isChecked: Bool {
        get { !checkmarkView.isHidden }
        set {
            checkmarkView.isHidden = !newValue
            if newValue { accessibilityTraits.insert(.selected) }
            else { accessibilityTraits.remove(.selected) }
        }
    }
    private let pill = UIView()
    private let content = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let checkmarkView = UIImageView(image: UIImage(
        systemName: "checkmark",
        // Matches AVKit's glyph by rendered ink, not by its reported 19x17 size.
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)
    ))

    private let chevronView = UIImageView(image: UIImage(
        systemName: "chevron.forward",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)
    ))

    init(row: CardTrackListView.Row, showsChevron: Bool = false) {
        self.row = row
        self.showsChevron = showsChevron
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
        subtitleLabel.numberOfLines = row.wrapsSubtitle ? 0 : 1
        isAccessibilityElement = true
        accessibilityLabel = row.title
        accessibilityValue = row.subtitle
        accessibilityTraits = row.isSelected ? [.button, .selected] : .button

        checkmarkView.tintColor = .white
        checkmarkView.isHidden = !row.isSelected
        checkmarkView.contentMode = .center

        addSubview(pill)
        addSubview(content)
        [checkmarkView, titleLabel, subtitleLabel].forEach { content.addSubview($0) }
        chevronView.isHidden = !showsChevron
        chevronView.tintColor = M.secondaryColor
        content.addSubview(chevronView)
        chevronView.translatesAutoresizingMaskIntoConstraints = false

        [content, checkmarkView, titleLabel, subtitleLabel].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        var constraints = [
            row.wrapsSubtitle
                ? heightAnchor.constraint(greaterThanOrEqualToConstant: M.twoLineRowHeight)
                : heightAnchor.constraint(equalToConstant: hasSubtitle ? M.twoLineRowHeight : M.rowHeight),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),

            checkmarkView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: M.checkColumnX),
            checkmarkView.widthAnchor.constraint(equalToConstant: M.checkColumnWidth),
            checkmarkView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: M.titleX),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor,
                                                 constant: -M.checkColumnX - (showsChevron ? 34 : 0)),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor,
                                                    constant: -M.checkColumnX - (showsChevron ? 34 : 0)),
            chevronView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -M.checkColumnX),
            chevronView.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ]
        if hasSubtitle {
            constraints += [
                titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 13),
                subtitleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 45),
            ]
            if row.wrapsSubtitle {
                constraints.append(subtitleLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -13))
            }
        } else {
            constraints.append(titleLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        applyFocus(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTitle(_ title: String) {
        titleLabel.text = title
        accessibilityLabel = title
    }

    func setSubtitle(_ subtitle: String) {
        subtitleLabel.text = subtitle
        accessibilityValue = subtitle
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let isFocused = self.isFocused
        pill.frame = isFocused ? bounds.insetBy(dx: -CardTrackListView.Metrics.focusGrowth,
                                                dy: -CardTrackListView.Metrics.focusGrowth) : bounds
        pill.layer.shadowPath = UIBezierPath(roundedRect: pill.bounds, cornerRadius: pill.layer.cornerRadius).cgPath
    }

    override var canBecomeFocused: Bool { isEnabled }

    // Select does not fire .primaryActionTriggered on a plain UIControl
    // on tvOS; handle the press directly.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard isEnabled else { return }
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
        chevronView.tintColor = focused ? UIColor.black.withAlphaComponent(0.6) : M.secondaryColor
    }
}
