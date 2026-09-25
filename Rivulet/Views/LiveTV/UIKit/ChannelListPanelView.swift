// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ChannelListPanelView.swift
//  Rivulet
//
//  Channel list content for the Live TV rail panel — the live counterpart of
//  UpNextListView (Views/Player/UIKit/PlayerUpNextPanelView.swift), which
//  lists a season's episodes on the VOD OSD.
//
//  Deliberately the same shape as that panel: same panel width, row height,
//  16:9 thumbnail, corner radii, focus scale, accent bar on the current row,
//  and the same open-scrolled-to-the-current-row behavior. Only the CONTENT
//  differs — channel number + name and the current programme, rather than
//  episode number + title and a watched state. Two files rather than one
//  generic list because the row data, artwork source, and image lifetimes
//  have nothing in common; the visual contract is held by matching the
//  metrics below to UpNextRowButton's.
//
//  Pure list content: no glass chrome, no width. The presenter
//  (PlayerRailPanelView via LiveTVAetherPlayerViewController.presentPanel)
//  owns those. A fresh instance is built per presentation.
//

import UIKit

final class ChannelListPanelView: UIView {

    private enum Metrics {
        /// Matches UpNextListView.
        static let maxHeight: CGFloat = 520
        static let rowInset: CGFloat = 8
    }

    private let onSelect: (UnifiedChannel) -> Void
    private let headerLabel = UILabel()
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var rows: [ChannelRowButton] = []
    /// Pin focus to the current channel for the FIRST landing only; see the
    /// matching flag and rationale in UpNextListView / CardTrackListView.
    private var hasPinnedInitialFocus = false
    private weak var lastFocusedRow: ChannelRowButton?

    /// - Parameters:
    ///   - channels: the full channel list, in guide order.
    ///   - currentChannelId: the channel playing now — gets the accent bar and
    ///     is the row the panel opens on.
    ///   - programProvider: current programme per channel, read at build time
    ///     from LiveTVDataStore so this view stays free of store lookups.
    /// `programProvider` is `@MainActor` because its only real implementation
    /// reads `LiveTVDataStore` (a MainActor singleton); it is called
    /// synchronously during init, which is already MainActor-bound.
    init(channels: [UnifiedChannel],
         currentChannelId: String?,
         programProvider: @MainActor (UnifiedChannel) -> UnifiedProgram?,
         onSelect: @escaping (UnifiedChannel) -> Void) {
        self.onSelect = onSelect
        super.init(frame: .zero)
        setupContent()
        buildRows(channels: channels, currentChannelId: currentChannelId, programProvider: programProvider)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupContent() {
        stack.axis = .vertical
        stack.spacing = 8
        scrollView.addSubview(stack)
        scrollView.clipsToBounds = true

        [headerLabel, scrollView, stack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(headerLabel)
        addSubview(scrollView)

        // Grows with content up to a cap: a short line-up hugs its rows, a
        // long one scrolls. Same construction as UpNextListView.
        let scrollHeight = scrollView.heightAnchor.constraint(equalTo: stack.heightAnchor)
        scrollHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: topAnchor),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.rowInset),
            headerLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.rowInset),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: Metrics.maxHeight),
            scrollHeight,

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: Metrics.rowInset),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -Metrics.rowInset),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -(Metrics.rowInset * 2)),
        ])
    }

    private func buildRows(channels: [UnifiedChannel],
                           currentChannelId: String?,
                           programProvider: @MainActor (UnifiedChannel) -> UnifiedProgram?) {
        headerLabel.attributedText = NSAttributedString(
            string: "CHANNELS",
            attributes: [
                .font: UIFont.systemFont(ofSize: 15, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.5),
                .kern: 1.5,
            ]
        )

        for channel in channels {
            let row = ChannelRowButton(
                channel: channel,
                program: programProvider(channel),
                isCurrent: channel.id == currentChannelId
            )
            row.onTap = { [weak self] in self?.onSelect(channel) }
            stack.addArrangedSubview(row)
            rows.append(row)
        }
    }

    // MARK: - Teardown

    override func removeFromSuperview() {
        rows.forEach { $0.cancelImageLoad() }
        super.removeFromSuperview()
    }

    deinit {
        rows.forEach { $0.cancelImageLoad() }
    }

    // MARK: - Scroll-to-current

    private var didScrollToCurrent = false

    /// Positions the scroll view on the current channel instantly and
    /// invisibly, before the panel's rise-in animation renders a frame. MUST
    /// be called by the presenter after the panel has real constraints and
    /// `layoutIfNeeded()` has resolved a frame — see the full explanation on
    /// UpNextListView.prepareForPresentation, whose trap (a visible
    /// self-correcting scroll) applies identically here. Idempotent.
    func prepareForPresentation() {
        guard !didScrollToCurrent else { return }
        didScrollToCurrent = true
        scrollToCurrentRow()
    }

    private func scrollToCurrentRow() {
        guard let target = rows.first(where: { $0.isCurrent }) else { return }
        layoutIfNeeded()
        let targetFrame = target.convert(target.bounds, to: scrollView)
        scrollView.scrollRectToVisible(
            targetFrame.insetBy(dx: 0, dy: -(scrollView.bounds.height / 2 - targetFrame.height / 2)),
            animated: false
        )
    }

    // MARK: - Focus

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // After the first landing, hold the row focus already sits on, so a
        // denied edge move doesn't loop focus back to the top of a long
        // channel list. See UpNextListView for the full rationale.
        if hasPinnedInitialFocus {
            return lastFocusedRow.map { [$0] } ?? []
        }
        if let target = rows.first(where: { $0.isCurrent }) ?? rows.first { return [target] }
        return [self]
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if let next = context.nextFocusedView,
           let row = rows.first(where: { next.isDescendant(of: $0) || next === $0 }) {
            hasPinnedInitialFocus = true
            lastFocusedRow = row
        }
    }
}

// MARK: - ChannelRowButton

final class ChannelRowButton: UIControl {

    let isCurrent: Bool
    var onTap: (() -> Void)?

    private let thumbView = UIImageView()
    private let accentBar = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private var imageLoadTask: Task<Void, Never>?
    /// Elapsed-progress bar drawn across the bottom of the artwork. Hidden
    /// when the row has no programme to measure.
    private let progressTrack = UIView()
    private let progressFill = UIView()

    // Matched to UpNextRowButton so both panels read as one component.
    private static let restBackground = UIColor.white.withAlphaComponent(0.06)
    private static let restBackgroundClear = UIColor.clear
    private static let focusedBackground = UIColor.white.withAlphaComponent(0.16)
    private static let restBorder = UIColor.clear.cgColor
    private static let focusedBorder = UIColor.white.withAlphaComponent(0.25).cgColor
    private static let accentColor = UIColor(red: 143/255, green: 233/255, blue: 212/255, alpha: 1)

    init(channel: UnifiedChannel, program: UnifiedProgram?, isCurrent: Bool) {
        self.isCurrent = isCurrent
        super.init(frame: .zero)
        setupViews(channel: channel, program: program)
        loadThumbnail(channel: channel, program: program)
        applyRestAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        imageLoadTask?.cancel()
    }

    override var canBecomeFocused: Bool { true }

    private func setupViews(channel: UnifiedChannel, program: UnifiedProgram?) {
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = Self.restBorder

        thumbView.contentMode = .scaleAspectFill
        thumbView.clipsToBounds = true
        thumbView.layer.cornerRadius = 8
        thumbView.layer.cornerCurve = .continuous
        thumbView.backgroundColor = UIColor.white.withAlphaComponent(0.08)

        accentBar.backgroundColor = Self.accentColor
        accentBar.isHidden = !isCurrent

        titleLabel.text = channel.name
        titleLabel.font = .systemFont(ofSize: 19, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1

        subtitleLabel.text = Self.subtitleText(program: program, isCurrent: isCurrent)
        subtitleLabel.font = .systemFont(ofSize: 15, weight: .regular)
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        subtitleLabel.numberOfLines = 1

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 4
        textStack.isUserInteractionEnabled = false

        // Same shape as the VOD play pill's resume bar (MediaProgressInfoBar):
        // white fill, 4pt tall, 2pt radius. The TRACK is darkened rather than
        // translucent-white, because here it sits on artwork rather than on a
        // dark button, and a white-on-white track leaves the bar unreadable
        // over a bright frame.
        progressTrack.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        progressTrack.layer.cornerRadius = 2
        progressTrack.layer.cornerCurve = .continuous
        progressTrack.clipsToBounds = true
        progressFill.backgroundColor = .white
        progressFill.layer.cornerRadius = 2
        progressFill.layer.cornerCurve = .continuous
        progressTrack.addSubview(progressFill)

        [accentBar, thumbView, textStack].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        [progressTrack, progressFill].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        // Inside the artwork, so it reads as "how far through this programme
        // is" rather than as a row-level control.
        thumbView.addSubview(progressTrack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 92),

            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentBar.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            accentBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            accentBar.widthAnchor.constraint(equalToConstant: 3),

            thumbView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            thumbView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbView.widthAnchor.constraint(equalToConstant: 120),
            thumbView.heightAnchor.constraint(equalToConstant: 68),

            textStack.leadingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: 14),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            progressTrack.leadingAnchor.constraint(equalTo: thumbView.leadingAnchor, constant: 8),
            progressTrack.trailingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: -8),
            progressTrack.bottomAnchor.constraint(equalTo: thumbView.bottomAnchor, constant: -8),
            progressTrack.heightAnchor.constraint(equalToConstant: 4),

            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
        ])

        applyProgress(for: program)
    }

    /// Sizes the fill to the fraction of the programme already elapsed. A
    /// snapshot taken when the panel opens: programmes run for tens of
    /// minutes, so a live-updating bar would buy nothing for the seconds the
    /// panel is on screen.
    private func applyProgress(for program: UnifiedProgram?) {
        guard let program else {
            progressTrack.isHidden = true
            return
        }
        let total = program.endTime.timeIntervalSince(program.startTime)
        // A zero or negative duration is malformed EPG data; show no bar
        // rather than a full or nonsensical one.
        guard total > 0 else {
            progressTrack.isHidden = true
            return
        }
        let elapsed = Date().timeIntervalSince(program.startTime)
        let fraction = min(max(elapsed / total, 0), 1)
        progressTrack.isHidden = false
        // Multiplier against the track means the fill follows the track's
        // real width, with no hardcoded thumbnail geometry to keep in sync.
        // A multiplier must be > 0, so nothing-elapsed pins the width to 0.
        if fraction <= 0 {
            progressFill.widthAnchor.constraint(equalToConstant: 0).isActive = true
        } else {
            progressFill.widthAnchor.constraint(
                equalTo: progressTrack.widthAnchor, multiplier: fraction
            ).isActive = true
        }
    }

    /// Programme title, prefixed on the playing channel so the current row
    /// reads like the VOD panel's "Now playing" row.
    private static func subtitleText(program: UnifiedProgram?, isCurrent: Bool) -> String {
        guard let program else { return isCurrent ? "Now playing" : "No guide data" }
        return isCurrent ? "Now playing · \(program.title)" : program.title
    }

    /// Fills the 16:9 box with genuinely landscape programme art whenever the
    /// EPG offers it: `landscapeURL` (an icon declaring an aspect ratio at or
    /// above `EPGImageClassifier.landscapeThreshold`, so never a logo or a
    /// poster in disguise), or programme art the guide has already measured
    /// as landscape.
    ///
    /// Everything else is FIT, not filled. `iconURL` / `posterURL` are
    /// routinely 2:3 posters, and cropping a portrait poster to 16:9 keeps
    /// only a band across its middle. The channel logo is preferred over a
    /// poster as the fallback: in a channel list, identifying the channel
    /// beats showing a sliver of programme art.
    private func loadThumbnail(channel: UnifiedChannel, program: UnifiedProgram?) {
        let measured = [program?.iconURL, program?.posterURL].compactMap { $0 }
            .first(where: { EPGImageClassifier.shared.isLandscape($0) })
        let landscape = program?.landscapeURL ?? measured
        guard let url = landscape ?? channel.logoURL ?? program?.posterURL ?? program?.iconURL else { return }
        thumbView.contentMode = landscape != nil ? .scaleAspectFill : .scaleAspectFit
        imageLoadTask = Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url)
            guard let self, !Task.isCancelled else { return }
            self.thumbView.image = image
        }
    }

    func cancelImageLoad() {
        imageLoadTask?.cancel()
        imageLoadTask = nil
    }

    private func applyRestAppearance() {
        backgroundColor = isCurrent ? Self.restBackground : Self.restBackgroundClear
        layer.borderColor = Self.restBorder
        transform = .identity
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let isFocused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({
            self.backgroundColor = isFocused
                ? Self.focusedBackground
                : (self.isCurrent ? Self.restBackground : Self.restBackgroundClear)
            self.layer.borderColor = isFocused ? Self.focusedBorder : Self.restBorder
            self.transform = isFocused ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
        }, completion: nil)
    }

    // Select does not fire .primaryActionTriggered on a plain UIControl on
    // tvOS; handle the press directly (same trap as UpNextRowButton).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .select {
            onTap?()
            return
        }
        super.pressesBegan(presses, with: event)
    }
}
