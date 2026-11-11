// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PauseScreenView.swift
//  Rivulet
//
//  The pause screen: after 10 s paused the player says what is paused and how long
//  is left, over the paused picture (which the container pushes in); at 30 s the
//  title's art crossfades in under the details; at 2 min it settles into a dimmer,
//  quieter state (an OLED burn-in guard).
//
//  Plain UIKit, non-interactive and focusless. `PlayerContainerViewController`
//  mounts it above the video and captions and below the content focus anchor, and
//  drives it from `applyPauseScreen`, its single writer. Sizes are points on the
//  1920x1080 screen, measured from the design mock.
//

import UIKit

final class PauseScreenView: UIView {

    /// The paused tiers (`UniversalPlayerViewModel.PausePresentation` past `.frame`).
    enum Tier { case info, art, dimmed }

    struct Content {
        var title: String
        var logo: UIImage?
        var detailLine: String?
        var synopsis: String?
        /// Full-resolution backdrop: the picture from 30 s, and while no frame exists.
        var artURL: URL?
        /// Down opens Insights, so the screen says so.
        var insightsAvailable = false
    }

    private enum Metrics {
        static let margin: CGFloat = 80
        static let infoBottom: CGFloat = 92
        static let infoWidth: CGFloat = 860
        static let synopsisLines = 5
        static let lineGap: CGFloat = 22
        static let logoGap: CGFloat = 30
        static let logoBox = CGSize(width: 640, height: 120)
        static let dimmedLogoBox = CGSize(width: 520, height: 96)
        static let clockTop: CGFloat = 58
        static let miniBar = CGSize(width: 220, height: 6)
        static let dim: CGFloat = 0.34
        static let dimmedScrim: CGFloat = 0.85
        static let drift: (from: CGFloat, to: CGFloat) = (1.04, 1.08)
        static let driftDuration: TimeInterval = 60
        static let stagger: TimeInterval = 0.12
        static let rise: CGFloat = 16
    }

    /// Position and duration, read on show and on each minute tick ("Ends at" moves with the clock).
    var progress: () -> (position: TimeInterval, duration: TimeInterval) = { (0, 0) }

    /// The picture treatment's fade in, spanning the info lines' staggered entrance;
    /// the container fades its paused dim out on the same clock.
    static let fadeDuration: TimeInterval = 1.5

    private(set) var isShowing = false
    private var tier: Tier = .info
    /// Insights is raised over the screen: the info block and hint make way.
    private var panelUp = false
    private var parked = false
    private var content = Content(title: "")

    // Picture layers, bottom-up.
    private let artView = UIImageView()
    /// The 2 min tier's dim.
    private let dimView = UIView()
    private let scrimView = PauseScrimView()

    private let clockLabel = UILabel()
    private let insightsHint = UIStackView()

    // Info block, bottom left.
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
    func show(content: Content, tier: Tier, parked: Bool) {
        isShowing = true
        panelUp = false
        infoStack.alpha = 1
        self.tier = tier
        self.parked = parked
        self.content = content
        // A hide still fading out ends here; its completion sees `isShowing` and stands down.
        stopDrift()
        isHidden = false

        artView.transform = .identity
        configureContent()
        loadArt()
        refreshTime()
        startTimers()

        // Start from nothing, without animation.
        UIView.performWithoutAnimation {
            for view in [artView, dimView, scrimView, clockLabel] { view.alpha = 0 }
            applyLayout()
            for view in infoLines {
                view.alpha = 0
                view.transform = CGAffineTransform(translationX: 0, y: Metrics.rise)
            }
            layoutIfNeeded()
        }

        UIView.animate(withDuration: Self.fadeDuration, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.applyPicture()
            self.clockLabel.alpha = 1
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

    /// The 30 s and 2 min tiers, or the frame going away under a sleep (parked).
    func update(tier: Tier, parked: Bool) {
        guard isShowing, tier != self.tier || parked != self.parked else { return }
        self.tier = tier
        self.parked = parked
        UIView.animate(withDuration: 1.2, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.applyLayout()
            self.applyPicture()
            for view in [self.detailLabel, self.synopsisLabel, self.insightsHint] { view.alpha = view.isHidden ? 0 : 1 }
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

    func setInsightsAvailable(_ available: Bool) {
        guard isShowing, content.insightsAvailable != available else { return }
        content.insightsAvailable = available
        UIView.animate(withDuration: 0.4, delay: 0, options: [.beginFromCurrentState]) {
            self.applyLayout()
            self.insightsHint.alpha = self.insightsHint.isHidden ? 0 : 1
        }
    }

    func setPanelUp(_ up: Bool) {
        guard isShowing, panelUp != up else { return }
        panelUp = up
        UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState]) {
            self.applyLayout()
            self.infoStack.alpha = up ? 0 : 1
            self.insightsHint.alpha = self.insightsHint.isHidden ? 0 : 1
        }
    }

    /// Whether Down goes to Insights: the hint is on screen.
    var showsInsightsHint: Bool { isShowing && !insightsHint.isHidden }

    /// Fades everything out (the picture's own push-in is the container's).
    func hide() {
        guard isShowing else { return }
        isShowing = false
        stopTimers()
        artTask?.cancel()
        artTask = nil
        UIView.animate(withDuration: 0.5, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            for view in [self.artView, self.dimView, self.scrimView, self.clockLabel] {
                view.alpha = 0
            }
            for view in self.infoLines { view.alpha = 0 }
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

    private var infoLines: [UIView] { [logoSlot, titleLabel, detailLabel, synopsisLabel, timeRow, insightsHint] }

    /// The art from 30 s, and while no frame exists.
    private var showsArt: Bool {
        artView.image != nil && (parked || tier != .info)
    }

    /// Alphas of the picture layers for the current state. Inside an animation block.
    private func applyPicture() {
        artView.alpha = showsArt ? 1 : 0
        dimView.alpha = tier == .dimmed ? Metrics.dim : 0
        scrimView.alpha = tier == .dimmed ? Metrics.dimmedScrim : 1
        if showsArt { startDrift() } else { stopDrift() }
    }

    /// Which info lines show and how large the logo sits. Inside an animation block.
    private func applyLayout() {
        let dimmed = tier == .dimmed
        detailLabel.isHidden = dimmed || content.detailLine == nil
        synopsisLabel.isHidden = dimmed || content.synopsis == nil
        insightsHint.isHidden = dimmed || panelUp || !content.insightsAvailable
        fitLogo(in: dimmed ? Metrics.dimmedLogoBox : Metrics.logoBox)
        titleLabel.font = .systemFont(ofSize: dimmed ? 60 : 72, weight: .bold)
    }

    // MARK: - Configuration

    private func configureContent() {
        configureTitle()
        detailLabel.text = content.detailLine
        synopsisLabel.attributedText = content.synopsis.map { synopsis in
            let fitted = PauseScreenText.fittedSynopsis(synopsis) { Self.synopsisFits(Self.synopsisText($0)) }
            return Self.synopsisText(fitted)
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

    /// A slow drift on the art, as on the Apple TV app's screensaver stills.
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

    private static func synopsisText(_ string: String) -> NSAttributedString {
        text(string, size: 28, weight: .regular, color: UIColor(white: 1, alpha: 0.82), lineHeight: 40)
    }

    /// Whether `text` sets in `Metrics.synopsisLines` lines of the info column.
    private static func synopsisFits(_ text: NSAttributedString) -> Bool {
        let limit = synopsisText(Array(repeating: "M", count: Metrics.synopsisLines).joined(separator: "\n"))
        func height(_ string: NSAttributedString) -> CGFloat {
            string.boundingRect(with: CGSize(width: Metrics.infoWidth, height: .greatestFiniteMagnitude),
                                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
        }
        return height(text) <= height(limit) + 1
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
        dimView.backgroundColor = .black

        for view in [artView, dimView, scrimView] {
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.isUserInteractionEnabled = false
            addSubview(view)
        }

        clockLabel.font = .monospacedDigitSystemFont(ofSize: 30, weight: .semibold)
        clockLabel.textColor = UIColor(white: 1, alpha: 0.9)
        Self.shadow(clockLabel, opacity: 0.45, radius: 14, y: 2)

        // Down for Insights, beside the time row's baseline.
        let hintFont = UIFont.systemFont(ofSize: 24, weight: .semibold)
        let hintGlyph = UIImageView(image: UIImage(systemName: "chevron.down",
                                                   withConfiguration: UIImage.SymbolConfiguration(font: hintFont)))
        let hintLabel = UILabel()
        hintLabel.text = String(localized: "Insights")
        hintLabel.font = hintFont
        for view in [hintGlyph, hintLabel] as [UIView] {
            view.tintColor = UIColor(white: 1, alpha: 0.7)
            Self.shadow(view, opacity: 0.35, radius: 12, y: 2)
        }
        hintLabel.textColor = UIColor(white: 1, alpha: 0.7)
        insightsHint.axis = .horizontal
        insightsHint.alignment = .center
        insightsHint.spacing = 10
        insightsHint.addArrangedSubview(hintGlyph)
        insightsHint.addArrangedSubview(hintLabel)

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
        synopsisLabel.numberOfLines = Metrics.synopsisLines
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

        for view in [clockLabel, infoStack, insightsHint] { addSubview(view) }
        for view in [clockLabel, infoStack, insightsHint, logoView, miniFill] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        for label in [titleLabel, detailLabel, synopsisLabel, timeLabel] {
            label.preferredMaxLayoutWidth = Metrics.infoWidth
        }

        logoWidth = logoView.widthAnchor.constraint(equalToConstant: 0)
        logoHeight = logoView.heightAnchor.constraint(equalToConstant: 0)
        miniFillWidth = miniFill.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            clockLabel.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.clockTop),
            clockLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.margin),

            infoStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.margin),
            infoStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.infoBottom),
            infoStack.widthAnchor.constraint(equalToConstant: Metrics.infoWidth),
            insightsHint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.margin),
            insightsHint.centerYAnchor.constraint(equalTo: timeRow.centerYAnchor),

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
