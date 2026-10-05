// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerRailPanelView.swift
//  Rivulet
//
//  The one floating glass popup shared by every rail button. Cloned from
//  AVKit's tvOS 26 tool menus (`AVUnifiedPlayerContextMenuView`, measured
//  with DEBUG `AVKitScrubProbe`, RIVULET_SCRUBPROBE=menus): a 54pt-radius
//  glass platter whose bottom-right corner sits 20.5pt above its button's
//  top-right, growing out of that corner on a spring while its content
//  fades in. Menu dismisses; content owns its own internal focus.
//

import UIKit

/// Conformed to by rail-panel content that has its own internal Menu
/// handling (e.g. `InsightsPanelContainerView`'s return from an actor to
/// the cast) rather than always wanting Menu to close the whole
/// panel outright.
///
/// tvOS delivers presses to the FOCUSED view and bubbles them UP the
/// responder chain (first-responder status is irrelevant while something is
/// focused). While the panel is open its focus fence keeps focus inside it,
/// so `.menu` lands on `PlayerRailPanelView.pressesBegan` — an ancestor of
/// every focused descendant — before it could ever reach
/// `PlayerContainerViewController`. That override, and (for the
/// focus-outside-panel edge case) `handleMenuButton()`, both consult this
/// protocol first and only dismiss the whole panel if the content declines.
///
/// The content itself can't own this in its own `pressesBegan`: in states
/// where nothing inside the content is focusable, focus falls onto the
/// panel view itself, and a press delivered to the panel never visits its
/// CHILDREN — bubbling goes up, not down.
protocol RailPanelMenuHandling {
    /// Return true if this content fully handled Menu itself (e.g. animated
    /// back to a sub-list) and the panel should stay open. Return false to
    /// let the panel dismiss as normal.
    func handleMenuPress() -> Bool
}

final class PlayerRailPanelView: UIView {

    /// Height available to panel CONTENT at the panel's full size. Content that
    /// wants a constant panel (rather than one that grows and shrinks with what
    /// it happens to be showing) constrains itself to this.
    static var fullContentHeight: CGFloat { Metrics.maxHeight - Metrics.padding * 2 }

    fileprivate enum Metrics {
        static let cornerRadius: CGFloat = 54
        static let buttonGap: CGFloat = 20.5
        /// Inset for free-form content. Menus (`CardTrackListView`) fill the platter.
        static let padding: CGFloat = 20
        static let maxHeight: CGFloat = 560
        static let screenMargin: CGFloat = 80
        /// AVKit grows the platter from 10% scale on this spring, both ways.
        static let collapsedScale: CGFloat = 0.1
        static let spring = UISpringTimingParameters(mass: 1, stiffness: 200, damping: 23, initialVelocity: .zero)
        static let springDuration: TimeInterval = 0.677
        static let contentFade: TimeInterval = 0.17
        static let contentFadeCurve = UICubicTimingParameters(
            controlPoint1: CGPoint(x: 0.33, y: 0), controlPoint2: CGPoint(x: 0.67, y: 1))
        // AVKit's info pane: a 1760-wide area whose bottom sits 50pt above the
        // screen's, 30pt below the risen pills; content starts 14pt down.
        static let paneBottomInset: CGFloat = 50
        static let paneHeight: CGFloat = 300
        static let paneContentTop: CGFloat = 14
        static let panePillGap: CGFloat = 30
        static let paneCardRadius: CGFloat = 48
    }

    var onDismiss: (() -> Void)?

    /// Fired whenever this panel consumes a `.menu` press (whether the
    /// content handled it internally or the panel dismissed). tvOS ALSO
    /// processes Menu through a system gesture recognizer that races
    /// responder-chain consumption and calls `dismiss(animated:)` on the
    /// presenting VC — the host uses this hook to arm its block-next-dismiss
    /// guard so that system echo doesn't peel a second layer (it used to be
    /// invisibly absorbed because the panel was already dismissing; now that
    /// Menu can leave the panel open, it must be blocked explicitly).
    var onMenuHandled: (() -> Void)?

    /// Gives the hosted content first refusal on Menu — see
    /// `RailPanelMenuHandling`'s doc comment for why this exists. Called
    /// from this panel's own `pressesBegan` (the live path while focus is
    /// inside the panel) and from
    /// `PlayerContainerViewController.handleMenuButton()` (the edge case
    /// where a Menu press arrives with focus outside the panel).
    func contentHandlesMenuPress() -> Bool {
        (content as? RailPanelMenuHandling)?.handleMenuPress() ?? false
    }

    private let backgroundEffectView: UIVisualEffectView
    private let wash = UIView()
    private let content: UIView
    private var didDismiss = false
    private var springAnimator: UIViewPropertyAnimator?

    /// An info pane (opened from a pill below the bar) rather than a popup.
    private(set) var isPane = false
    private weak var paneRail: PlayerRailView?

    private init(content: UIView, style: Style = .popup) {
        self.content = content
        // `.clear` glass plus a light gray wash lands on AVKit's private
        // `.avplayer` glass over black, mid gray and white (within 1-7 levels).
        // `.regular` darkens where AVKit lifts.
        backgroundEffectView = UIVisualEffectView(effect: UIGlassEffect(style: .clear))
        super.init(frame: .zero)

        backgroundEffectView.clipsToBounds = true
        backgroundEffectView.layer.cornerRadius = Metrics.cornerRadius
        backgroundEffectView.layer.cornerCurve = .continuous

        wash.backgroundColor = UIColor(white: 0.35, alpha: 0.18)
        wash.layer.cornerRadius = Metrics.cornerRadius
        wash.layer.cornerCurve = .continuous
        wash.isUserInteractionEnabled = false

        let padding: CGFloat
        switch style {
        case .popup: padding = content is CardTrackListView ? 0 : Metrics.padding
        case .paneCard: padding = Metrics.padding
        case .paneContent: padding = 0
        }
        if style != .popup {
            [backgroundEffectView, wash].forEach { $0.layer.cornerRadius = Metrics.paneCardRadius }
            wash.backgroundColor = TransportControlButton.restingWash
        }
        if style == .paneContent {
            [backgroundEffectView, wash].forEach { $0.isHidden = true }
        }
        let topInset = style == .paneContent ? Metrics.paneContentTop : padding
        let bottom = content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding)
        if style == .paneContent { bottom.priority = .defaultLow }
        [backgroundEffectView, wash, content].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(lessThanOrEqualToConstant: Metrics.maxHeight),

            backgroundEffectView.topAnchor.constraint(equalTo: topAnchor),
            backgroundEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            wash.topAnchor.constraint(equalTo: topAnchor),
            wash.leadingAnchor.constraint(equalTo: leadingAnchor),
            wash.trailingAnchor.constraint(equalTo: trailingAnchor),
            wash.bottomAnchor.constraint(equalTo: bottomAnchor),

            content.topAnchor.constraint(equalTo: topAnchor, constant: topInset),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            bottom,
        ])
    }

    private enum Style {
        case popup
        /// Pane content that draws its own surfaces (AVKit's Info card, card rows).
        case paneContent
        /// Free-form pane content on a glass card.
        case paneCard
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Presentation

    /// Builds the popup in `container` above `button` (right edges aligned) and
    /// grows it in. Passing the rail as `button` anchors to its top-right.
    @discardableResult
    static func present(content: UIView, width: CGFloat, in container: UIView, aboveRail rail: UIView, towards button: UIView) -> PlayerRailPanelView {
        let panel = PlayerRailPanelView(content: content)
        container.addSubview(panel)
        panel.translatesAutoresizingMaskIntoConstraints = false

        // Below every label's compression resistance: when the screen margin
        // wins, the popup gives way, never the rail's own layout.
        let trailing = panel.trailingAnchor.constraint(equalTo: button.trailingAnchor)
        trailing.priority = .defaultLow + 250
        NSLayoutConstraint.activate([
            panel.widthAnchor.constraint(equalToConstant: content is CardTrackListView ? CardTrackListView.menuWidth : width),
            panel.bottomAnchor.constraint(equalTo: button.topAnchor, constant: -Metrics.buttonGap),
            trailing,
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: Metrics.screenMargin),
            panel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -Metrics.screenMargin),
        ])
        container.layoutIfNeeded()

        // Content that needs to position itself against real geometry
        // before the first visible frame (e.g. Up Next's scroll-to-current
        // row) must do so here, after layout and before the grow-in.
        (content as? ChannelListPanelView)?.prepareForPresentation()

        panel.transform = panel.collapsedTransform
        content.alpha = 0
        panel.animate(toTransform: .identity, contentAlpha: 1, completion: nil)

        container.setNeedsFocusUpdate()
        container.updateFocusIfNeeded()

        return panel
    }

    /// AVKit's info pane: the area under the risen pills. `cardWidth` puts
    /// free-form content on a glass card that wide; nil gives the content the
    /// full 1760 x 300 area to draw its own surfaces in. `replacing` swaps an
    /// open pane's tab in place, as moving across AVKit's pills does.
    @discardableResult
    static func presentPane(content: UIView, cardWidth: CGFloat?, in container: UIView,
                            rail: PlayerRailView, pill: UIView, riders: [UIView] = [],
                            replacing old: PlayerRailPanelView?) -> PlayerRailPanelView {
        old?.removeWithoutDismissing()
        let panel = PlayerRailPanelView(content: content, style: cardWidth == nil ? .paneContent : .paneCard)
        panel.isPane = true
        panel.paneRail = rail
        panel.riders = riders
        container.addSubview(panel)
        panel.translatesAutoresizingMaskIntoConstraints = false
        var constraints = [
            panel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: PlayerRailView.sideInset),
            panel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Metrics.paneBottomInset),
        ]
        if let cardWidth {
            constraints.append(panel.widthAnchor.constraint(equalToConstant: cardWidth))
        } else {
            constraints += [
                panel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -PlayerRailView.sideInset),
                panel.heightAnchor.constraint(equalToConstant: Metrics.paneHeight),
            ]
        }
        // The gap between the pills and the pane: Down from any pill enters the
        // content, and Up from the content returns to this tab's pill rather
        // than whichever pill sits above (which would switch the tab).
        let guide = UIFocusGuide()
        container.addLayoutGuide(guide)
        guide.preferredFocusEnvironments = [content]
        panel.tabPill = pill
        constraints += [
            guide.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            guide.bottomAnchor.constraint(equalTo: panel.topAnchor),
            guide.heightAnchor.constraint(equalToConstant: Metrics.panePillGap),
        ]
        panel.returnGuide = guide
        NSLayoutConstraint.activate(constraints)
        container.layoutIfNeeded()
        (content as? ChannelListPanelView)?.prepareForPresentation()

        // The pills end 30pt above the pane. AVKit raises the whole control
        // block and the pane together from below, on one 0.5s curve.
        let paneTop = panel.frame.minY
        // From the rail's center, which its lift transform leaves alone.
        let restingTop = rail.center.y - rail.bounds.height / 2 + rail.pillRowRestingTop
        let pillHeight = rail.pillRowView.bounds.height
        let lift = restingTop - (paneTop - Metrics.panePillGap - pillHeight)
        panel.paneLift = lift
        if let old, old.paneLift == lift {
            content.alpha = 0
            UIView.animate(withDuration: 0.25) { content.alpha = 1 }
            return panel
        }
        let motion = paneMotion()
        rail.setPaneLift(lift, motion: motion)
        if old == nil { panel.transform = CGAffineTransform(translationX: 0, y: lift) }
        // AVKit fades only its Info card in; custom tabs just ride up.
        if content is PlayerInfoCardView { content.alpha = 0 }
        motion.addAnimations {
            panel.transform = .identity
            content.alpha = 1
            riders.forEach { $0.transform = CGAffineTransform(translationX: 0, y: -lift) }
        }
        motion.startAnimation()
        return panel
    }

    /// AVKit's info pane move: 0.5s on Core Animation's default curve.
    private static func paneMotion() -> UIViewPropertyAnimator {
        UIViewPropertyAnimator(duration: 0.5, timingParameters: UICubicTimingParameters(
            controlPoint1: CGPoint(x: 0.25, y: 0.1), controlPoint2: CGPoint(x: 0.25, y: 1)))
    }

    private var returnGuide: UIFocusGuide?
    private weak var tabPill: UIView?

    /// Where Up from the content goes: the tab's pill, or the sub-tab showing.
    func setReturnTarget(_ view: UIView) { tabPill = view }
    /// How far the control block rose for this pane.
    private var paneLift: CGFloat = 0
    /// Host views outside the rail (the scrub bar) that rise with it.
    private var riders: [UIView] = []

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if superview == nil, let returnGuide {
            returnGuide.owningView?.removeLayoutGuide(returnGuide)
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard let next = context.nextFocusedView else { return }
        if next.isDescendant(of: self) {
            returnGuide?.preferredFocusEnvironments = tabPill.map { [$0] } ?? []
        } else {
            returnGuide?.preferredFocusEnvironments = [content]
        }
    }

    /// A tab switch: the new pane takes over, so this one leaves with no
    /// dismissal side effects.
    private func removeWithoutDismissing() {
        didDismiss = true
        removeFromSuperview()
    }

    /// Scale about the bottom-right corner, the one nearest the button.
    private var collapsedTransform: CGAffineTransform {
        let corner = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        return CGAffineTransform(translationX: corner.x, y: corner.y)
            .scaledBy(x: Metrics.collapsedScale, y: Metrics.collapsedScale)
            .translatedBy(x: -corner.x, y: -corner.y)
    }

    /// AVKit's two clocks: the platter springs, the content fades on a short curve.
    private func animate(toTransform transform: CGAffineTransform, contentAlpha: CGFloat,
                         clearsGlass: Bool = false, completion: (() -> Void)?) {
        springAnimator?.stopAnimation(true)
        let spring = UIViewPropertyAnimator(duration: Metrics.springDuration, timingParameters: Metrics.spring)
        spring.addAnimations { self.transform = transform }
        springAnimator = spring
        spring.startAnimation()

        // Completion rides the content fade, and closing clears the glass with
        // it: the shrunken platter otherwise sat on screen for the rest of the spring.
        let fade = UIViewPropertyAnimator(duration: Metrics.contentFade, timingParameters: Metrics.contentFadeCurve)
        fade.addAnimations {
            self.content.alpha = contentAlpha
            if clearsGlass {
                self.backgroundEffectView.effect = nil
                self.wash.alpha = 0
            }
        }
        fade.addCompletion { _ in completion?() }
        fade.startAnimation()
    }

    /// The info sheet has no row to highlight, so the platter rim brightens instead.
    func setFocusHighlight(_ focused: Bool) {
        layer.cornerRadius = Metrics.cornerRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = focused ? 1 : 0
        layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor
    }

    func dismissPanel() {
        guard !didDismiss else { return }
        didDismiss = true
        isUserInteractionEnabled = false
        if isPane {
            let motion = Self.paneMotion()
            paneRail?.setPaneLift(nil, motion: motion)
            motion.addAnimations {
                self.transform = CGAffineTransform(translationX: 0, y: self.paneLift)
                self.alpha = 0
                self.riders.forEach { $0.transform = .identity }
            }
            motion.addCompletion { [weak self] _ in self?.removeFromSuperview() }
            motion.startAnimation()
        } else {
            animate(toTransform: collapsedTransform, contentAlpha: 0, clearsGlass: true) { [weak self] in
                self?.removeFromSuperview()
            }
        }
        // The host moves focus and restores state now, not when the spring settles.
        onDismiss?()
    }

    // MARK: - Focus

    /// A pane is never a focus stop itself: its content and the pills are.
    override var canBecomeFocused: Bool { !didDismiss && !isPane }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [content] }

    /// Fences focus inside the panel while it's still in the window
    /// (i.e. hasn't finished its dismiss animation/removal yet) —
    /// mirrors the fullScreenCover-style isolation the rest of the
    /// chrome relies on, scoped here since the panel isn't presented
    /// via a system modal.
    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        // While collapsing it is still on screen; keep focus from re-entering it.
        if didDismiss { return !(context.nextFocusedView?.isDescendant(of: self) ?? false) }
        guard window != nil else { return true }
        if let next = context.nextFocusedView, next.isDescendant(of: self) {
            return true
        }
        // A pane shares focus with the pills (and sub-tabs) that switch it.
        if isPane, let rail = paneRail, let next = context.nextFocusedView, next.isDescendant(of: rail) {
            return true
        }
        return false
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .menu {
            // This is where Menu genuinely arrives while the panel is open:
            // tvOS delivers presses to the FOCUSED view and bubbles them up,
            // and the panel fences focus inside itself, so this override sits
            // on the chain between every focused descendant and the container
            // VC. Content gets first refusal (e.g. Insights' actor state
            // reverse-crossfades back to its list) before the whole panel
            // dismisses.
            onMenuHandled?()
            if !contentHandlesMenuPress() {
                dismissPanel()
            }
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .menu {
            // Menu is fully consumed at began; an unswallowed ended
            // phase bubbles to the system and peels an extra layer
            // (dismisses the player itself on top of closing the
            // panel) — same trap as the container's own Menu handling.
            return
        }
        super.pressesEnded(presses, with: event)
    }
}
