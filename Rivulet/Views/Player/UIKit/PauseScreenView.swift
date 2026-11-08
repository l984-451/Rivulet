// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PauseScreenView.swift
//  Rivulet
//
//  The pause screen: after 10 s paused the player says what is paused and how long
//  is left; after 2 min it settles into a dimmer, quieter state (an OLED burn-in
//  guard) and the title's art replaces the paused picture. Two looks, picked in
//  Settings (`PauseScreenStyle`): Frame keeps the paused picture under a scrim (the
//  container pushes it in), and Glass dims it (a flat 30% black, the picture left
//  sharp) and holds the details on a glass card.
//
//  Plain UIKit, non-interactive and focusless. `PlayerContainerViewController`
//  mounts it above the video and captions and below the content focus anchor, and
//  drives it from `applyPauseScreen`, its single writer. Sizes are points on the
//  1920x1080 screen, measured from the design mock.
//

import UIKit

final class PauseScreenView: UIView {

    /// The two paused tiers (`UniversalPlayerViewModel.PausePresentation` past `.frame`).
    enum Tier { case ambient, dimmed }

    struct Content {
        var title: String
        var logo: UIImage?
        var detailLine: String?
        var synopsis: String?
        /// Full-resolution backdrop: the 2 min picture, and the picture while no frame exists.
        var artURL: URL?
    }

    private enum Metrics {
        static let margin: CGFloat = 80
        static let infoBottom: CGFloat = 92
        static let glassInfoBottom: CGFloat = 80
        static let infoWidth: CGFloat = 860
        static let glassCardWidth: CGFloat = 860
        static let glassPadding = UIEdgeInsets(top: 54, left: 58, bottom: 54, right: 58)
        static let glassRadius: CGFloat = 46
        static let lineGap: CGFloat = 22
        static let logoGap: CGFloat = 30
        static let logoBox = CGSize(width: 640, height: 120)
        static let dimmedLogoBox = CGSize(width: 520, height: 96)
        static let clockTop: CGFloat = 58
        static let miniBar = CGSize(width: 220, height: 6)
        /// Glass: the flat black over the sharp picture, under the card.
        static let glassDim: CGFloat = 0.30
        static let dim: CGFloat = 0.34
        static let dimmedScrim: CGFloat = 0.85
        static let drift: (from: CGFloat, to: CGFloat) = (1.04, 1.08)
        static let driftDuration: TimeInterval = 60
        static let stagger: TimeInterval = 0.12
        static let rise: CGFloat = 16
    }

    /// Position and duration, read on show and on each minute tick ("Ends at" moves with the clock).
    var progress: () -> (position: TimeInterval, duration: TimeInterval) = { (0, 0) }

    private(set) var isShowing = false
    private(set) var style: PauseScreenStyle = .frame
    private var tier: Tier = .ambient
    private var parked = false
    private var content = Content(title: "")

    // Picture layers, bottom-up.
    private let artView = UIImageView()
    /// Glass's flat dim over the picture (`Metrics.glassDim`).
    private let glassDimView = UIView()
    /// The 2 min tier's dim, over the Glass dim.
    private let dimView = UIView()
    /// Frame's gradient scrim; Glass keeps it off.
    private let scrimView = PauseScrimView()

    private let clockLabel = UILabel()

    // Info block, bottom left.
    private let infoContainer = UIView()
    private let cardView = UIVisualEffectView(effect: nil)
    private let infoStack = UIStackView()
    private let logoSlot = UIView()
    private let logoView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let synopsisLabel = UILabel()
    private let timeRow = UIStackView()
    private let miniTrack = UIView()
    private let miniFill = UIView()
    private let timeLabel = UILabel()

    private var infoBottom: NSLayoutConstraint!
    private var stackInsets: [NSLayoutConstraint] = []
    private var infoWidth: NSLayoutConstraint!
    private var logoWidth: NSLayoutConstraint!
    private var logoHeight: NSLayoutConstraint!
    private var miniFillWidth: NSLayoutConstraint!

    private var clockTimer: Timer?
    private var artTask: Task<Void, Never>?
    private var loadedArtURL: URL?
    private var isDrifting = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        clipsToBounds = true
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Off the window (the player dismissed with the pause screen up) nothing
    /// repeating may run on: the timers, the art load and the drift all stop.
    /// Not `deinit`: it is nonisolated, and these are main-actor state.
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        stopTimers()
        artTask?.cancel()
        artTask = nil
        stopDrift()
    }

    // MARK: - Driving

    /// Brings the pause screen up: the picture treatment first, then the info lines
    /// rise in one after another.
    func show(style: PauseScreenStyle, content: Content, tier: Tier, parked: Bool) {
        isShowing = true
        self.style = style
        self.tier = tier
        self.parked = parked
        self.content = content
        // A hide still fading out ends here; its completion sees `isShowing` and stands down.
        stopDrift()
        isHidden = false

        configureStyle()
        configureContent()
        loadArt()
        refreshTime()
        startTimers()

        // Start from nothing, without animation.
        UIView.performWithoutAnimation {
            for view in [artView, glassDimView, dimView, scrimView, clockLabel] { view.alpha = 0 }
            cardView.effect = nil
            applyLayout()
            for view in infoLines {
                view.alpha = 0
                view.transform = CGAffineTransform(translationX: 0, y: Metrics.rise)
            }
            layoutIfNeeded()
        }

        UIView.animate(withDuration: 1.0, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
            self.applyPicture()
            self.clockLabel.alpha = 1
        }
        if style == .glass {
            UIView.animate(withDuration: 0.6, delay: 0.15, options: [.curveEaseOut]) {
                self.cardView.effect = Self.glassEffect()
            }
        }
        var delay: TimeInterval = 0.25
        for view in infoLines where !view.isHidden {
            UIView.animate(withDuration: 0.6, delay: delay, options: [.curveEaseOut]) {
                view.alpha = 1
                view.transform = .identity
            }
            delay += Metrics.stagger
        }
    }

    /// The 2 min tier, or the frame going away under a sleep (parked).
    func update(tier: Tier, parked: Bool) {
        guard isShowing, tier != self.tier || parked != self.parked else { return }
        self.tier = tier
        self.parked = parked
        UIView.animate(withDuration: 1.2, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.applyLayout()
            self.applyPicture()
            for view in [self.detailLabel, self.synopsisLabel] { view.alpha = view.isHidden ? 0 : 1 }
            self.layoutIfNeeded()
        }
    }

    /// A logo that resolved after the pause screen came up.
    func setLogo(_ image: UIImage?) {
        guard isShowing, content.logo !== image else { return }
        content.logo = image
        UIView.transition(with: infoStack, duration: 0.4, options: [.transitionCrossDissolve, .beginFromCurrentState]) {
            self.configureTitle()
            self.applyLayout()
            // Whichever of the two was hidden on show never ran its entrance.
            for view in [self.logoSlot, self.titleLabel] {
                view.alpha = 1
                view.transform = .identity
            }
            self.layoutIfNeeded()
        }
    }

    /// Fades everything out (the picture's own push-in is the container's).
    func hide() {
        guard isShowing else { return }
        isShowing = false
        stopTimers()
        artTask?.cancel()
        artTask = nil
        UIView.animate(withDuration: 0.5, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            for view in [self.artView, self.glassDimView, self.dimView, self.scrimView, self.clockLabel] {
                view.alpha = 0
            }
            for view in self.infoLines { view.alpha = 0 }
            self.cardView.effect = nil
        } completion: { _ in
            guard !self.isShowing else { return }
            self.isHidden = true
            self.stopDrift()
            // A 4K decode is ~33 MB; the cache keeps the bytes for the next pause.
            self.artView.image = nil
            self.loadedArtURL = nil
        }
    }

    // MARK: - State

    private var infoLines: [UIView] { [logoSlot, titleLabel, detailLabel, synopsisLabel, timeRow] }

    /// Both styles show the art at 2 min, and while no frame exists. Only Frame's drifts.
    private var showsArt: Bool {
        artView.image != nil && (parked || tier == .dimmed)
    }

    /// Alphas of the picture layers for the current state. Inside an animation block.
    /// Glass is the sharp picture under a flat dim; Frame is the picture under the scrim.
    private func applyPicture() {
        let glass = style == .glass
        artView.alpha = showsArt ? 1 : 0
        glassDimView.alpha = glass ? Metrics.glassDim : 0
        dimView.alpha = tier == .dimmed ? Metrics.dim : 0
        scrimView.alpha = glass ? 0 : (tier == .dimmed ? Metrics.dimmedScrim : 1)
        if showsArt && style == .frame { startDrift() } else if !showsArt { stopDrift() }
    }

    /// Which info lines show and how large the logo sits. Inside an animation block.
    private func applyLayout() {
        let dimmed = tier == .dimmed
        detailLabel.isHidden = dimmed || content.detailLine == nil
        synopsisLabel.isHidden = dimmed || content.synopsis == nil
        fitLogo(in: dimmed ? Metrics.dimmedLogoBox : Metrics.logoBox)
        titleLabel.font = .systemFont(ofSize: dimmed ? 60 : 72, weight: .bold)
    }

    // MARK: - Configuration

    private func configureStyle() {
        let glass = style == .glass
        infoBottom.constant = -(glass ? Metrics.glassInfoBottom : Metrics.infoBottom)
        let pad = glass ? Metrics.glassPadding : .zero
        stackInsets[0].constant = pad.top
        stackInsets[1].constant = pad.left
        stackInsets[2].constant = -pad.right
        stackInsets[3].constant = -pad.bottom
        let width = glass ? Metrics.glassCardWidth - pad.left - pad.right : Metrics.infoWidth
        infoWidth.constant = width
        for label in [titleLabel, detailLabel, synopsisLabel, timeLabel] {
            label.preferredMaxLayoutWidth = width
        }
        // Over the bare picture the text needs lift; on glass it has the card.
        for label in [titleLabel, detailLabel, synopsisLabel, timeLabel] {
            label.layer.shadowOpacity = glass ? 0 : 0.35
        }
        artView.transform = .identity
    }

    private func configureContent() {
        configureTitle()
        detailLabel.text = content.detailLine
        synopsisLabel.attributedText = content.synopsis.map {
            Self.text($0, size: 28, weight: .regular, color: UIColor(white: 1, alpha: 0.82), lineHeight: 40)
        }
        synopsisLabel.lineBreakMode = .byTruncatingTail
    }

    /// The logo when there is one, else the title in large bold type.
    private func configureTitle() {
        logoView.image = content.logo
        logoSlot.isHidden = content.logo == nil
        titleLabel.isHidden = content.logo != nil
        titleLabel.text = content.title
    }

    /// Aspect-fits the logo in `box`, resting on the slot's leading edge.
    private func fitLogo(in box: CGSize) {
        guard let image = content.logo, image.size.width > 0, image.size.height > 0 else { return }
        let aspect = image.size.width / image.size.height
        let height = min(box.height, box.width / aspect)
        logoHeight.constant = height
        logoWidth.constant = height * aspect
    }

    private func refreshTime() {
        clockLabel.text = Date().formatted(date: .omitted, time: .shortened)
        let (position, duration) = progress()
        let line = PauseScreenText.timeLine(position: position, duration: duration, now: Date())
        timeLabel.text = line
        timeRow.isHidden = line == nil
        miniFillWidth.constant = Metrics.miniBar.width * PauseScreenText.progress(position: position, duration: duration)
    }

    // MARK: - Art

    private func loadArt() {
        guard let url = content.artURL else {
            artView.image = nil
            loadedArtURL = nil
            return
        }
        guard url != loadedArtURL else { return }
        artView.image = nil
        loadedArtURL = url
        artTask?.cancel()
        artTask = Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url, quality: .full)
            guard let self, !Task.isCancelled, self.isShowing, self.loadedArtURL == url else { return }
            self.artView.image = image
            UIView.animate(withDuration: 1.2, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
                self.applyPicture()
            }
        }
    }

    #if DEBUG
    /// `PauseScreenProbe`: art without a server.
    func debugSetArt(_ image: UIImage) {
        artView.image = image
        UIView.animate(withDuration: 1.2, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.applyPicture()
        }
    }
    #endif

    /// A slow drift on the Frame art, as on the Apple TV app's screensaver stills.
    private func startDrift() {
        guard !isDrifting else { return }
        isDrifting = true
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        UIView.performWithoutAnimation {
            artView.transform = CGAffineTransform(scaleX: Metrics.drift.from, y: Metrics.drift.from)
        }
        UIView.animate(withDuration: Metrics.driftDuration, delay: 0, options: [.curveEaseInOut]) {
            self.artView.transform = CGAffineTransform(scaleX: Metrics.drift.to, y: Metrics.drift.to)
        }
    }

    /// Ends the drift at once. Only its transform animation goes: this runs inside
    /// `applyPicture`'s block, beside the art's own fade.
    private func stopDrift() {
        guard isDrifting else { return }
        isDrifting = false
        artView.layer.removeTransformAnimations()
        UIView.performWithoutAnimation { artView.transform = .identity }
    }

    // MARK: - Timers

    private func startTimers() {
        stopTimers()
        // The clock turns over on the minute, so the first tick waits for it.
        let now = Date()
        let nextMinute = Calendar.current.nextDate(after: now, matching: DateComponents(second: 0),
                                                   matchingPolicy: .nextTime) ?? now.addingTimeInterval(60)
        let clock = Timer(fire: nextMinute, interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTime() }
        }
        RunLoop.main.add(clock, forMode: .common)
        clockTimer = clock
    }

    private func stopTimers() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    // MARK: - Build

    private static func glassEffect() -> UIGlassEffect {
        let effect = UIGlassEffect(style: .regular)
        effect.tintColor = UIColor(white: 1, alpha: 0.1)
        return effect
    }

    private static func text(_ string: String, size: CGFloat, weight: UIFont.Weight, color: UIColor,
                             lineHeight: CGFloat) -> NSAttributedString {
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = max(0, lineHeight - font.lineHeight)
        // No truncating break mode here: in an attributed string it makes every
        // paragraph one line. The label's own `lineBreakMode` truncates the last line.
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    private static func shadow(_ view: UIView, opacity: Float, radius: CGFloat, y: CGFloat) {
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = opacity
        view.layer.shadowRadius = radius
        view.layer.shadowOffset = CGSize(width: 0, height: y)
    }

    private func build() {
        backgroundColor = .clear

        artView.contentMode = .scaleAspectFill
        artView.clipsToBounds = true
        glassDimView.backgroundColor = .black
        dimView.backgroundColor = .black

        for view in [artView, glassDimView, dimView, scrimView] {
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.isUserInteractionEnabled = false
            addSubview(view)
        }

        clockLabel.font = .monospacedDigitSystemFont(ofSize: 38, weight: .medium)
        clockLabel.textColor = UIColor(white: 1, alpha: 0.9)
        Self.shadow(clockLabel, opacity: 0.45, radius: 14, y: 2)

        // Info block.
        cardView.clipsToBounds = true
        cardView.layer.cornerRadius = Metrics.glassRadius
        cardView.layer.cornerCurve = .continuous

        logoView.contentMode = .scaleAspectFit
        Self.shadow(logoView, opacity: 0.5, radius: 22, y: 4)
        logoSlot.addSubview(logoView)

        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.6
        detailLabel.font = .systemFont(ofSize: 34, weight: .semibold)
        detailLabel.textColor = .white
        detailLabel.numberOfLines = 2
        synopsisLabel.numberOfLines = 3
        synopsisLabel.lineBreakMode = .byTruncatingTail
        for label in [titleLabel, detailLabel, synopsisLabel, timeLabel] {
            Self.shadow(label, opacity: 0.35, radius: 12, y: 2)
        }

        miniTrack.backgroundColor = UIColor(white: 1, alpha: 0.26)
        miniTrack.layer.cornerRadius = Metrics.miniBar.height / 2
        miniTrack.clipsToBounds = true
        miniFill.backgroundColor = .white
        miniFill.layer.cornerRadius = Metrics.miniBar.height / 2
        miniTrack.addSubview(miniFill)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 26, weight: .medium)
        timeLabel.textColor = UIColor(white: 1, alpha: 0.9)
        timeRow.axis = .horizontal
        timeRow.alignment = .center
        timeRow.spacing = 22
        timeRow.addArrangedSubview(miniTrack)
        timeRow.addArrangedSubview(timeLabel)

        infoStack.axis = .vertical
        infoStack.alignment = .fill
        infoStack.spacing = Metrics.lineGap
        for view in [logoSlot, titleLabel, detailLabel, synopsisLabel, timeRow] { infoStack.addArrangedSubview(view) }
        infoStack.setCustomSpacing(Metrics.logoGap, after: logoSlot)
        infoStack.setCustomSpacing(Metrics.logoGap, after: titleLabel)

        infoContainer.addSubview(cardView)
        infoContainer.addSubview(infoStack)

        for view in [clockLabel, infoContainer] { addSubview(view) }
        for view in [clockLabel, infoContainer, cardView, infoStack, logoView, miniFill] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }

        infoBottom = infoContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.infoBottom)
        stackInsets = [
            infoStack.topAnchor.constraint(equalTo: infoContainer.topAnchor),
            infoStack.leadingAnchor.constraint(equalTo: infoContainer.leadingAnchor),
            infoStack.trailingAnchor.constraint(equalTo: infoContainer.trailingAnchor),
            infoStack.bottomAnchor.constraint(equalTo: infoContainer.bottomAnchor),
        ]
        infoWidth = infoStack.widthAnchor.constraint(equalToConstant: Metrics.infoWidth)
        logoWidth = logoView.widthAnchor.constraint(equalToConstant: 0)
        logoHeight = logoView.heightAnchor.constraint(equalToConstant: 0)
        miniFillWidth = miniFill.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate(stackInsets + [
            clockLabel.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.clockTop),
            clockLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.margin),

            infoContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.margin),
            infoBottom,
            infoWidth,
            cardView.topAnchor.constraint(equalTo: infoContainer.topAnchor),
            cardView.leadingAnchor.constraint(equalTo: infoContainer.leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: infoContainer.trailingAnchor),
            cardView.bottomAnchor.constraint(equalTo: infoContainer.bottomAnchor),

            logoView.leadingAnchor.constraint(equalTo: logoSlot.leadingAnchor),
            logoView.topAnchor.constraint(equalTo: logoSlot.topAnchor),
            logoView.bottomAnchor.constraint(equalTo: logoSlot.bottomAnchor),
            logoWidth,
            logoHeight,

            miniTrack.widthAnchor.constraint(equalToConstant: Metrics.miniBar.width),
            miniTrack.heightAnchor.constraint(equalToConstant: Metrics.miniBar.height),
            miniFill.leadingAnchor.constraint(equalTo: miniTrack.leadingAnchor),
            miniFill.topAnchor.constraint(equalTo: miniTrack.topAnchor),
            miniFill.bottomAnchor.constraint(equalTo: miniTrack.bottomAnchor),
            miniFillWidth,
        ])
        miniTrack.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
}

extension CALayer {
    /// Drops the in-flight animations of `transform`, whatever keys UIKit gave them.
    func removeTransformAnimations() {
        for key in animationKeys() ?? [] where key.hasPrefix("transform") { removeAnimation(forKey: key) }
    }
}

/// The pause screen's scrim, the mock's: black from the left and from the bottom
/// behind the text, and a faint corner behind the clock.
private final class PauseScrimView: UIView {
    private let layers: [CAGradientLayer]

    override init(frame: CGRect) {
        let corner = CAGradientLayer()
        corner.type = .radial
        // An ellipse 120% wide and 90% tall around the top-right corner.
        corner.startPoint = CGPoint(x: 1, y: 0)
        corner.endPoint = CGPoint(x: 2.2, y: 0.9)
        corner.colors = [UIColor.black.withAlphaComponent(0.34).cgColor, UIColor.black.withAlphaComponent(0).cgColor]
        corner.locations = [0, 0.36]

        let left = CAGradientLayer()
        left.startPoint = CGPoint(x: 0, y: 0.5)
        left.endPoint = CGPoint(x: 1, y: 0.5)
        left.colors = [0.70, 0.40, 0].map { UIColor.black.withAlphaComponent($0).cgColor }
        left.locations = [0, 0.33, 0.62]

        let bottom = CAGradientLayer()
        bottom.startPoint = CGPoint(x: 0.5, y: 1)
        bottom.endPoint = CGPoint(x: 0.5, y: 0)
        bottom.colors = [0.84, 0.44, 0].map { UIColor.black.withAlphaComponent($0).cgColor }
        bottom.locations = [0, 0.30, 0.60]

        layers = [corner, left, bottom]
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layers.forEach { layer.addSublayer($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layers.forEach { $0.frame = bounds }
        CATransaction.commit()
    }
}
