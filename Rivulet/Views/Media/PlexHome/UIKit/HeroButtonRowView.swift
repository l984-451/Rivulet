// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// The hero's four buttons: Play, Watchlist, Info, Next.
// Unfocused: dark glass, faint stroke. Focused: solid white, 10 pt growth.
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
    /// A bare chevron at rest, as the TV app draws it; the platter shows on focus only.
    let nextButton = HeroCircleButton(restingPlatter: false)

    private let stack = UIStackView()

    /// Swipes at either end of the button row page without changing focus.
    private var pageSwipe: DirectionalInputBinding?

    // MARK: - State

    var canAdvance: Bool = false {
        didSet {
            nextButton.isHidden = !canAdvance
            pastNextCatcher.isHidden = !canAdvance
        }
    }

    /// Gives the engine a Right to ask for from Next, so a long swipe can carry past it
    /// (`passesNext`), as the shell's edge catcher does left of Play. A real focusable view:
    /// a focus guide here was never asked. Focusable only while Next holds focus, and every
    /// move into it is refused, so focus never lands here.
    private final class PastNextCatcher: UIView {
        weak var button: UIView?
        override var canBecomeFocused: Bool { button?.isFocused == true }
    }
    private let pastNextCatcher = PastNextCatcher()
    private var nextPageGesture: Int?

    var canRetreat = false
    private var previousPageGesture: Int?

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
            playButton.title = String(localized: "Play")
            playButton.iconImage = UIImage(systemName: "play.fill")
            playButton.accessibilityLabel = String(localized: "Play")
            watchlistButton.isHidden = false
        case .watchlist:
            playButton.title = String(localized: "Watchlist")
            playButton.iconImage = UIImage(systemName: isOnWatchlist ? "bookmark.fill" : "bookmark")
            playButton.accessibilityLabel = String(localized: "Toggle Watchlist")
            watchlistButton.isHidden = true
        }
    }

    // MARK: - Callbacks

    var onPlay: (() -> Void)?
    var onWatchlist: (() -> Void)?
    var onInfo: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        playButton.title = String(localized: "Play")
        playButton.iconImage = UIImage(systemName: "play.fill")
        watchlistButton.setImage(UIImage(systemName: "plus"), for: .normal)
        // Measured from the TV app: Info bold, the chevron 15 x 26 at rest.
        infoButton.setImage(UIImage(systemName: "info.circle"), for: .normal, pointSize: 30, weight: .bold)
        nextButton.setImage(UIImage(systemName: "chevron.right"), for: .normal, pointSize: 35.5)

        playButton.accessibilityLabel = String(localized: "Play")
        watchlistButton.accessibilityLabel = String(localized: "Toggle Watchlist")
        infoButton.accessibilityLabel = String(localized: "More info")
        nextButton.accessibilityLabel = String(localized: "Next featured item")

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
        pastNextCatcher.button = nextButton
        pastNextCatcher.isHidden = true
        pastNextCatcher.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pastNextCatcher)
        NSLayoutConstraint.activate([
            pastNextCatcher.leadingAnchor.constraint(equalTo: nextButton.trailingAnchor, constant: 40),
            pastNextCatcher.trailingAnchor.constraint(equalTo: trailingAnchor),
            pastNextCatcher.widthAnchor.constraint(equalToConstant: 2),
            pastNextCatcher.topAnchor.constraint(equalTo: stack.topAnchor),
            pastNextCatcher.bottomAnchor.constraint(equalTo: stack.bottomAnchor)
        ])
        pageSwipe = DirectionalInputBinding(
            gatedSwipesOn: self, directions: [.left, .right],
            shouldHandle: { [weak self] direction in
                guard let self else { return false }
                return direction == .left ? self.pagesOnLeft : self.pagesOnRight
            },
            onSwipe: { [weak self] direction in
                guard let self else { return }
                if direction == .left {
                    _ = self.consumeBackwardPaging(from: self.playButton, heading: .left,
                                                   gesture: MenuPressInterceptor.remoteGestures.count)
                } else {
                    self.onNext?()
                }
            })
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

    func setPagingVisible(_ visible: Bool, animated: Bool = true) {
        guard animated else {
            stack.layer.removeAnimation(forKey: "heroPagingOpacity")
            return
        }
        // Presentation opacity only: UIKit still sees the focus targets at full alpha.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = stack.layer.presentation()?.opacity ?? 1
        fade.toValue = visible ? 1 : 0
        fade.duration = visible ? HeroPageMotion.metadataFade : HeroPageMotion.outgoingFade
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        stack.layer.add(fade, forKey: "heroPagingOpacity")
    }

    /// The engine moves focus before the press or swipe reaches us, so the arrow
    /// that landed on Play or Next must not also page. Only a later gesture does.
    private var arrivalGesture: Int?
    private var arrivedThisGesture: Bool { arrivalGesture == MenuPressInterceptor.remoteGestures.count }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if let next = context.nextFocusedItem, next === playButton || next === nextButton,
           next !== context.previouslyFocusedItem {
            let row: [UIControl] = [playButton, watchlistButton, infoButton, nextButton]
            let fromRow = row.contains { $0 === context.previouslyFocusedItem }
            noteArrival(gesture: MenuPressInterceptor.remoteGestures.count, fromRow: fromRow)
        }
    }

    /// The gesture that walked focus along the row onto Play or Next (not one that came up from the shelves).
    private var rowArrivalGesture: Int?

    func noteArrival(gesture: Int, fromRow: Bool) {
        arrivalGesture = gesture
        rowArrivalGesture = fromRow ? gesture : nil
    }

    /// Left from Play while earlier items exist, or in the gesture that arrived or paged, never
    /// reaches the sidebar. At the first item a fresh gesture falls through and opens it.
    /// A swipe that keeps travelling after it lands on Play passes it and pages back.
    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        if context.previouslyFocusedItem === playButton, context.focusHeading == .left {
            let gesture = MenuPressInterceptor.remoteGestures.count
            if passesPlay(gesture: gesture) {
                // Not from inside the engine's query: paging rebuilds the row.
                DispatchQueue.main.async { [weak self] in self?.onPrevious?() }
                return false
            }
            if canRetreat || arrivedThisGesture || previousPageGesture == gesture { return false }
        }
        if context.nextFocusedItem === pastNextCatcher {
            if context.previouslyFocusedItem === nextButton, context.focusHeading == .right,
               passesNext(gesture: MenuPressInterceptor.remoteGestures.count) {
                DispatchQueue.main.async { [weak self] in self?.onNext?() }
            }
            return false
        }
        return super.shouldUpdateFocus(in: context)
    }

    /// `passesPlay`'s mirror: the swipe that walked onto Next and keeps going pages forward, once.
    func passesNext(gesture: Int) -> Bool {
        guard canAdvance, rowArrivalGesture == gesture, nextPageGesture != gesture else { return false }
        nextPageGesture = gesture
        return true
    }

    /// The TV app's long swipe: the gesture that landed on Play asks the engine for another Left,
    /// so it carries past Play to the previous item. A short swipe that stops on Play never asks.
    /// Still one page per gesture.
    func passesPlay(gesture: Int) -> Bool {
        guard canRetreat, rowArrivalGesture == gesture, previousPageGesture != gesture else { return false }
        previousPageGesture = gesture
        return true
    }

    /// Pages back once per gesture; the rest of that gesture is consumed, even at the first item.
    func consumeBackwardPaging(from item: (any UIFocusItem)?, heading: UIFocusHeading, gesture: Int) -> Bool {
        guard item === playButton, heading == .left else { return false }
        if previousPageGesture == gesture { return true }
        guard canRetreat else { return false }
        previousPageGesture = gesture
        onPrevious?()
        return true
    }

    private var pagesOnLeft: Bool { playButton.isFocused && canRetreat && !arrivedThisGesture }

    /// Next is the last button, so the engine has no Right move from it to make.
    private var pagesOnRight: Bool { nextButton.isFocused && !nextButton.isHidden && !arrivedThisGesture }

    // A Left or Right the engine declined (nothing to move to) reaches here; focus stays put.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if pagesOnLeft, presses.contains(where: { $0.type == .leftArrow }),
           consumeBackwardPaging(from: playButton, heading: .left,
                                 gesture: MenuPressInterceptor.remoteGestures.count) { return }
        if pagesOnRight, presses.contains(where: { $0.type == .rightArrow }) {
            onNext?()
            return
        }
        super.pressesBegan(presses, with: event)
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
    /// The TV app's play glyph, about 23 x 26 at rest (measured on device).
    static let iconSize: CGFloat = 30
    /// Apple grows a focused button by 10 pt of width; on the pill that is 1.045.
    static let focusScale: CGFloat = (pillWidth + 10) / pillWidth
    /// Circles grow 66 -> 76 on focus (measured on device, tvOS 27).
    static let circleFocusScale: CGFloat = 76.0 / 66.0
    /// Resting edge for every hero button: 1 pt at 0.12 white on the circles (measured on device).
    static let restingStroke = UIColor.white.withAlphaComponent(0.12)
    /// Resting glass for every hero button: the clear (more see-through) glass with a dark
    /// tint, so the buttons stay as dark as the regular glass while showing more of the art.
    static func restingGlass() -> UIGlassEffect {
        let glass = UIGlassEffect(style: .clear)
        glass.tintColor = UIColor.black.withAlphaComponent(0.3)
        return glass
    }
    /// The glass is faded to show less blur; a plain dark fill under it keeps the buttons dark.
    static let restingGlassAlpha: CGFloat = 0.5
    static let restingFill = UIColor.black.withAlphaComponent(0.3)
    /// The focused Play fill reads 229 on Apple's, not pure white.
    static let focusedFill = UIColor(white: 0.9, alpha: 1)

    var title: String = "" {
        didSet { titleLabel.text = title }
    }

    var iconImage: UIImage? {
        didSet {
            iconView.image = iconImage?.withConfiguration(UIImage.SymbolConfiguration(pointSize: Self.iconSize, weight: .semibold))
        }
    }

    private let background = UIView()
    /// Real Liquid Glass material, the second background under the solid
    /// fill (it shows through when unfocused, fades out on focus).
    private let materialBackground = UIVisualEffectView(effect: HeroPillButton.restingGlass())
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
        // Dark fill under faded glass, as on the circles.
        background.backgroundColor = Self.restingFill
        background.isUserInteractionEnabled = false
        addSubview(background)

        materialBackground.translatesAutoresizingMaskIntoConstraints = false
        materialBackground.layer.cornerRadius = cornerRadius
        materialBackground.layer.cornerCurve = .continuous
        materialBackground.clipsToBounds = true
        materialBackground.isUserInteractionEnabled = false
        addSubview(materialBackground)
        materialBackground.alpha = Self.restingGlassAlpha

        strokeLayer.fillColor = UIColor.clear.cgColor
        strokeLayer.strokeColor = Self.restingStroke.cgColor
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

            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize)
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
            self.background.backgroundColor = focused ? HeroPillButton.focusedFill : HeroPillButton.restingFill
            self.materialBackground.alpha = focused ? 0 : HeroPillButton.restingGlassAlpha
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
    private let materialBackground = UIVisualEffectView(effect: HeroPillButton.restingGlass())
    private let strokeLayer = CAShapeLayer()
    private let iconView = UIImageView()
    private lazy var iconWidth = iconView.widthAnchor.constraint(equalToConstant: 24)
    private lazy var iconHeight = iconView.heightAnchor.constraint(equalToConstant: 24)

    private let cornerRadius: CGFloat = 33
    /// False draws only the symbol at rest (the hero's Next chevron).
    private let restingPlatter: Bool
    /// Apple's bare chevron rests 12.5 pt left of the platter's centre; focus recentres it.
    private var restingIconTransform: CGAffineTransform {
        restingPlatter ? .identity : CGAffineTransform(translationX: -12.5, y: 0)
    }

    init(restingPlatter: Bool = true) {
        self.restingPlatter = restingPlatter
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = false

        background.translatesAutoresizingMaskIntoConstraints = false
        background.layer.cornerRadius = cornerRadius
        background.layer.cornerCurve = .continuous
        background.backgroundColor = restingPlatter ? HeroPillButton.restingFill : .clear
        background.isUserInteractionEnabled = false
        addSubview(background)

        materialBackground.translatesAutoresizingMaskIntoConstraints = false
        materialBackground.layer.cornerRadius = cornerRadius
        materialBackground.layer.cornerCurve = .continuous
        materialBackground.clipsToBounds = true
        materialBackground.isUserInteractionEnabled = false
        addSubview(materialBackground)

        strokeLayer.fillColor = UIColor.clear.cgColor
        strokeLayer.strokeColor = HeroPillButton.restingStroke.cgColor
        strokeLayer.lineWidth = 1
        layer.addSublayer(strokeLayer)
        materialBackground.alpha = restingPlatter ? HeroPillButton.restingGlassAlpha : 0
        strokeLayer.opacity = restingPlatter ? 1 : 0

        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.isUserInteractionEnabled = false
        iconView.transform = restingIconTransform
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
            iconWidth,
            iconHeight
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        strokeLayer.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25),
                                        cornerRadius: cornerRadius).cgPath
        strokeLayer.frame = bounds
    }

    func setImage(_ image: UIImage?, for state: UIControl.State,
                  pointSize: CGFloat = 24, weight: UIImage.SymbolWeight = .semibold) {
        iconWidth.constant = pointSize
        iconHeight.constant = pointSize
        iconView.image = image?.withConfiguration(UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
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
            self.background.backgroundColor = focused ? .white : (self.restingPlatter ? HeroPillButton.restingFill : .clear)
            self.materialBackground.alpha = focused || !self.restingPlatter ? 0 : HeroPillButton.restingGlassAlpha
            self.strokeLayer.opacity = focused || !self.restingPlatter ? 0 : 1
            self.iconView.tintColor = focused ? .black : .white
            self.iconView.transform = focused ? .identity : self.restingIconTransform
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
