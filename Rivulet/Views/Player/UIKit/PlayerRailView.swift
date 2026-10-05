// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerRailView.swift
//  Rivulet
//
//  The player's control overlay, laid out like AVPlayerViewController on tvOS
//  26 (measured with DEBUG `AVKitScrubProbe`, RIVULET_SCRUBPROBE=chrome): no
//  plate, the title block bottom-left, round glass tool buttons right-aligned
//  beside it, and the info pills (Info, Insights, Up Next) in a row below the
//  scrub bar. Spans the screen's bottom `railHeight` points edge to edge. The
//  scrub bar (`PlayerProgressBarView`) is a host-owned sibling placed with
//  `barTop`.
//

import UIKit

final class PlayerRailView: UIView {

    /// Covers y 740...1080 at 1080p, the band AVKit's controls use.
    static let railHeight: CGFloat = 340
    /// Where hosts put the scrub bar's top, from this view's top (track center at 1080p y910).
    static let barTop: CGFloat = 160
    /// Inset of the scrub bar and the pill row from the screen edges.
    static let sideInset: CGFloat = 80

    private enum Metrics {
        static let titleLeading: CGFloat = 84
        static let subtitleTop: CGFloat = 18
        static let titleTop: CGFloat = 62
        static let toolTop: CGFloat = 56
        static let toolDiameter: CGFloat = 70
        static let toolGap: CGFloat = 24
        static let pillsTop: CGFloat = 230
        static let pillGap: CGFloat = 24
        static let subTabGap: CGFloat = 16
        static let titleToolGap: CGFloat = 32
    }

    let subtitlesButton = TransportControlButton(
        icon: UIImage(systemName: "captions.bubble"), accessibilityLabel: "Subtitles",
        diameter: Metrics.toolDiameter)
    let audioButton = TransportControlButton(
        icon: UIImage(systemName: "waveform"), accessibilityLabel: "Audio",
        diameter: Metrics.toolDiameter)
    let filterButton = TransportControlButton(
        icon: UIImage(systemName: "hand.raised"), accessibilityLabel: "Content Filter",
        diameter: Metrics.toolDiameter)
    /// Live TV only: shown while the viewer is behind the live edge.
    let goLiveButton = TransportControlButton(
        icon: UIImage(systemName: "forward.end.fill"), accessibilityLabel: "Go to Live",
        diameter: Metrics.toolDiameter)
    /// Live TV only: shown when the channel's source can record.
    let recordButton = TransportControlButton(
        icon: UIImage(systemName: "record.circle"), accessibilityLabel: "Record",
        diameter: Metrics.toolDiameter)
    /// Live TV only: opens multiview with this channel in it.
    let multiviewButton = TransportControlButton(
        icon: UIImage(systemName: "rectangle.split.2x1"), accessibilityLabel: "Multiview",
        diameter: Metrics.toolDiameter)

    // Info pills below the scrub bar, AVKit's place for info tabs: Info and
    // Chapters as in AVKit, then Rivulet's own tabs. Insights goes last so
    // its sub-tabs, right of it, are reached without crossing another pill.
    let infoButton = PlayerInfoPillButton(title: "Info")
    let chaptersButton = PlayerInfoPillButton(title: "Chapters")
    /// "Up Next" on VOD, "Channels" on Live TV.
    let upNextButton = PlayerInfoPillButton(title: "Up Next")
    let insightsButton = PlayerInfoPillButton(title: "Insights")
    /// Technical media info and live playback stats.
    let detailsButton = PlayerInfoPillButton(title: "Details")

    var onSubtitles: (() -> Void)?
    var onAudio: (() -> Void)?
    var onInfo: (() -> Void)?
    var onChapters: (() -> Void)?
    var onDetails: (() -> Void)?
    /// A pill gained focus. While a pane is open this switches its tab, as AVKit's do.
    var onPillFocused: ((PlayerInfoPillButton) -> Void)?
    var onInsights: (() -> Void)?
    var onUpNext: (() -> Void)?
    var onFilter: (() -> Void)?
    var onReplayLongPress: (() -> Void)?
    var onGoLive: (() -> Void)?
    var onRecord: (() -> Void)?
    var onMultiview: (() -> Void)?

    private let subtitleLabel = UILabel()
    private let titleLabel = UILabel()
    private let toolRow = UIStackView()
    private let pillRow = UIStackView()
    /// Insights' sub-tabs, right-aligned on the pill row while its pane is open.
    private let insightsTabRow = UIStackView()
    private var onInsightsTabFocused: ((Int) -> Void)?
    /// Down from the bar lands on the first pill, not the nearest one.
    private let pillEntryGuide = UIFocusGuide()

    init() {
        super.init(frame: .zero)

        // AVKit's title block: a 25pt medium line over a 57pt bold title, each
        // with a soft wide shadow.
        subtitleLabel.font = .systemFont(ofSize: 25, weight: .medium)
        subtitleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 57, weight: .bold)
        titleLabel.textColor = .white
        for label in [subtitleLabel, titleLabel] {
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.2
            label.layer.shadowRadius = 30
            label.layer.shadowOffset = .zero
        }

        // Custom tools sit left of Subtitles/Audio, as AVKit places them.
        toolRow.axis = .horizontal
        toolRow.spacing = Metrics.toolGap
        toolRow.alignment = .center
        [multiviewButton, recordButton, goLiveButton, filterButton, subtitlesButton, audioButton].forEach {
            toolRow.addArrangedSubview($0)
        }

        pillRow.axis = .horizontal
        pillRow.spacing = Metrics.pillGap
        pillRow.alignment = .center
        [infoButton, chaptersButton, upNextButton, detailsButton, insightsButton].forEach {
            pillRow.addArrangedSubview($0)
        }
        insightsTabRow.axis = .horizontal
        insightsTabRow.spacing = Metrics.subTabGap
        insightsTabRow.alignment = .center
        insightsTabRow.isHidden = true

        [subtitleLabel, titleLabel, toolRow, pillRow, insightsTabRow].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            subtitleLabel.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.subtitleTop),
            subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.titleLeading),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: toolRow.leadingAnchor, constant: -Metrics.titleToolGap),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.titleTop),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.titleLeading),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: toolRow.leadingAnchor, constant: -Metrics.titleToolGap),

            toolRow.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.toolTop),
            toolRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.sideInset),

            pillRow.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.pillsTop),
            pillRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.sideInset),

            insightsTabRow.centerYAnchor.constraint(equalTo: pillRow.centerYAnchor),
            insightsTabRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.sideInset),
            insightsTabRow.leadingAnchor.constraint(greaterThanOrEqualTo: pillRow.trailingAnchor, constant: Metrics.pillGap),
        ])

        subtitlesButton.onPress = { [weak self] in self?.onSubtitles?() }
        subtitlesButton.onLongPress = { [weak self] in self?.onReplayLongPress?() }
        audioButton.onPress = { [weak self] in self?.onAudio?() }
        infoButton.onPress = { [weak self] in self?.onInfo?() }
        chaptersButton.onPress = { [weak self] in self?.onChapters?() }
        detailsButton.onPress = { [weak self] in self?.onDetails?() }
        insightsButton.onPress = { [weak self] in self?.onInsights?() }
        upNextButton.onPress = { [weak self] in self?.onUpNext?() }
        filterButton.onPress = { [weak self] in self?.onFilter?() }
        goLiveButton.onPress = { [weak self] in self?.onGoLive?() }
        recordButton.onPress = { [weak self] in self?.onRecord?() }
        multiviewButton.onPress = { [weak self] in self?.onMultiview?() }
        insightsButton.isHidden = true
        upNextButton.isHidden = true
        chaptersButton.isHidden = true
        detailsButton.isHidden = true
        // Hidden until a host shows it — the Live TV rail shares this view but
        // has no content filter.
        filterButton.isHidden = true
        // Live TV only, and only in the states that give them meaning.
        goLiveButton.isHidden = true
        recordButton.isHidden = true
        multiviewButton.isHidden = true
    }

    /// Show the content filter toggle (VOD, filtering on in Settings).
    func setFilterAvailable(_ available: Bool) {
        filterButton.isHidden = !available
    }

    /// Reflect whether the content filter is acting in the toggle glyph
    /// (filled = filtering, outline = paused for this title).
    func setFilterActive(_ active: Bool) {
        filterButton.setIcon(UIImage(systemName: active ? "hand.raised.fill" : "hand.raised"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Content

    func setTitle(_ title: String, eyebrow: String?) {
        titleLabel.text = title
        subtitleLabel.text = eyebrow
        subtitleLabel.isHidden = eyebrow == nil
    }

    func setLoading(_ loading: Bool) {
        toolRow.isHidden = loading
        pillRow.isHidden = loading
    }

    func setUpNextAvailable(_ available: Bool) {
        upNextButton.isHidden = !available
    }

    /// Uses the Up Next pill as the Live TV channel list: same pill, place and
    /// `onUpNext` action, titled Channels. It is the rail's default landing,
    /// since changing channels is the main thing a viewer does on live TV.
    func setChannelListAvailable(_ available: Bool) {
        upNextButton.isHidden = !available
        guard available else { return }
        upNextButton.setTitle("Channels")
        defaultFocusButton = upNextButton
    }

    func setInsightsAvailable(_ available: Bool) {
        insightsButton.isHidden = !available
    }

    func setChaptersAvailable(_ available: Bool) {
        chaptersButton.isHidden = !available
    }

    func setDetailsAvailable(_ available: Bool) {
        detailsButton.isHidden = !available
    }

    // MARK: - Info pane

    /// AVKit's info pane: the whole control block rises by `lift` on `motion`
    /// while the title and tool buttons fade out; nil puts it back. Timings
    /// measured from AVKit.
    func setPaneLift(_ lift: CGFloat?, motion: UIViewPropertyAnimator) {
        isPaneOpen = lift != nil
        updatePillEntryGuide(focusInPills: false)
        // The whole rail moves, as AVKit's full-screen container does: rows
        // shifted outside the rail's own frame drop out of sideways focus search.
        let rise = CGAffineTransform(translationX: 0, y: -(lift ?? 0))
        motion.addAnimations { self.transform = rise }
        let fadeCurve = UICubicTimingParameters(controlPoint1: CGPoint(x: 0.33, y: 0), controlPoint2: CGPoint(x: 0.83, y: 0.83))
        let fader = UIViewPropertyAnimator(duration: 0.167, timingParameters: fadeCurve)
        fader.addAnimations { self.applyAlphas() }
        fader.startAnimation()
    }

    /// Pills a pane can switch between, for the pane's focus fence.
    var pillRowView: UIView { pillRow }

    /// The pill row's top at rest, in this view's coordinates (the lift aside).
    var pillRowRestingTop: CGFloat {
        layoutIfNeeded()
        return pillRow.center.y - pillRow.bounds.height / 2
    }

    /// Shows Insights' sub-tabs (empty hides them); `onFocus` gets the index
    /// of a sub-tab that gains focus, which also becomes the selected one.
    func setInsightsTabs(_ titles: [String], selected: Int, onFocus: ((Int) -> Void)?) {
        insightsTabRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        onInsightsTabFocused = onFocus
        for (index, title) in titles.enumerated() {
            let tab = PlayerInfoPillButton(title: title, compact: true)
            tab.isSelectedTab = index == selected
            insightsTabRow.addArrangedSubview(tab)
        }
        insightsTabRow.isHidden = titles.isEmpty
    }

    func insightsTab(at index: Int) -> UIView? {
        insightsTabRow.arrangedSubviews.indices.contains(index) ? insightsTabRow.arrangedSubviews[index] : nil
    }

    /// The open pane's pill keeps a selected look while focus is in the pane.
    func setSelectedPill(_ selected: PlayerInfoPillButton?) {
        for case let pill as PlayerInfoPillButton in pillRow.arrangedSubviews {
            pill.isSelectedTab = pill === selected
        }
    }

    /// Live TV: offer "Go to Live" only while the viewer is behind the edge.
    /// A hidden button that held focus hands it back to the channel list.
    func setGoLiveAvailable(_ available: Bool) {
        guard goLiveButton.isHidden == available else { return }
        goLiveButton.isHidden = !available
        if !available, lastFocusedButton === goLiveButton { lastFocusedButton = nil }
    }

    /// Live TV: the record button, filled while the current programme is set
    /// to record.
    func setRecordState(available: Bool, isRecording: Bool) {
        recordButton.isHidden = !available
        recordButton.setIcon(UIImage(systemName: isRecording ? "record.circle.fill" : "record.circle"))
        recordButton.accessibilityLabel = isRecording ? "Recording" : "Record"
        recordButton.glyphColor = isRecording ? .systemRed : nil
    }

    /// Live TV: multiview, where the host has one to open.
    func setMultiviewAvailable(_ available: Bool) {
        multiviewButton.isHidden = !available
        // It leads the tool row, so the chrome opens on it.
        if available { defaultFocusButton = multiviewButton }
    }

    // MARK: - Ambient pause

    /// During ambient pause the controls fade out, but for a show the episode
    /// `titleLabel` stays exactly where it is (same place, same size). The
    /// container holds the rail's own alpha at 1 while ambient so this held
    /// title can show through. `keepTitle` is false for movies (logo only).
    ///
    /// `ambientState` lets the container detect a real change (the sub-view
    /// alpha shifts here aren't visible to its own top-level `targets` diff).
    private(set) var ambientState: (ambient: Bool, keepTitle: Bool) = (false, false)

    func setAmbient(_ ambient: Bool, keepTitle: Bool) {
        ambientState = (ambient, keepTitle)
        applyAlphas()
    }

    private var isPaneOpen = false

    /// One writer for the sub-view alphas ambient pause and the info pane share.
    private func applyAlphas() {
        let ambient = ambientState.ambient
        let chrome: CGFloat = ambient || isPaneOpen ? 0 : 1
        subtitleLabel.alpha = chrome
        toolRow.alpha = chrome
        pillRow.alpha = ambient ? 0 : 1
        titleLabel.alpha = ambient ? (ambientState.keepTitle ? 1 : 0) : chrome
    }

    // MARK: - Focus

    private weak var lastFocusedButton: UIView?

    /// The scrubber's focus proxy, injected by the container (it is a sibling
    /// of the rail, not a child — see PlayerContainerViewController). Focus
    /// lands here FIRST when the chrome comes up: the timeline is the primary
    /// affordance, as in AVPlayerViewController. Once the user has moved to a
    /// button, the last-focused button wins instead, so re-entering the rail
    /// returns them where they left off.
    weak var scrubberFocusProxy: UIView?

    /// Button the rail lands on when there's no remembered one and no
    /// scrubber proxy. Defaults to Subtitles (VOD); Live TV points it at the
    /// channel list via `setChannelListAvailable`.
    private weak var defaultFocusButton: UIControl?

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let last = lastFocusedButton, !last.isHidden, last.window != nil { return [last] }
        if let proxy = scrubberFocusProxy, proxy.canBecomeFocused { return [proxy] }
        if let preferred = defaultFocusButton, !preferred.isHidden { return [preferred] }
        return [subtitlesButton]
    }

    /// Makes `button` the rail's next focus landing.
    func setFocusLanding(_ button: UIView) { lastFocusedButton = button }

    /// The leftmost tool button on screen, where AVKit lands Up from the video.
    var firstToolButton: UIView? { toolRow.arrangedSubviews.first { !$0.isHidden } }

    /// Drop the remembered button so the next chrome appearance starts on the
    /// scrubber again. Called when controls-focus mode ends — "where you left
    /// off" is scoped to one visit to the controls, not to the whole session.
    func resetFocusMemory() {
        lastFocusedButton = nil
    }

    /// Puts the pill entry guide in the gap between the scrub bar and the pills.
    /// It belongs to the bar: the bar sits above the rail, and the focus engine
    /// skips a guide that a view above it covers.
    func installPillEntryGuide(on bar: UIView) {
        bar.addLayoutGuide(pillEntryGuide)
        NSLayoutConstraint.activate([
            pillEntryGuide.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            pillEntryGuide.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            pillEntryGuide.bottomAnchor.constraint(equalTo: pillRow.topAnchor),
            pillEntryGuide.heightAnchor.constraint(equalToConstant: 8),
        ])
        updatePillEntryGuide(focusInPills: false)
    }

    /// Live only while focus is outside the pills (Up from a pill must reach
    /// the bar) and no pane has lifted them away from the strip.
    private func updatePillEntryGuide(focusInPills: Bool) {
        let first = pillRow.arrangedSubviews.first { !$0.isHidden }
        pillEntryGuide.preferredFocusEnvironments = first.map { [$0] } ?? []
        pillEntryGuide.isEnabled = !focusInPills && !isPaneOpen && first != nil
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if let next = context.nextFocusedView {
            updatePillEntryGuide(focusInPills: next.isDescendant(of: pillRow))
        }
        if let next = context.nextFocusedView, next.isDescendant(of: self), next is UIControl {
            lastFocusedButton = next
        }
        if let pill = context.nextFocusedView as? PlayerInfoPillButton {
            if pill.isDescendant(of: pillRow) {
                onPillFocused?(pill)
            } else if let index = insightsTabRow.arrangedSubviews.firstIndex(of: pill) {
                for case let (i, tab as PlayerInfoPillButton) in insightsTabRow.arrangedSubviews.enumerated() {
                    tab.isSelectedTab = i == index
                }
                onInsightsTabFocused?(index)
            }
        }
    }
}

// MARK: - PlayerInfoPillButton

/// AVKit's info pill (`AVInfoMenuCell`): a 64pt glass capsule with a 29pt
/// medium label padded 30pt each side. Focused, a white capsule grows 4pt past
/// it with AVKit's lift shadow and the label turns black.
final class PlayerInfoPillButton: UIControl {

    private enum Metrics {
        static let focusGrowth: CGFloat = 4
    }
    private let height: CGFloat

    var onPress: (() -> Void)?
    /// The tab an open pane shows: lit while focus is elsewhere in the pane.
    var isSelectedTab = false {
        didSet { if !isFocused { applyAppearance(focused: false) } }
    }
    private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .clear))
    private let highlight = UIView()
    private let label = UILabel()

    /// `compact` is the smaller pill Insights' sub-tabs use, so they read as a second level.
    init(title: String, compact: Bool = false) {
        height = compact ? 52 : 64
        let padding: CGFloat = compact ? 24 : 30
        super.init(frame: .zero)
        accessibilityLabel = title
        isAccessibilityElement = true

        // The tool buttons' glass, so the whole control row reads as one material.
        glass.isUserInteractionEnabled = false
        glass.clipsToBounds = true
        glass.layer.cornerRadius = height / 2
        glass.backgroundColor = TransportControlButton.restingWash

        highlight.backgroundColor = .white
        highlight.isUserInteractionEnabled = false
        highlight.alpha = 0
        highlight.layer.shadowColor = UIColor.black.cgColor
        highlight.layer.shadowOpacity = 0.3
        highlight.layer.shadowRadius = 15
        highlight.layer.shadowOffset = CGSize(width: 0, height: 20)

        label.text = title
        label.font = .systemFont(ofSize: compact ? 25 : 29, weight: .medium)
        label.textColor = .white

        [glass, highlight, label].forEach {
            addSubview($0)
        }
        [glass, label].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTitle(_ title: String) {
        label.text = title
        accessibilityLabel = title
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutHighlight()
    }

    private func layoutHighlight() {
        let frame = bounds.insetBy(dx: -Metrics.focusGrowth, dy: -Metrics.focusGrowth)
        highlight.frame = frame
        highlight.layer.cornerRadius = frame.height / 2
        highlight.layer.shadowPath = UIBezierPath(roundedRect: highlight.bounds, cornerRadius: frame.height / 2).cgPath
    }

    override var canBecomeFocused: Bool { true }

    // Select does not fire .primaryActionTriggered on a plain UIControl on tvOS.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .select {
            onPress?()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.animateFocusChange(gained: focused) {
            self.applyAppearance(focused: focused)
        }
    }

    private func applyAppearance(focused: Bool) {
        // Selected but unfocused, AVKit lifts the pill to about a 35% white wash.
        highlight.alpha = focused ? 1 : (isSelectedTab ? 0.35 : 0)
        highlight.layer.shadowOpacity = focused ? 0.3 : 0
        label.textColor = focused ? .black : .white
        label.transform = focused
            ? CGAffineTransform(scaleX: (bounds.width + 2 * Metrics.focusGrowth) / max(bounds.width, 1),
                                y: (bounds.height + 2 * Metrics.focusGrowth) / max(bounds.height, 1))
            : .identity
    }
}
