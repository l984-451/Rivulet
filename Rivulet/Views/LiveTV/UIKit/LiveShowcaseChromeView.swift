// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveShowcaseChromeView.swift
//  Rivulet
//
//  The live player's chrome in the Browse layout, modelled on how the Apple
//  TV app presents a live event: no glass plate, just a scrim rising from the
//  bottom edge; a LIVE pill with the air time and channel; the title large;
//  round controls on the right; the programme timeline across the width; and
//  a row of tabs underneath (Info, Channels, Multiview).
//
//  The player owns everything behind the look: playback, transport, panels,
//  and the timeline itself, which it lays into `timelineGuide`.
//

import UIKit

final class LiveShowcaseChromeView: UIView, LivePlayerChrome {

    static let height: CGFloat = 470

    // MARK: LivePlayerChrome callbacks

    var onSubtitles: (() -> Void)?
    var onAudio: (() -> Void)?
    var onInfo: (() -> Void)?
    var onUpNext: (() -> Void)?
    var onGoLive: (() -> Void)?
    var onRecord: (() -> Void)?
    /// Showcase only: open multiview with this channel in it.
    var onMultiview: (() -> Void)?

    /// Where the player lays the programme timeline.
    let timelineGuide = UILayoutGuide()

    private enum Metrics {
        static let side: CGFloat = 90
        static let bottom: CGFloat = 56
        static let buttonDiameter: CGFloat = 62
    }

    private let scrim = CAGradientLayer()
    private let livePill = LivePillView()
    private let metaLabel = UILabel()
    private let titleLabel = UILabel()
    private let buttonStack = UIStackView()
    private let tabStack = UIStackView()

    private let multiviewButton = TransportControlButton(
        icon: UIImage(systemName: "rectangle.split.2x1"), accessibilityLabel: "Multiview",
        diameter: Metrics.buttonDiameter)
    private let subtitlesButton = TransportControlButton(
        icon: UIImage(systemName: "captions.bubble"), accessibilityLabel: "Subtitles",
        diameter: Metrics.buttonDiameter)
    private let audioButton = TransportControlButton(
        icon: UIImage(systemName: "waveform"), accessibilityLabel: "Audio",
        diameter: Metrics.buttonDiameter)
    private let recordButton = TransportControlButton(
        icon: UIImage(systemName: "record.circle"), accessibilityLabel: "Record",
        diameter: Metrics.buttonDiameter)
    private let goLiveButton = TransportControlButton(
        icon: UIImage(systemName: "forward.end.fill"), accessibilityLabel: "Go to Live",
        diameter: Metrics.buttonDiameter)

    private lazy var infoTab = LiveShowcaseTabButton(title: "Info") { [weak self] in self?.onInfo?() }
    private lazy var channelsTab = LiveShowcaseTabButton(title: "Channels") { [weak self] in self?.onUpNext?() }
    private lazy var multiviewTab = LiveShowcaseTabButton(title: "Multiview") { [weak self] in self?.onMultiview?() }

    /// Down from the round controls lands on the tabs; up from the tabs lands
    /// on the controls. The two rows sit at opposite ends of the width, so the
    /// focus engine needs a guide in each direction.
    private let downToTabsGuide = UIFocusGuide()
    private let upToButtonsGuide = UIFocusGuide()

    private weak var lastFocused: UIView?

    // MARK: Init

    override init(frame: CGRect) {
        super.init(frame: frame)

        scrim.colors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(0.55).cgColor,
            UIColor.black.withAlphaComponent(0.8).cgColor,
        ]
        scrim.locations = [0, 0.45, 1]
        layer.addSublayer(scrim)

        metaLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        metaLabel.textColor = UIColor.white.withAlphaComponent(0.8)

        titleLabel.font = .systemFont(ofSize: 50, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail

        buttonStack.axis = .horizontal
        buttonStack.alignment = .center
        buttonStack.spacing = 18
        [multiviewButton, subtitlesButton, audioButton, recordButton, goLiveButton].forEach {
            buttonStack.addArrangedSubview($0)
        }
        recordButton.isHidden = true
        goLiveButton.isHidden = true

        tabStack.axis = .horizontal
        tabStack.alignment = .center
        tabStack.spacing = 16
        [infoTab, channelsTab, multiviewTab].forEach { tabStack.addArrangedSubview($0) }

        let liveRow = UIStackView(arrangedSubviews: [livePill, metaLabel])
        liveRow.axis = .horizontal
        liveRow.alignment = .center
        liveRow.spacing = 14

        [liveRow, titleLabel, buttonStack, tabStack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        addLayoutGuide(timelineGuide)
        addLayoutGuide(downToTabsGuide)
        addLayoutGuide(upToButtonsGuide)

        NSLayoutConstraint.activate([
            tabStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.side),
            tabStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.bottom),

            timelineGuide.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.side),
            timelineGuide.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.side),
            timelineGuide.bottomAnchor.constraint(equalTo: tabStack.topAnchor, constant: -26),
            timelineGuide.heightAnchor.constraint(equalToConstant: 50),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.side),
            titleLabel.bottomAnchor.constraint(equalTo: timelineGuide.topAnchor, constant: -22),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: -40),

            liveRow.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            liveRow.bottomAnchor.constraint(equalTo: titleLabel.topAnchor, constant: -8),
            liveRow.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: -40),

            buttonStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.side),
            buttonStack.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            // Right half, between the controls and the timeline: catches Down
            // from a control.
            downToTabsGuide.leadingAnchor.constraint(equalTo: centerXAnchor),
            downToTabsGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
            downToTabsGuide.topAnchor.constraint(equalTo: buttonStack.bottomAnchor, constant: 4),
            downToTabsGuide.bottomAnchor.constraint(equalTo: timelineGuide.bottomAnchor),

            // Left half, between the timeline and the tabs: catches Up from a
            // tab.
            upToButtonsGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            upToButtonsGuide.trailingAnchor.constraint(equalTo: centerXAnchor),
            upToButtonsGuide.topAnchor.constraint(equalTo: timelineGuide.topAnchor),
            upToButtonsGuide.bottomAnchor.constraint(equalTo: tabStack.topAnchor, constant: -4),
        ])
        downToTabsGuide.preferredFocusEnvironments = [channelsTab]
        upToButtonsGuide.preferredFocusEnvironments = [multiviewButton]

        multiviewButton.onPress = { [weak self] in self?.onMultiview?() }
        subtitlesButton.onPress = { [weak self] in self?.onSubtitles?() }
        audioButton.onPress = { [weak self] in self?.onAudio?() }
        recordButton.onPress = { [weak self] in self?.onRecord?() }
        goLiveButton.onPress = { [weak self] in self?.onGoLive?() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrim.frame = bounds
        CATransaction.commit()
    }

    // MARK: Focus

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let lastFocused, !lastFocused.isHidden { return [lastFocused] }
        // Changing channel is what a viewer most often opens the chrome for.
        return [channelsTab]
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard let next = context.nextFocusedView, next.isDescendant(of: self) else { return }
        lastFocused = next
        // Aim each guide at the control focus left from, so crossing rows and
        // coming back lands where the viewer was.
        if next.isDescendant(of: tabStack) {
            downToTabsGuide.preferredFocusEnvironments = [next]
        } else if next.isDescendant(of: buttonStack) {
            upToButtonsGuide.preferredFocusEnvironments = [next]
        }
    }

    // MARK: LivePlayerChrome

    func setTitle(_ title: String, eyebrow: String?) {
        titleLabel.text = title
        channelLine = eyebrow
        refreshMeta()
    }

    func setMeta(rating: String?, runtime: String?, audio: String?) {
        // The LIVE pill carries what the rail's rating chip says.
        self.runtime = runtime
        refreshMeta()
    }

    func setGoLiveAvailable(_ available: Bool) {
        guard goLiveButton.isHidden == available else { return }
        goLiveButton.isHidden = !available
        if !available, lastFocused === goLiveButton { lastFocused = nil }
    }

    func setRecordState(available: Bool, isRecording: Bool) {
        recordButton.isHidden = !available
        recordButton.setIcon(UIImage(systemName: isRecording ? "record.circle.fill" : "record.circle"))
        recordButton.accessibilityLabel = isRecording ? "Recording" : "Record"
        if !available, lastFocused === recordButton { lastFocused = nil }
    }

    func setTimeshift(behindLiveSeconds: Double, hasRewindWindow: Bool, isPaused: Bool) {
        livePill.update(behindLiveSeconds: behindLiveSeconds, hasRewindWindow: hasRewindWindow, isPaused: isPaused)
    }

    func resetFocusMemory() {
        lastFocused = nil
    }

    /// Panels rise above the round controls, inset like them.
    var panelAnchor: UIView { buttonStack }

    /// Multiview needs room for another stream; hidden when that is not the case.
    func setMultiviewAvailable(_ available: Bool) {
        multiviewButton.isHidden = !available
        multiviewTab.isHidden = !available
        if !available, lastFocused === multiviewButton || lastFocused === multiviewTab { lastFocused = nil }
    }

    // MARK: Meta line

    private var runtime: String?
    private var channelLine: String?

    private func refreshMeta() {
        metaLabel.text = [runtime, channelLine]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

// MARK: - LIVE pill

/// Red "LIVE" at the edge, a grey "−2:15" behind it, "Paused" while paused.
final class LivePillView: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 20, weight: .bold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 34),
        ])
        update(behindLiveSeconds: 0, hasRewindWindow: false, isPaused: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(behindLiveSeconds: Double, hasRewindWindow: Bool, isPaused: Bool) {
        let isLive = !hasRewindWindow || behindLiveSeconds < LiveTimeshiftBadgeView.liveToleranceSeconds
        if isPaused {
            label.text = "PAUSED"
            backgroundColor = UIColor.white.withAlphaComponent(0.25)
        } else if isLive {
            label.text = "LIVE"
            backgroundColor = UIColor.systemRed
        } else {
            let total = max(0, Int(behindLiveSeconds.rounded()))
            label.text = total >= 3600
                ? String(format: "−%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
                : String(format: "−%d:%02d", total / 60, total % 60)
            backgroundColor = UIColor.white.withAlphaComponent(0.25)
        }
    }
}

// MARK: - Tab pill

/// A pill-shaped tab under the timeline: translucent at rest, white with dark
/// text when focused.
final class LiveShowcaseTabButton: UIView {
    private let label = UILabel()
    private let action: () -> Void

    override var canBecomeFocused: Bool { true }

    init(title: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        layer.cornerRadius = 26
        layer.cornerCurve = .continuous
        label.text = title
        label.font = .systemFont(ofSize: 24, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 52),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        let tap = UITapGestureRecognizer(target: self, action: #selector(pressed))
        tap.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        addGestureRecognizer(tap)
        apply(focused: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func pressed() { action() }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations { self.apply(focused: focused) }
    }

    private func apply(focused: Bool) {
        backgroundColor = focused ? .white : UIColor.white.withAlphaComponent(0.16)
        label.textColor = focused ? UIColor(white: 0.08, alpha: 1) : .white
        transform = focused ? CGAffineTransform(scaleX: 1.04, y: 1.04) : .identity
    }
}
