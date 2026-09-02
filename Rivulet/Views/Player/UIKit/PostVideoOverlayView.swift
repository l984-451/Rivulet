// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PostVideoOverlayView.swift
//  Rivulet
//
//  The end-of-episode "Up Next" page: blurred backdrop, next-episode card,
//  autoplay countdown ring, Play Next / Dismiss.
//
//  UIKit because the rest of the player chrome is. As SwiftUI inside the
//  hosting controller it rendered correctly and could not be reached: the
//  container's `preferredFocusEnvironments` never pointed at it and nothing
//  requested a focus update when it appeared, so `@FocusState` had no engine
//  pass to act on and every button sat unfocused. The fix is structural, not
//  a modifier: the container hands focus to this view and asks the engine to
//  re-resolve. See `PlayerContainerViewController.applyPostVideoState`.
//
//  The video keeps playing behind at `VideoFrameState.shrunk`, so the
//  backdrop is masked with a hole at the shrunk rect rather than covering it.
//

import UIKit

final class PostVideoOverlayView: UIView {

    private enum Metrics {
        static let contentSpacing: CGFloat = 32
        static let controlsSpacing: CGFloat = 40
        static let horizontalPadding: CGFloat = 80
        static let cardMaxWidth: CGFloat = 700
    }

    /// Play Next / Play Now, and the Play-Pause press.
    var onPlayNext: (() -> Void)?
    /// Dismiss button: back to fullscreen video.
    var onDismiss: (() -> Void)?
    /// Any focus move the user made. Drives cancel-the-countdown-on-interaction;
    /// the first landing (the engine placing initial focus) does NOT count.
    var onUserFocusMove: (() -> Void)?

    private let backdropContainer = UIView()
    private let backdropImageView = UIImageView()
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let dimView = UIView()

    private let contentStack = UIStackView()
    private let headerStack = UIStackView()
    private let headerLabel = UILabel()
    private let headerSubtitleLabel = UILabel()
    private let card = NextEpisodeCardView()
    private let controlsStack = UIStackView()
    private let ring = CountdownRingView()
    private let playNextButton = PostVideoButtonView(isPrimary: true)
    private let dismissButton = PostVideoButtonView(isPrimary: false)

    private let spinner = UIActivityIndicatorView(style: .large)
    private var hasNextEpisode = false
    private var countdownActive = false
    /// The engine's first landing is not a user interaction. Same guard the
    /// SwiftUI version carried as `hasConsumedInitialFocus`.
    private var hasSeenInitialFocus = false

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        backgroundColor = .clear

        backdropImageView.contentMode = .scaleAspectFill
        backdropImageView.clipsToBounds = true
        // Fallback when there is no art, matching the old solid-black case.
        backdropContainer.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.5)

        headerLabel.font = .systemFont(ofSize: 32, weight: .bold)
        headerLabel.textColor = .white
        headerLabel.textAlignment = .center
        headerSubtitleLabel.font = .systemFont(ofSize: 22)
        headerSubtitleLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        headerSubtitleLabel.textAlignment = .center
        headerSubtitleLabel.text = "You've watched all available episodes"

        headerStack.axis = .vertical
        headerStack.spacing = 8
        headerStack.alignment = .center
        headerStack.addArrangedSubview(headerLabel)
        headerStack.addArrangedSubview(headerSubtitleLabel)

        controlsStack.axis = .horizontal
        controlsStack.spacing = Metrics.controlsSpacing
        controlsStack.alignment = .center
        controlsStack.addArrangedSubview(ring)
        controlsStack.addArrangedSubview(playNextButton)
        controlsStack.addArrangedSubview(dismissButton)

        contentStack.axis = .vertical
        contentStack.spacing = Metrics.contentSpacing
        contentStack.alignment = .center
        contentStack.addArrangedSubview(headerStack)
        contentStack.addArrangedSubview(card)
        contentStack.addArrangedSubview(controlsStack)

        playNextButton.onTap = { [weak self] in self?.onPlayNext?() }
        dismissButton.onTap = { [weak self] in self?.onDismiss?() }
        let focusMoved: () -> Void = { [weak self] in
            guard let self else { return }
            guard self.hasSeenInitialFocus else {
                self.hasSeenInitialFocus = true
                return
            }
            self.onUserFocusMove?()
        }
        playNextButton.onFocused = focusMoved
        dismissButton.onFocused = focusMoved

        [backdropImageView, blurView, dimView].forEach {
            backdropContainer.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                $0.topAnchor.constraint(equalTo: backdropContainer.topAnchor),
                $0.bottomAnchor.constraint(equalTo: backdropContainer.bottomAnchor),
                $0.leadingAnchor.constraint(equalTo: backdropContainer.leadingAnchor),
                $0.trailingAnchor.constraint(equalTo: backdropContainer.trailingAnchor),
            ])
        }

        spinner.color = .white
        spinner.hidesWhenStopped = true

        [backdropContainer, contentStack, spinner].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),

            backdropContainer.topAnchor.constraint(equalTo: topAnchor),
            backdropContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            backdropContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdropContainer.trailingAnchor.constraint(equalTo: trailingAnchor),

            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: Metrics.horizontalPadding),
            contentStack.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -Metrics.horizontalPadding),

            card.widthAnchor.constraint(equalToConstant: Metrics.cardMaxWidth),
        ])
    }

    // MARK: - Content

    func configure(nextEpisode: PlexMetadata?, serverURL: String, authToken: String, backdrop: UIImage?) {
        hasNextEpisode = nextEpisode != nil
        backdropImageView.image = backdrop
        // No art: the container's own translucent black stands in, and the
        // blur over nothing would just wash it out.
        blurView.isHidden = backdrop == nil
        dimView.isHidden = backdrop == nil

        headerLabel.text = hasNextEpisode ? "Up Next" : "End of Series"
        headerSubtitleLabel.isHidden = hasNextEpisode
        card.isHidden = !hasNextEpisode
        if let nextEpisode {
            card.configure(episode: nextEpisode, serverURL: serverURL, authToken: authToken)
        }
        applyButtonState()
    }

    /// While the next episode is still being fetched: backdrop and spinner
    /// only. Same beat the SwiftUI `.loading` case covered.
    func setLoading(_ loading: Bool) {
        contentStack.isHidden = loading
        if loading { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    /// Countdown tick. `total` is the resolved setting, not a re-read of
    /// UserDefaults — see `UniversalPlayerViewModel.countdownTotalSeconds`.
    func setCountdown(remaining: Int, total: Int, isPaused: Bool) {
        countdownActive = remaining > 0 && !isPaused
        ring.isHidden = !(hasNextEpisode && countdownActive)
        ring.update(remaining: remaining, total: total, isPaused: isPaused)
        applyButtonState()
    }

    private func applyButtonState() {
        playNextButton.isHidden = !hasNextEpisode
        playNextButton.configure(
            title: countdownActive ? "Play Now" : "Play Next", systemImage: "play.fill")
        // With a countdown running, Dismiss means "stop the countdown"; with
        // none, it means "back to the video". Same two roles the SwiftUI
        // version split across two buttons that were never on screen together.
        dismissButton.configure(
            title: "Dismiss", systemImage: countdownActive ? nil : "xmark")
        dismissButton.setPrimaryLook(!hasNextEpisode)
    }

    // MARK: - Focus

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        hasNextEpisode ? [playNextButton] : [dismissButton]
    }

    /// A fresh presentation gets a fresh initial-focus grace.
    func resetFocusGrace() {
        hasSeenInitialFocus = false
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .playPause {
            if hasNextEpisode {
                onPlayNext?()
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        applyShrunkVideoHole()
    }

    /// The video plays on behind this view at `VideoFrameState.shrunk`, so
    /// punch its rect out of the backdrop instead of covering it. Derived from
    /// the same constants the video layer scales by, not a second copy.
    private func applyShrunkVideoHole() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = VideoFrameState.shrunk.scale
        let offset = VideoFrameState.shrunk.offset
        let hole = CGRect(
            x: offset.width,
            y: offset.height,
            width: bounds.width * scale,
            height: bounds.height * scale
        )
        let path = UIBezierPath(rect: bounds)
        path.append(UIBezierPath(roundedRect: hole, cornerRadius: 12))
        let mask = (backdropContainer.layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        mask.frame = bounds
        mask.fillRule = .evenOdd
        mask.path = path.cgPath
        backdropContainer.layer.mask = mask
    }
}

// MARK: - Next episode card

final class NextEpisodeCardView: UIView {

    private let thumbView = UIImageView()
    private let showLabel = UILabel()
    private let numberLabel = UILabel()
    private let titleLabel = UILabel()
    private let summaryLabel = UILabel()
    private let durationLabel = UILabel()
    private var imageLoadTask: Task<Void, Never>?
    /// Guards against re-fetching the thumbnail on every countdown tick —
    /// `configure` runs once a second while the ring counts down.
    private var configuredRatingKey: String?

    init() {
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        imageLoadTask?.cancel()
    }

    private func setupViews() {
        // A translucent fill rather than a second blur: this card sits on an
        // already-blurred backdrop, where another blur pass reads the same and
        // costs an extra offscreen. Matches the glass row style.
        backgroundColor = UIColor.white.withAlphaComponent(0.08)
        layer.cornerRadius = 20
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.1).cgColor

        thumbView.contentMode = .scaleAspectFill
        thumbView.clipsToBounds = true
        thumbView.layer.cornerRadius = 12
        thumbView.layer.cornerCurve = .continuous
        thumbView.backgroundColor = UIColor.white.withAlphaComponent(0.1)

        showLabel.font = .systemFont(ofSize: 22, weight: .medium)
        showLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        showLabel.numberOfLines = 1

        numberLabel.font = .monospacedSystemFont(ofSize: 20, weight: .semibold)
        numberLabel.textColor = UIColor.white.withAlphaComponent(0.5)
        numberLabel.setContentHuggingPriority(.required, for: .horizontal)
        numberLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 26, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1

        summaryLabel.font = .systemFont(ofSize: 20)
        summaryLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        summaryLabel.numberOfLines = 3

        durationLabel.font = .systemFont(ofSize: 18)
        durationLabel.textColor = UIColor.white.withAlphaComponent(0.5)

        let titleRow = UIStackView(arrangedSubviews: [numberLabel, titleLabel])
        titleRow.axis = .horizontal
        titleRow.spacing = 12
        titleRow.alignment = .firstBaseline

        let textStack = UIStackView(arrangedSubviews: [showLabel, titleRow, summaryLabel, durationLabel])
        textStack.axis = .vertical
        textStack.spacing = 8
        textStack.alignment = .leading
        textStack.setCustomSpacing(12, after: summaryLabel)

        [thumbView, textStack].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            thumbView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            thumbView.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            thumbView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -24),
            thumbView.widthAnchor.constraint(equalToConstant: 280),
            thumbView.heightAnchor.constraint(equalToConstant: 158),

            textStack.leadingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: 24),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            textStack.heightAnchor.constraint(greaterThanOrEqualTo: thumbView.heightAnchor),
        ])
    }

    func configure(episode: PlexMetadata, serverURL: String, authToken: String) {
        guard configuredRatingKey != episode.ratingKey else { return }
        configuredRatingKey = episode.ratingKey
        showLabel.text = episode.grandparentTitle
        showLabel.isHidden = (episode.grandparentTitle ?? "").isEmpty
        numberLabel.text = String(format: "S%02dE%02d", episode.parentIndex ?? 0, episode.index ?? 0)
        titleLabel.text = episode.title ?? "Episode"
        summaryLabel.text = episode.summary
        summaryLabel.isHidden = (episode.summary ?? "").isEmpty
        if let duration = episode.duration {
            durationLabel.text = "\(duration / 60000) min"
            durationLabel.isHidden = false
        } else {
            durationLabel.isHidden = true
        }
        loadThumbnail(episode: episode, serverURL: serverURL, authToken: authToken)
    }

    private func loadThumbnail(episode: PlexMetadata, serverURL: String, authToken: String) {
        imageLoadTask?.cancel()
        thumbView.image = nil
        guard let thumbPath = episode.thumb,
              let url = PlexNetworkManager.shared.buildThumbnailURL(
                serverURL: serverURL, authToken: authToken, thumbPath: thumbPath,
                width: 560, height: 316) else { return }
        imageLoadTask = Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url)
            guard let self, !Task.isCancelled else { return }
            self.thumbView.image = image
        }
    }
}

// MARK: - Countdown ring

final class CountdownRingView: UIView {

    private enum Metrics {
        static let size: CGFloat = 100
        static let lineWidth: CGFloat = 6
    }

    private let trackLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()
    private let numberLabel = UILabel()
    private var lastProgress: CGFloat = 1

    init() {
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        for shape in [trackLayer, progressLayer] {
            shape.fillColor = UIColor.clear.cgColor
            shape.lineWidth = Metrics.lineWidth
            layer.addSublayer(shape)
        }
        trackLayer.strokeColor = UIColor.white.withAlphaComponent(0.2).cgColor
        progressLayer.strokeColor = UIColor.white.cgColor
        progressLayer.lineCap = .round
        progressLayer.strokeEnd = 1

        numberLabel.font = .systemFont(ofSize: 48, weight: .bold)
        numberLabel.textColor = .white
        numberLabel.textAlignment = .center
        addSubview(numberLabel)
        numberLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Metrics.size),
            heightAnchor.constraint(equalToConstant: Metrics.size),
            numberLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            numberLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = Metrics.lineWidth / 2
        let radius = min(bounds.width, bounds.height) / 2 - inset
        let path = UIBezierPath(
            arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
            radius: radius,
            startAngle: -.pi / 2,
            endAngle: .pi * 1.5,
            clockwise: true
        )
        trackLayer.frame = bounds
        progressLayer.frame = bounds
        trackLayer.path = path.cgPath
        progressLayer.path = path.cgPath
    }

    func update(remaining: Int, total: Int, isPaused: Bool) {
        numberLabel.text = "\(remaining)"
        let color: UIColor = isPaused ? .gray : .white
        numberLabel.textColor = color
        progressLayer.strokeColor = color.cgColor

        let progress: CGFloat = total > 0 ? CGFloat(remaining) / CGFloat(total) : 0
        guard progress != lastProgress else { return }
        // Write the model value first, then animate from the old one: parking
        // the presentation layer with fillMode would leave the model
        // disagreeing with the screen on the next tick.
        let from = lastProgress
        lastProgress = progress
        progressLayer.strokeEnd = progress
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = from
        animation.toValue = progress
        animation.duration = 1
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        progressLayer.add(animation, forKey: "strokeEnd")
    }
}

// MARK: - Button

final class PostVideoButtonView: UIControl {

    var onTap: (() -> Void)?
    var onFocused: (() -> Void)?

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let stack = UIStackView()
    private var isPrimary: Bool

    init(isPrimary: Bool) {
        self.isPrimary = isPrimary
        super.init(frame: .zero)
        setupViews()
        applyLook(focused: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFocused: Bool { true }

    private func setupViews() {
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        titleLabel.textColor = .white

        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.isUserInteractionEnabled = false
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(titleLabel)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false

        applyMetrics()
    }

    private var metricConstraints: [NSLayoutConstraint] = []

    private func applyMetrics() {
        NSLayoutConstraint.deactivate(metricConstraints)
        let h: CGFloat = isPrimary ? 32 : 28
        let v: CGFloat = isPrimary ? 16 : 14
        metricConstraints = [
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: h),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -h),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: v),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -v),
        ]
        NSLayoutConstraint.activate(metricConstraints)
        titleLabel.font = .systemFont(ofSize: isPrimary ? 24 : 22, weight: isPrimary ? .semibold : .medium)
    }

    func configure(title: String, systemImage: String?) {
        titleLabel.text = title
        if let systemImage {
            iconView.image = UIImage(
                systemName: systemImage,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: isPrimary ? 22 : 18, weight: .semibold))
            iconView.isHidden = false
        } else {
            iconView.image = nil
            iconView.isHidden = true
        }
    }

    func setPrimaryLook(_ primary: Bool) {
        guard primary != isPrimary else { return }
        isPrimary = primary
        applyMetrics()
        applyLook(focused: isFocused)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    private func applyLook(focused: Bool) {
        let fill: CGFloat = isPrimary ? (focused ? 0.22 : 0.12) : (focused ? 0.18 : 0.08)
        backgroundColor = UIColor.white.withAlphaComponent(fill)
        let borderAlpha: CGFloat = focused ? (isPrimary ? 0.35 : 0.25) : 0.08
        layer.borderColor = UIColor.white.withAlphaComponent(borderAlpha).cgColor
        layer.borderWidth = focused ? 3 : 1
        transform = focused ? CGAffineTransform(scaleX: 1.08, y: 1.08) : .identity
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({ self.applyLook(focused: focused) }, completion: nil)
        if focused { onFocused?() }
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
