// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PostVideoOverlayView.swift
//  Rivulet
//
//  The end-of-episode Up Next card, sliding in over the credits. The view is
//  exactly the card's footprint: anything larger would occlude the content anchor.
//

import UIKit

final class PostVideoOverlayView: UIView {

    private enum Metrics {
        static let width: CGFloat = 640
        static let padding: CGFloat = 40
        static let cornerRadius: CGFloat = 40
        static let spacing: CGFloat = 24
        /// How far past the screen edge the card starts and ends.
        static let offscreen: CGFloat = 720
    }

    /// Play Next / Play Now, and the Play-Pause press.
    var onPlayNext: (() -> Void)?
    /// Dismiss button: stop the countdown, else close the card.
    var onDismiss: (() -> Void)?
    /// A focus move the user made with the remote. Cancels the countdown.
    var onUserFocusMove: (() -> Void)?

    /// The rail panels' glass.
    private let glass = UIVisualEffectView(effect: TransportControlButton.glassEffect())
    private let contentStack = UIStackView()
    private let headerLabel = UILabel()
    private let headerSubtitleLabel = UILabel()
    private let card = NextEpisodeCardView()
    private let ring = CountdownRingView()
    private let playNextButton = PostVideoButtonView(isPrimary: true)
    private let dismissButton = PostVideoButtonView(isPrimary: false)

    private var hasNextEpisode = false
    private var countdownActive = false
    private var isOnScreen = false

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
        transform = CGAffineTransform(translationX: Metrics.offscreen, y: 0)

        glass.clipsToBounds = true
        glass.layer.cornerRadius = Metrics.cornerRadius
        glass.layer.cornerCurve = .continuous

        headerLabel.font = .systemFont(ofSize: 32, weight: .bold)
        headerLabel.textColor = .white
        headerSubtitleLabel.font = .systemFont(ofSize: 22)
        headerSubtitleLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        headerSubtitleLabel.numberOfLines = 2
        applyChromeTextShadow([headerLabel, headerSubtitleLabel])

        let headerText = UIStackView(arrangedSubviews: [headerLabel, headerSubtitleLabel])
        headerText.axis = .vertical
        headerText.spacing = 8
        let header = UIStackView(arrangedSubviews: [headerText, ring])
        header.axis = .horizontal
        header.alignment = .center
        header.distribution = .equalSpacing

        let buttons = UIStackView(arrangedSubviews: [playNextButton, dismissButton])
        buttons.axis = .horizontal
        buttons.spacing = 24

        contentStack.axis = .vertical
        contentStack.spacing = Metrics.spacing
        // Leading so the buttons keep their own width; header and card fill.
        contentStack.alignment = .leading
        contentStack.addArrangedSubview(header)
        contentStack.addArrangedSubview(card)
        contentStack.addArrangedSubview(buttons)
        contentStack.setCustomSpacing(36, after: card)

        playNextButton.onTap = { [weak self] in self?.onPlayNext?() }
        dismissButton.onTap = { [weak self] in self?.onDismiss?() }
        playNextButton.onUserFocus = { [weak self] in self?.onUserFocusMove?() }
        dismissButton.onUserFocus = { [weak self] in self?.onUserFocusMove?() }

        [glass, contentStack].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Metrics.width),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.padding),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.padding),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.padding),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.padding),
            header.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            card.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])
    }

    // MARK: - Content

    /// `thumbnailURL` is the next episode's own image URL when it has one;
    /// nil builds the Plex thumbnail URL.
    func configure(nextEpisode: PlexMetadata?, serverURL: String, authToken: String,
                   thumbnailURL: URL? = nil, errorMessage: String? = nil) {
        hasNextEpisode = nextEpisode != nil
        headerLabel.text = hasNextEpisode ? "Up Next" : "End of Series"
        headerSubtitleLabel.text = errorMessage ?? "You've watched all available episodes"
        headerSubtitleLabel.isHidden = hasNextEpisode && errorMessage == nil
        card.isHidden = !hasNextEpisode
        if let nextEpisode {
            card.configure(episode: nextEpisode, serverURL: serverURL, authToken: authToken,
                           thumbnailURL: thumbnailURL)
        }
        applyButtonState()
    }

    /// The card stays off screen while the next episode is fetched, then slides in.
    func setLoading(_ loading: Bool) {
        guard !loading, !isOnScreen else { return }
        isOnScreen = true
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
            self.transform = .identity
        }
    }

    /// Slides the card back off the edge, then removes it.
    func slideOut(completion: @escaping () -> Void) {
        isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.35, delay: 0, options: .curveEaseIn, animations: {
            self.transform = CGAffineTransform(translationX: Metrics.offscreen, y: 0)
        }, completion: { _ in
            self.removeFromSuperview()
            completion()
        })
    }

    /// Countdown tick. `total` is the resolved setting, not a re-read of
    /// UserDefaults — see `UniversalPlayerViewModel.countdownTotalSeconds`.
    func setCountdown(remaining: Int, total: Int, isPaused: Bool) {
        countdownActive = remaining > 0 && !isPaused
        // Alpha, not isHidden: the ring sets the header's height, so hiding it moved the card.
        ring.alpha = hasNextEpisode && countdownActive ? 1 : 0
        ring.update(remaining: remaining, total: total, isPaused: isPaused)
        applyButtonState()
    }

    private func applyButtonState() {
        playNextButton.isHidden = !hasNextEpisode
        playNextButton.configure(
            title: countdownActive ? "Play Now" : "Play Next", systemImage: "play.fill")
        // With a countdown running, Dismiss means "stop the countdown"; with
        // none, it means "close the card".
        dismissButton.configure(
            title: "Dismiss", systemImage: countdownActive ? nil : "xmark")
        dismissButton.setPrimaryLook(!hasNextEpisode)
    }

    // MARK: - Focus

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        hasNextEpisode ? [playNextButton] : [dismissButton]
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
        thumbView.contentMode = .scaleAspectFill
        thumbView.clipsToBounds = true
        thumbView.layer.cornerRadius = 20
        thumbView.layer.cornerCurve = .continuous
        thumbView.backgroundColor = UIColor.white.withAlphaComponent(0.1)

        showLabel.font = .systemFont(ofSize: 22, weight: .medium)
        showLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        showLabel.numberOfLines = 1

        numberLabel.font = .monospacedSystemFont(ofSize: 20, weight: .semibold)
        numberLabel.textColor = UIColor.white.withAlphaComponent(0.5)
        numberLabel.setContentHuggingPriority(.required, for: .horizontal)
        numberLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1

        summaryLabel.font = .systemFont(ofSize: 22)
        summaryLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        summaryLabel.numberOfLines = 4

        durationLabel.font = .systemFont(ofSize: 20)
        durationLabel.textColor = UIColor.white.withAlphaComponent(0.5)
        applyChromeTextShadow([showLabel, numberLabel, titleLabel, summaryLabel, durationLabel])

        let titleRow = UIStackView(arrangedSubviews: [numberLabel, titleLabel])
        titleRow.axis = .horizontal
        titleRow.spacing = 12
        titleRow.alignment = .firstBaseline

        let stack = UIStackView(arrangedSubviews: [thumbView, showLabel, titleRow, summaryLabel, durationLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .fill
        stack.setCustomSpacing(20, after: thumbView)
        stack.setCustomSpacing(12, after: summaryLabel)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            thumbView.heightAnchor.constraint(equalTo: thumbView.widthAnchor, multiplier: 9.0 / 16.0),
        ])
    }

    func configure(episode: PlexMetadata, serverURL: String, authToken: String, thumbnailURL: URL? = nil) {
        guard configuredRatingKey != episode.ratingKey else { return }
        configuredRatingKey = episode.ratingKey
        showLabel.text = episode.grandparentTitle
        showLabel.isHidden = (episode.grandparentTitle ?? "").isEmpty
        // A playlist's next item can be a movie: year in place of SxEy.
        numberLabel.text = episode.type == "episode"
            ? String(format: "S%02dE%02d", episode.parentIndex ?? 0, episode.index ?? 0)
            : episode.year.map(String.init)
        numberLabel.isHidden = numberLabel.text == nil
        titleLabel.text = episode.title ?? "Episode"
        summaryLabel.text = episode.summary
        summaryLabel.isHidden = (episode.summary ?? "").isEmpty
        if let duration = episode.duration {
            durationLabel.text = "\(duration / 60000) min"
            durationLabel.isHidden = false
        } else {
            durationLabel.isHidden = true
        }
        loadThumbnail(episode: episode, serverURL: serverURL, authToken: authToken, url: thumbnailURL)
    }

    private func loadThumbnail(episode: PlexMetadata, serverURL: String, authToken: String, url: URL?) {
        imageLoadTask?.cancel()
        thumbView.image = nil
        guard let url = url ?? episode.thumb.flatMap({
            PlexNetworkManager.shared.buildThumbnailURL(
                serverURL: serverURL, authToken: authToken, thumbPath: $0, width: 1120, height: 630)
        }) else { return }
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
        static let size: CGFloat = 72
        static let lineWidth: CGFloat = 5
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

        numberLabel.font = .systemFont(ofSize: 32, weight: .bold)
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
        // Only the tick down animates; a countdown starts full.
        guard progress < lastProgress else {
            lastProgress = progress
            progressLayer.removeAnimation(forKey: "strokeEnd")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            progressLayer.strokeEnd = progress
            CATransaction.commit()
            return
        }
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
    /// Focus arrived by a remote move. Engine placements (first landing, the
    /// hand-off from Dismiss to Play Next once the episode loads) have no heading.
    var onUserFocus: (() -> Void)?

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
        if focused, !context.focusHeading.isEmpty { onUserFocus?() }
    }

    // Select does not fire .primaryActionTriggered on a plain UIControl on
    // tvOS; handle the press directly.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .select {
            onTap?()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    // The release must not bubble: once the card is gone the player reads it as Select on the video.
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { return }
        super.pressesEnded(presses, with: event)
    }
}
