// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerRailView.swift
//  Rivulet
//
//  The 3a bottom glass rail: metadata block left, five round transport
//  buttons right. The scrubber (PlayerProgressBarView) is NOT a child —
//  it stays a container sibling overlaid on the rail's lower region so
//  its morph/behavior layer is untouched; this view is the glass plate
//  and the top row only.
//

import UIKit

final class PlayerRailView: UIView {

    static let railHeight: CGFloat = 260

    private enum Metrics {
        static let padV: CGFloat = 34
        static let padH: CGFloat = 42
        static let topRowGap: CGFloat = 32
        static let buttonGap: CGFloat = 20
        static let buttonDiameter: CGFloat = 74
    }

    // No skip-back control — the remote's own scrub gesture owns seeking
    // (same philosophy as the earlier Resume-pill removal).
    let subtitlesButton = TransportControlButton(
        icon: UIImage(systemName: "captions.bubble"), accessibilityLabel: "Subtitles",
        diameter: Metrics.buttonDiameter)
    let audioButton = TransportControlButton(
        icon: UIImage(systemName: "waveform"), accessibilityLabel: "Audio",
        diameter: Metrics.buttonDiameter)
    let infoButton = TransportControlButton(
        icon: UIImage(systemName: "info.circle"), accessibilityLabel: "Info",
        diameter: Metrics.buttonDiameter)
    let insightsButton = TransportControlButton(
        icon: UIImage(systemName: "sparkles"), accessibilityLabel: "Insights",
        diameter: Metrics.buttonDiameter)
    let upNextButton = TransportControlButton(
        icon: UIImage(systemName: "list.and.film"), accessibilityLabel: "Up Next",
        diameter: Metrics.buttonDiameter)
    let filterButton = TransportControlButton(
        icon: UIImage(systemName: "hand.raised"), accessibilityLabel: "Content Filter",
        diameter: Metrics.buttonDiameter)
    /// Live TV only: shown while the viewer is behind the live edge.
    let goLiveButton = TransportControlButton(
        icon: UIImage(systemName: "forward.end.fill"), accessibilityLabel: "Go to Live",
        diameter: Metrics.buttonDiameter)
    /// Live TV only: shown when the channel's source can record.
    let recordButton = TransportControlButton(
        icon: UIImage(systemName: "record.circle"), accessibilityLabel: "Record",
        diameter: Metrics.buttonDiameter)
    /// Live TV only: opens multiview with this channel in it.
    let multiviewButton = TransportControlButton(
        icon: UIImage(systemName: "rectangle.split.2x1"), accessibilityLabel: "Multiview",
        diameter: Metrics.buttonDiameter)

    var onSubtitles: (() -> Void)?
    var onAudio: (() -> Void)?
    var onInfo: (() -> Void)?
    var onInsights: (() -> Void)?
    var onUpNext: (() -> Void)?
    var onFilter: (() -> Void)?
    var onReplayLongPress: (() -> Void)?
    var onGoLive: (() -> Void)?
    var onRecord: (() -> Void)?
    var onMultiview: (() -> Void)?

    private let backgroundEffectView: UIVisualEffectView
    private let tintView = UIView()
    private let eyebrowLabel = UILabel()
    private let titleLabel = UILabel()
    private let metaRow = UIStackView()
    private let ratingChip = UILabel()
    private let runtimeLabel = UILabel()
    private let dividerLabel = UILabel()
    private let audioLabel = UILabel()
    private let cluster = UIStackView()

    init() {
        if #available(tvOS 26.0, *) {
            backgroundEffectView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        } else {
            backgroundEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        }
        super.init(frame: .zero)

        layer.cornerRadius = 32
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.1).cgColor
        // Shadow lives on the unclipped self layer; glass clips itself.
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.6
        layer.shadowRadius = 35
        layer.shadowOffset = CGSize(width: 0, height: 15)

        backgroundEffectView.clipsToBounds = true
        backgroundEffectView.layer.cornerRadius = 32
        backgroundEffectView.layer.cornerCurve = .continuous
        tintView.backgroundColor = UIColor(red: 18/255, green: 20/255, blue: 26/255, alpha: 0.5)
        tintView.clipsToBounds = true
        tintView.layer.cornerRadius = 32
        tintView.layer.cornerCurve = .continuous

        eyebrowLabel.font = .systemFont(ofSize: 23, weight: .medium)
        eyebrowLabel.textColor = UIColor.white.withAlphaComponent(0.66)

        titleLabel.font = .systemFont(ofSize: 38, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1

        ratingChip.font = .systemFont(ofSize: 17, weight: .medium)
        ratingChip.textColor = UIColor.white.withAlphaComponent(0.55)
        ratingChip.layer.borderWidth = 1
        ratingChip.layer.borderColor = UIColor.white.withAlphaComponent(0.28).cgColor
        ratingChip.layer.cornerRadius = 6
        ratingChip.layer.cornerCurve = .continuous
        ratingChip.textAlignment = .center

        for label in [runtimeLabel, dividerLabel, audioLabel] {
            label.font = .systemFont(ofSize: 20, weight: .regular)
            label.textColor = UIColor.white.withAlphaComponent(0.55)
        }
        dividerLabel.text = "·"
        dividerLabel.textColor = UIColor.white.withAlphaComponent(0.4)

        metaRow.axis = .horizontal
        metaRow.spacing = 14
        metaRow.alignment = .center
        [ratingChip, runtimeLabel, dividerLabel, audioLabel].forEach { metaRow.addArrangedSubview($0) }

        cluster.axis = .horizontal
        cluster.spacing = Metrics.buttonGap
        cluster.alignment = .center
        // Multiview and Record (live only, hidden on VOD) lead the row.
        [multiviewButton, recordButton, subtitlesButton, audioButton, infoButton, insightsButton, upNextButton,
         filterButton, goLiveButton].forEach {
            cluster.addArrangedSubview($0)
        }

        [backgroundEffectView, tintView, eyebrowLabel, titleLabel, metaRow, cluster].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            backgroundEffectView.topAnchor.constraint(equalTo: topAnchor),
            backgroundEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            tintView.topAnchor.constraint(equalTo: topAnchor),
            tintView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintView.bottomAnchor.constraint(equalTo: bottomAnchor),

            eyebrowLabel.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.padV),
            eyebrowLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.padH),

            titleLabel.topAnchor.constraint(equalTo: eyebrowLabel.bottomAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: eyebrowLabel.leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: cluster.leadingAnchor, constant: -Metrics.topRowGap),

            metaRow.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            metaRow.leadingAnchor.constraint(equalTo: eyebrowLabel.leadingAnchor),

            ratingChip.widthAnchor.constraint(greaterThanOrEqualToConstant: 58),
            ratingChip.heightAnchor.constraint(equalToConstant: 28),

            cluster.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.padH),
            cluster.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        ])

        subtitlesButton.onPress = { [weak self] in self?.onSubtitles?() }
        subtitlesButton.onLongPress = { [weak self] in self?.onReplayLongPress?() }
        audioButton.onPress = { [weak self] in self?.onAudio?() }
        infoButton.onPress = { [weak self] in self?.onInfo?() }
        insightsButton.onPress = { [weak self] in self?.onInsights?() }
        upNextButton.onPress = { [weak self] in self?.onUpNext?() }
        filterButton.onPress = { [weak self] in self?.onFilter?() }
        goLiveButton.onPress = { [weak self] in self?.onGoLive?() }
        recordButton.onPress = { [weak self] in self?.onRecord?() }
        multiviewButton.onPress = { [weak self] in self?.onMultiview?() }
        insightsButton.isHidden = true
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
        eyebrowLabel.text = eyebrow
        eyebrowLabel.isHidden = eyebrow == nil
    }

    func setMeta(rating: String?, runtime: String?, audio: String?) {
        ratingChip.text = rating
        ratingChip.isHidden = rating == nil
        runtimeLabel.text = runtime
        runtimeLabel.isHidden = runtime == nil
        audioLabel.text = audio
        audioLabel.isHidden = audio == nil
        dividerLabel.isHidden = runtime == nil || audio == nil
    }

    func setLoading(_ loading: Bool) {
        cluster.isHidden = loading
    }

    func setUpNextAvailable(_ available: Bool) {
        upNextButton.isHidden = !available
    }

    /// Uses the Up Next button as the Live TV channel list: same button, place
    /// and `onUpNext` action as VOD's Up Next, with a plain list icon. It is the
    /// rail's default landing, since changing channels is the main thing a
    /// viewer does on live TV.
    func setChannelListAvailable(_ available: Bool) {
        upNextButton.isHidden = !available
        guard available else { return }
        upNextButton.setIcon(UIImage(systemName: "line.3.horizontal"))
        upNextButton.accessibilityLabel = "Channels"
        defaultFocusButton = upNextButton
    }

    func setInsightsAvailable(_ available: Bool) {
        insightsButton.isHidden = !available
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
        // It leads the row, so the chrome opens on it rather than at the far
        // right (Channels).
        if available { defaultFocusButton = multiviewButton }
    }

    // MARK: - Ambient pause

    /// During ambient pause the glass plate, eyebrow, meta, and buttons fade
    /// out, but for a show the episode `titleLabel` stays exactly where the
    /// rail draws it (same place, same 38pt bold) — it does not fade with the
    /// rest. `keepTitle` is false for movies (logo only, nothing kept here).
    /// The container holds the rail's own alpha at 1 while ambient so this
    /// held title can show through.
    ///
    /// `ambientState` lets the container detect a real change (the sub-view
    /// alpha shifts here aren't visible to its own top-level `targets` diff).
    private(set) var ambientState: (ambient: Bool, keepTitle: Bool) = (false, false)

    func setAmbient(_ ambient: Bool, keepTitle: Bool) {
        ambientState = (ambient, keepTitle)
        let plateAlpha: CGFloat = ambient ? 0 : 1
        backgroundEffectView.alpha = plateAlpha
        tintView.alpha = plateAlpha
        eyebrowLabel.alpha = plateAlpha
        metaRow.alpha = plateAlpha
        cluster.alpha = plateAlpha
        // Shadow belongs to the plate; drop it so no glass ghost lingers.
        layer.shadowOpacity = ambient ? 0 : 0.6
        titleLabel.alpha = ambient ? (keepTitle ? 1 : 0) : 1
    }

    // MARK: - Focus

    private weak var lastFocusedButton: UIView?

    /// The scrubber's focus proxy, injected by the container (it is a sibling
    /// of the rail, not a child — see PlayerContainerViewController). Focus
    /// lands here FIRST when the chrome comes up: the timeline is the primary
    /// affordance and the button row sits above it (AVPlayerViewController's
    /// model). Once the user has moved up into the buttons, the last-focused
    /// button wins instead, so re-entering the rail returns them where they
    /// left off rather than yanking focus back down to the scrubber.
    weak var scrubberFocusProxy: UIView?

    /// Button the rail lands on when there's no remembered one and no
    /// scrubber proxy. Defaults to Subtitles (VOD); Live TV points it at the
    /// channel list via `setChannelListAvailable`.
    private weak var defaultFocusButton: TransportControlButton?

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let last = lastFocusedButton, !last.isHidden { return [last] }
        if let proxy = scrubberFocusProxy, proxy.canBecomeFocused { return [proxy] }
        if let preferred = defaultFocusButton, !preferred.isHidden { return [preferred] }
        return [subtitlesButton]
    }

    /// Drop the remembered button so the next chrome appearance starts on the
    /// scrubber again. Called when controls-focus mode ends — "where you left
    /// off" is scoped to one visit to the controls, not to the whole session.
    func resetFocusMemory() {
        lastFocusedButton = nil
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if let next = context.nextFocusedView, next.isDescendant(of: self), next is UIControl {
            lastFocusedButton = next
        }
    }
}
