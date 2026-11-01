// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// The hero's four buttons: Play, Watchlist, Info, Next.
// Unfocused: white 20% fill, UIGlassEffect, 0.5pt stroke. Focused: solid white, 10 pt growth.
// Pressed: -5% scale. Springs: focus (0.25, 0.8), press (0.15, 0.9).

import UIKit

@MainActor
final class HeroButtonRowView: UIView {

    enum HeroButton {
        case play, watchlist, info, next
    }

    // MARK: - Buttons

    let playButton = HeroPillButton()
    let watchlistButton = HeroCircleButton()
    let infoButton = HeroCircleButton()
    let nextButton = HeroCircleButton()

    private let stack = UIStackView()

    // MARK: - State

    var canAdvance: Bool = false {
        didSet {
            nextButton.isHidden = !canAdvance
        }
    }

    var isOnWatchlist: Bool = false {
        didSet {
            // Match the UIKit carousel/detail chrome: plus to add, filled
            // bookmark when already on the watchlist.
            let name = isOnWatchlist ? "bookmark.fill" : "plus"
            watchlistButton.setImage(UIImage(systemName: name), for: .normal)
            if primaryAction == .watchlist { renderPrimaryAction() }
        }
    }

    /// What the primary pill does. `.play` is the default (provider-backed
    /// items). `.watchlist` is for metadata-only items (TMDB/Discover) with
    /// no playback route: the pill becomes the watchlist toggle and the
    /// (now redundant) watchlist circle hides.
    enum PrimaryAction { case play, watchlist }

    var primaryAction: PrimaryAction = .play {
        didSet {
            guard primaryAction != oldValue else { return }
            renderPrimaryAction()
        }
    }

    private func renderPrimaryAction() {
        switch primaryAction {
        case .play:
            playButton.title = "Play"
            playButton.iconImage = UIImage(systemName: "play.fill")
            playButton.accessibilityLabel = "Play"
            watchlistButton.isHidden = false
        case .watchlist:
            playButton.title = "Watchlist"
            playButton.iconImage = UIImage(systemName: isOnWatchlist ? "bookmark.fill" : "bookmark")
            playButton.accessibilityLabel = "Toggle Watchlist"
            watchlistButton.isHidden = true
        }
    }

    // MARK: - Callbacks

    var onPlay: (() -> Void)?
    var onWatchlist: (() -> Void)?
    var onInfo: (() -> Void)?
    var onNext: (() -> Void)?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        playButton.title = "Play"
        playButton.iconImage = UIImage(systemName: "play.fill")
        watchlistButton.setImage(UIImage(systemName: "plus"), for: .normal)
        infoButton.setImage(UIImage(systemName: "info.circle"), for: .normal)
        nextButton.setImage(UIImage(systemName: "chevron.right"), for: .normal)

        playButton.accessibilityLabel = "Play"
        watchlistButton.accessibilityLabel = "Toggle Watchlist"
        infoButton.accessibilityLabel = "More info"
        nextButton.accessibilityLabel = "Next featured item"

        playButton.addTarget(self, action: #selector(playTapped), for: .primaryActionTriggered)
        watchlistButton.addTarget(self, action: #selector(watchlistTapped), for: .primaryActionTriggered)
        infoButton.addTarget(self, action: #selector(infoTapped), for: .primaryActionTriggered)
        nextButton.addTarget(self, action: #selector(nextTapped), for: .primaryActionTriggered)

        stack.axis = .horizontal
        stack.spacing = HeroPillButton.rowGap
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(playButton)
        stack.addArrangedSubview(watchlistButton)
        stack.addArrangedSubview(infoButton)
        stack.addArrangedSubview(nextButton)
        nextButton.isHidden = true
        // Gated until focus actually enters the hero, so a directional entry
        // from the rows can only land on Play.
        setSecondaryButtonsFocusable(false)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Focus

    override var canBecomeFocused: Bool { false }

    /// Default focus target is Play; if Play is hidden (never, but defensive)
    /// fall back to Watchlist.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if !playButton.isHidden { return [playButton] }
        if !watchlistButton.isHidden { return [watchlistButton] }
        return super.preferredFocusEnvironments
    }

    /// Land-on-Play gate: `preferredFocusEnvironments` does not redirect a directional entry, so
    /// the secondary buttons stay unfocusable until focus is inside the hero.
    func setSecondaryButtonsFocusable(_ on: Bool) {
        watchlistButton.isFocusEnabled = on
        infoButton.isFocusEnabled = on
        nextButton.isFocusEnabled = on
    }

    // MARK: - Targets

    @objc private func playTapped() {
        switch primaryAction {
        case .play: onPlay?()
        case .watchlist: onWatchlist?()
        }
    }
    @objc private func watchlistTapped() { onWatchlist?() }
    @objc private func infoTapped() { onInfo?() }
    @objc private func nextTapped() { onNext?() }
}

// MARK: - Pill button (Play)

/// 66pt-tall pill button with an SF Symbol icon + label.
@MainActor
final class HeroPillButton: UIControl {

    /// Pill metrics shared with the carousel/detail action row's
    /// `FocusableActionButton` pills (see `MediaDetailChromeView`) so the
    /// hero and carousel present identical buttons. The label, padding, gap
    /// and focus growth are Apple's; the width is a floor a longer title
    /// ("Resume S1, E3") grows past.
    static let pillWidth: CGFloat = 220
    static let buttonHeight: CGFloat = 66
    static let sidePadding: CGFloat = 39
    static let iconGap: CGFloat = 14
    static let rowGap: CGFloat = 24
    static let titleFont = UIFont.systemFont(ofSize: 29, weight: .semibold)
    /// Apple grows a focused button by 10 pt of width; on the pill that is 1.045.
    static let focusScale: CGFloat = (pillWidth + 10) / pillWidth
    /// Circles grow 66 -> 76 on focus (measured on device, tvOS 27).
    static let circleFocusScale: CGFloat = 76.0 / 66.0

    var title: String = "" {
        didSet { titleLabel.text = title }
    }

    var iconImage: UIImage? {
        didSet {
            iconView.image = iconImage?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold))
        }
    }

    private let background = UIView()
    /// Real Liquid Glass material, the second background under the solid
    /// fill (it shows through when unfocused, fades out on focus).
    private let materialBackground = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let strokeLayer = CAShapeLayer()
    private let contentStack = UIStackView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()

    private let cornerRadius: CGFloat = 33  // height/2 (height=66)

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = false

        background.translatesAutoresizingMaskIntoConstraints = false
        background.layer.cornerRadius = cornerRadius
        background.layer.cornerCurve = .continuous
        background.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        background.isUserInteractionEnabled = false
        addSubview(background)

        materialBackground.translatesAutoresizingMaskIntoConstraints = false
        materialBackground.layer.cornerRadius = cornerRadius
        materialBackground.layer.cornerCurve = .continuous
        materialBackground.clipsToBounds = true
        materialBackground.isUserInteractionEnabled = false
        addSubview(materialBackground)

        strokeLayer.fillColor = UIColor.clear.cgColor
        strokeLayer.strokeColor = UIColor.white.withAlphaComponent(0.2).cgColor
        strokeLayer.lineWidth = 0.5
        layer.addSublayer(strokeLayer)

        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit

        titleLabel.text = title
        titleLabel.font = Self.titleFont
        titleLabel.textColor = .white

        contentStack.axis = .horizontal
        contentStack.spacing = Self.iconGap
        contentStack.alignment = .center
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.isUserInteractionEnabled = false
        contentStack.addArrangedSubview(iconView)
        contentStack.addArrangedSubview(titleLabel)
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: Self.pillWidth),
            {
                let c = widthAnchor.constraint(equalToConstant: Self.pillWidth)
                c.priority = .defaultLow
                return c
            }(),
            heightAnchor.constraint(equalToConstant: Self.buttonHeight),

            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),

            materialBackground.topAnchor.constraint(equalTo: topAnchor),
            materialBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
            materialBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialBackground.trailingAnchor.constraint(equalTo: trailingAnchor),

            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Self.sidePadding),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.sidePadding),
            contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),

            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        strokeLayer.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25),
                                        cornerRadius: cornerRadius).cgPath
        strokeLayer.frame = bounds
    }

    // MARK: - Focus

    /// Focus gate: false removes the button from focus candidacy entirely
    /// (see HeroButtonRowView.setSecondaryButtonsFocusable). Play is never
    /// gated; the secondary circles are gated while focus is outside the hero.
    var isFocusEnabled = true

    override var canBecomeFocused: Bool { isFocusEnabled }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let nowFocused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations { [self] in
            applyFocusVisuals(focused: nowFocused)
        }
    }

    private func applyFocusVisuals(focused: Bool) {
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8,
                       initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.transform = focused
                ? CGAffineTransform(scaleX: HeroPillButton.focusScale, y: HeroPillButton.focusScale) : .identity
            self.background.backgroundColor = focused ? .white : UIColor.white.withAlphaComponent(0.2)
            self.materialBackground.alpha = focused ? 0 : 1
            self.strokeLayer.opacity = focused ? 0 : 1
            self.titleLabel.textColor = focused ? .black : .white
            self.iconView.tintColor = focused ? .black : .white
        }
    }

    // MARK: - Press feedback

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesBegan(presses, with: event)
        for p in presses where p.type == .select {
            UIView.animate(withDuration: 0.15, delay: 0, usingSpringWithDamping: 0.9,
                           initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                let scale = 0.95 * (self.isFocused ? HeroPillButton.focusScale : 1.0)
                self.transform = CGAffineTransform(scaleX: scale, y: scale)
            }
            return
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(presses, with: event)
        for p in presses where p.type == .select {
            applyFocusVisuals(focused: isFocused)
            sendActions(for: .primaryActionTriggered)
            return
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesCancelled(presses, with: event)
        applyFocusVisuals(focused: isFocused)
    }
}

// MARK: - Circle button (Watchlist / Info / Next)

/// 66×66pt circular button with a single SF Symbol. Same focus visuals as
/// `HeroPillButton` but no label.
@MainActor
final class HeroCircleButton: UIControl {

    private let background = UIView()
    private let materialBackground = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let strokeLayer = CAShapeLayer()
    private let iconView = UIImageView()

    private let cornerRadius: CGFloat = 33

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = false

        background.translatesAutoresizingMaskIntoConstraints = false
        background.layer.cornerRadius = cornerRadius
        background.layer.cornerCurve = .continuous
        background.backgroundColor = .clear
        background.isUserInteractionEnabled = false
        addSubview(background)

        materialBackground.translatesAutoresizingMaskIntoConstraints = false
        materialBackground.layer.cornerRadius = cornerRadius
        materialBackground.layer.cornerCurve = .continuous
        materialBackground.clipsToBounds = true
        materialBackground.isUserInteractionEnabled = false
        addSubview(materialBackground)

        strokeLayer.fillColor = UIColor.clear.cgColor
        strokeLayer.strokeColor = UIColor.white.withAlphaComponent(0.12).cgColor
        strokeLayer.lineWidth = 1
        layer.addSublayer(strokeLayer)

        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.isUserInteractionEnabled = false
        addSubview(iconView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 66),
            heightAnchor.constraint(equalToConstant: 66),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            materialBackground.topAnchor.constraint(equalTo: topAnchor),
            materialBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
            materialBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        strokeLayer.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25),
                                        cornerRadius: cornerRadius).cgPath
        strokeLayer.frame = bounds
    }

    func setImage(_ image: UIImage?, for state: UIControl.State) {
        iconView.image = image?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold))
    }

    // MARK: - Focus

    /// Focus gate: false removes the button from focus candidacy entirely
    /// (see HeroButtonRowView.setSecondaryButtonsFocusable). Play is never
    /// gated; the secondary circles are gated while focus is outside the hero.
    var isFocusEnabled = true

    override var canBecomeFocused: Bool { isFocusEnabled }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let nowFocused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations { [self] in
            applyFocusVisuals(focused: nowFocused)
        }
    }

    private func applyFocusVisuals(focused: Bool) {
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8,
                       initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            let grow = HeroPillButton.circleFocusScale
            self.transform = focused ? CGAffineTransform(scaleX: grow, y: grow) : .identity
            self.background.backgroundColor = focused ? .white : .clear
            self.materialBackground.alpha = focused ? 0 : 1
            self.strokeLayer.opacity = focused ? 0 : 1
            self.iconView.tintColor = focused ? .black : .white
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesBegan(presses, with: event)
        for p in presses where p.type == .select {
            UIView.animate(withDuration: 0.15, delay: 0, usingSpringWithDamping: 0.9,
                           initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                let scale = 0.95 * (self.isFocused ? HeroPillButton.circleFocusScale : 1.0)
                self.transform = CGAffineTransform(scaleX: scale, y: scale)
            }
            return
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(presses, with: event)
        for p in presses where p.type == .select {
            applyFocusVisuals(focused: isFocused)
            sendActions(for: .primaryActionTriggered)
            return
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesCancelled(presses, with: event)
        applyFocusVisuals(focused: isFocused)
    }
}

// MARK: - Paging dots

/// The hero's page dots. The active dot is a pill that fills while the
/// auto-advance timer runs, so the viewer can see the page is about to change
/// (Apple's `UIPageControlTimerProgress` look).
@MainActor
final class HeroPagingDotsView: UIView {
    private final class Dot: UIView {
        let fill = CALayer()
        override init(frame: CGRect) {
            super.init(frame: frame)
            translatesAutoresizingMaskIntoConstraints = false
            backgroundColor = UIColor.white.withAlphaComponent(0.25)
            layer.cornerRadius = 4
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
            fill.backgroundColor = UIColor.white.cgColor
            fill.anchorPoint = CGPoint(x: 0, y: 0.5)
            fill.isHidden = true
            layer.addSublayer(fill)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fill.bounds = bounds
            fill.position = CGPoint(x: 0, y: bounds.midY)
            CATransaction.commit()
        }
    }

    private let stack = UIStackView()
    private var dots: [Dot] = []
    private var activeIndex = -1
    static let activeWidth: CGFloat = 30, dotSize: CGFloat = 8

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 13
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(count: Int, activeIndex: Int) {
        if dots.count != count {
            dots.forEach { $0.removeFromSuperview() }
            dots = (0..<count).map { _ in
                let dot = Dot()
                stack.addArrangedSubview(dot)
                dot.heightAnchor.constraint(equalToConstant: Self.dotSize).isActive = true
                return dot
            }
            self.activeIndex = -1
        }
        guard activeIndex != self.activeIndex else { return }
        self.activeIndex = activeIndex
        for (i, dot) in dots.enumerated() where i != activeIndex {
            dot.fill.removeAllAnimations()
            dot.fill.isHidden = true
        }
        if dots.indices.contains(activeIndex) { setProgress(duration: nil) }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut]) {
            for (i, dot) in self.dots.enumerated() {
                dot.constraints.filter { $0.firstAttribute == .width }.forEach(dot.removeConstraint)
                dot.widthAnchor.constraint(equalToConstant: i == activeIndex ? Self.activeWidth : Self.dotSize).isActive = true
            }
            self.layoutIfNeeded()
        }
    }

    /// Fills the active pill over `duration`; nil shows it full (timer off).
    func setProgress(duration: TimeInterval?) {
        guard dots.indices.contains(activeIndex) else { return }
        let fill = dots[activeIndex].fill
        fill.removeAllAnimations()
        fill.isHidden = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.transform = CATransform3DIdentity
        CATransaction.commit()
        guard let duration else { return }
        let grow = CABasicAnimation(keyPath: "transform.scale.x")
        grow.fromValue = 0
        grow.toValue = 1
        grow.duration = duration
        fill.add(grow, forKey: "progress")
    }
}
