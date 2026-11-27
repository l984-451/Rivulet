// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Combine
import SwiftUI
import UIKit

/// Rivulet's own poster-to-detail zoom, the alternative to SwiftUI's `.navigationTransition(.zoom)`.
///
/// SwiftUI builds the detail page before its zoom starts, which held the first frame 66 to 96 ms
/// after the tap on device. This zoom starts moving in the tap's own run-loop turn with a still of
/// the tile, and builds the page a turn later: the build still stalls the main thread, but the
/// spring is already running in the render server by then, so the motion does not wait for it.
///
/// The page is a child of the window's root controller, its view on top of the root's, rather than
/// a presentation: the root presents the player through `.fullScreenCover`, which has to keep
/// working over the page, and the page's own alerts and sheets present through the same hierarchy.
@MainActor
enum IOSCustomZoom {
    /// A zoom is open or animating; `open` is ignored while true. One whose overlay has left the
    /// window or fallen under another view does not count, and the next `open` clears it.
    static var isActive: Bool { IOSZoomController.current.map { !$0.isStranded } ?? false }

    /// `source` returns the tapped artwork's frame in window coordinates. It is read when the zoom
    /// opens and again when it closes; nil (or a frame now off screen) fades instead of zooming.
    /// `content` builds the page (a SwiftUI view that already carries its environment objects and
    /// its own NavigationStack) and receives the action that closes it. `hidesSource` hides the
    /// tile (true) while the card stands in for it, as the system zoom hides its source, and shows
    /// it again (false) once the card is back over it.
    static func open(from source: @escaping () -> CGRect?, cornerRadius: CGFloat,
                     hidesSource: @escaping (Bool) -> Void = { _ in },
                     content: @escaping (_ close: @escaping () -> Void) -> AnyView) {
        guard let window = keyWindow, let root = window.rootViewController else { return }
        // SwiftUI can bury the overlay under views it inserts later, and a new root leaves it behind.
        // Either way it is invisible but still takes every touch, so clear it rather than refuse.
        if let current = IOSZoomController.current, current.isStranded || current.parent !== root {
            current.tearDown()
        }
        guard IOSZoomController.current == nil else { return }
        IOSZoomController(cornerRadius: cornerRadius, source: source, hidesSource: hidesSource, content: content)
            .attach(to: root, in: window)
    }

    /// Closes the page without flying back to a tile (the tile may be gone): a fade, or at once.
    static func dismiss(animated: Bool) {
        IOSZoomController.current?.dismiss(animated: animated)
    }

    /// True while a zoomed page is up and `view` is not part of it, or the page itself is still
    /// zooming in or is closing. Polled by theme videos (every 300 ms) so they pause underneath
    /// the page and do not start mid-flight.
    static func covers(_ view: UIView) -> Bool {
        guard let zoom = IOSZoomController.current, !zoom.isStranded else { return false }
        return zoom.covers(view)
    }

    private static var keyWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.compactMap(\.keyWindow).first(where: \.isKeyWindow)
            ?? scenes.first { $0.activationState == .foregroundActive }?.keyWindow
    }
}

/// Whether a zoomed page has landed and covers the app, for SwiftUI views that should rest
/// underneath it (the Home hero's auto-advance). True from landing until the close starts.
@MainActor
final class IOSZoomCoverage: ObservableObject {
    static let shared = IOSZoomCoverage()

    @Published private(set) var pageIsUp = false

    private init() {}

    fileprivate func update(_ isUp: Bool) {
        if pageIsUp != isUp { pageIsUp = isUp }
    }
}

/// The zoom's feel, gathered here to tune on device.
private enum Tuning {
    /// One spring for the zoom in, the zoom out and the swipe's return, so UIKit and Core Animation
    /// move alike. A perceptual duration of 0.4 s at a damping ratio of 0.88 settles in about 0.5 s.
    static let springDuration: TimeInterval = 0.4
    static let dampingRatio: CGFloat = 0.88
    static var springBounce: CGFloat { 1 - dampingRatio }
    /// How long the tile's still takes to give way to the page once the page is built.
    static let stillFadeOut: TimeInterval = 0.18
    /// When the card turns into the tile on the way out, as shares of the spring's settling time:
    /// the still comes back over the page, or with no still to land as, the card fades to the live
    /// tile under it. The spring covers most of its travel early, so this is about the last 35% of
    /// the card's flight.
    static let landingStart = 0.25
    static let landingLength = 0.35
    /// The crossfade used for Reduce Motion, for a page with no source tile, and for a tile frame
    /// that went stale while the page was up (rotation, a window resize).
    static let fade: TimeInterval = 0.3
    /// How long the card holds over the tile after showing it again before the overlay goes, so
    /// SwiftUI has drawn the tile by then.
    static let revealLead: TimeInterval = 0.05
    /// Edge swipe: the share of the finger's travel the page follows, how small it gets across the
    /// full width, and how round its corners get.
    static let swipeFollow: CGFloat = 0.6
    static let swipeMinScale: CGFloat = 0.7
    static let swipeCornerRadius: CGFloat = 36
    /// A release closes the page faster than `swipeCommitSpeed` (points per second), or past
    /// `swipeCommitProgress` of the width unless it flicks back faster than `swipeCancelSpeed`.
    static let swipeCommitProgress: CGFloat = 0.25
    static let swipeCommitSpeed: CGFloat = 600
    static let swipeCancelSpeed: CGFloat = 100
    /// Caps a release's velocity as handed to the spring, in spring distances per second.
    static let maxReleaseVelocity: CGFloat = 4
    /// How far from rest, in points, the swipe's return may still be when a new swipe takes the card.
    static let regrabSlack: CGFloat = 1
    /// How often the page looks for a chance to take the keyboard back while it lacks it.
    static let keyboardRecheck: TimeInterval = 0.5
    /// What the zoom's own Core Animation work asks of a ProMotion display. An iPhone runs an
    /// explicit animation at 60 Hz unless it asks (measured: every close at 60 Hz on an iPhone 15
    /// Pro Max, while the UIKit spring of the zoom in ran at up to 120 Hz).
    static let frameRate = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
}

/// Keeps the display at the zoom's frame rate while a finger drags the page. The swipe's updates
/// are commits from the app, which ask for no rate, so without it touches and frames come at 60 Hz.
@MainActor
private enum DragPacing {
    private static var link: CADisplayLink?
    private static let target = Tick()

    private final class Tick: NSObject {
        @objc func tick() {}
    }

    static func run(_ on: Bool) {
        if on, link == nil {
            let link = CADisplayLink(target: target, selector: #selector(Tick.tick))
            link.preferredFrameRateRange = Tuning.frameRate
            link.add(to: .main, forMode: .common)
            self.link = link
        } else if !on {
            link?.invalidate()
            link = nil
        }
    }
}

/// Hosts one zoomed page. Its view covers the root's and takes every touch while it exists, from
/// the tap until the card has landed back on its tile, so nothing under it can be tapped mid-flight.
///
/// The page's safe area comes from its geometry, so while the page is in place the views only ever
/// hold the open state: the zoom in sets it before the page is added, and the edge swipe and the
/// zoom out animate the layers' presentation alone. Moving the views would shrink the page's safe
/// area as it left the notch, and SwiftUI would lay the page out again on every frame.
private final class IOSZoomController: UIViewController, UIGestureRecognizerDelegate {
    static var current: IOSZoomController?

    private enum Phase { case opening, open, dragging, closing }

    private static let swipeKey = "rivulet.zoom.swipe"
    /// The zoom in's settling time, from rest.
    private static let settlingTime = CASpringAnimation(perceptualDuration: Tuning.springDuration,
                                                        bounce: Double(Tuning.springBounce)).settlingDuration

    private let cornerRadius: CGFloat
    /// The tile's frame in window coordinates, read at open and again at close.
    private let sourceFrame: () -> CGRect?
    private let content: (@escaping () -> Void) -> AnyView
    private let hidesSource: (Bool) -> Void
    private var sourceHidden = false
    private var phase = Phase.opening
    /// The tile's frame in this view when the zoom opened; nil when the page faded in.
    private var source: CGRect?
    /// The size `source` was measured against. A rotation or a window resize leaves it stale.
    private var openSize = CGSize.zero
    private var isRightToLeft = false
    private var announced = false
    private var keyboardCheckPending = false

    /// `wrapper` carries the swipe. `clip` is the rounded window that grows from the tile. `card` is
    /// always the page's full size; its scale draws it into the clip, aspect fill, so the clip
    /// crops it rather than squashing it.
    private let wrapper = UIView()
    private let clip = UIView()
    private let card = UIView()
    /// The tapped tile, over the page until the page is built, and again as the page lands.
    private var still: UIView?
    private var page: UIHostingController<AnyView>?
    private var swipe: UIScreenEdgePanGestureRecognizer?
    /// The transform the swipe last held the wrapper at.
    private var held = CATransform3DIdentity

    init(cornerRadius: CGFloat, source: @escaping () -> CGRect?, hidesSource: @escaping (Bool) -> Void,
         content: @escaping (@escaping () -> Void) -> AnyView) {
        self.cornerRadius = cornerRadius
        sourceFrame = source
        self.hidesSource = hidesSource
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let overlay = IOSZoomOverlayView()
        overlay.onEscape = { [weak self] in
            self?.close()
            return self != nil
        }
        // VoiceOver reads the page only, not the tab under it.
        overlay.accessibilityViewIsModal = true
        view = overlay
    }

    // The page is dark, but SwiftUI's root controller decides the status bar, and nothing public
    // lets a child override it. This only helps if the root asks its children. Forcing this
    // controller dark instead would also darken the light pages pushed inside the page.
    override var childForStatusBarStyle: UIViewController? { page }
    override var childForStatusBarHidden: UIViewController? { page }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        keepOnTopSoon()
        // Follow a rotation or a window resize. Not mid-zoom: the zoom's start state is the tile's.
        switch phase {
        case .open, .dragging: layOutOpen()
        case .opening where source == nil: layOutOpen()
        default: break
        }
    }

    /// Left the window, or under another view: invisible, though it may still take every touch.
    var isStranded: Bool {
        guard isViewLoaded, view.window != nil, let superview = view.superview else { return true }
        return superview.subviews.last !== view
    }

    func covers(_ other: UIView) -> Bool {
        guard other.isDescendant(of: view) else { return true }
        return phase != .open && phase != .dragging
    }

    /// Reduce Motion, read at open and again at close: it can be turned on while the page is up.
    private static var prefersFade: Bool {
        UIAccessibility.isReduceMotionEnabled || UIAccessibility.prefersCrossFadeTransitions
    }

    // MARK: - Opening

    func attach(to root: UIViewController, in window: UIWindow) {
        let windowSource = Self.prefersFade ? nil : sourceFrame().flatMap {
            Self.isOnScreen($0, in: window.bounds) ? $0 : nil
        }
        // The tile as it is on screen now, before the overlay covers it.
        let tile = windowSource.flatMap {
            window.resizableSnapshotView(from: $0, afterScreenUpdates: false, withCapInsets: .zero)
        }

        Self.current = self
        root.addChild(self)
        view.frame = root.view.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.view.addSubview(view)
        didMove(toParent: root)
        // TabView rebuilds on a size-class change and can insert its views above this one.
        registerForTraitChanges([UITraitHorizontalSizeClass.self], action: #selector(keepOnTopSoon))

        isRightToLeft = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        openSize = view.bounds.size
        if let windowSource {
            let rect = view.convert(windowSource, from: window)
            if Self.isOnScreen(rect, in: view.bounds) { source = rect }
        }

        clip.clipsToBounds = true
        clip.layer.cornerCurve = .continuous
        // Dark like the page, around the still until the page arrives.
        card.backgroundColor = .black
        view.addSubview(wrapper)
        wrapper.addSubview(clip)
        clip.addSubview(card)
        // The page takes touches once it has landed; until then they stop at the overlay.
        wrapper.isUserInteractionEnabled = false

        let swipe = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(swiped(_:)))
        swipe.edges = isRightToLeft ? .right : .left
        swipe.delegate = self
        view.addGestureRecognizer(swipe)
        self.swipe = swipe

        if let source {
            // The still was taken above, so the tile can go: the card has left its slot.
            setSourceHidden(true)
            zoomIn(from: source, tile: tile)
        } else {
            layOutOpen()
            wrapper.alpha = 0
        }
        // Commit the overlay and its spring now. A main-queue block queued during the tap can run
        // before the run loop's own commit, and the page's build would then hold the first frame.
        CATransaction.flush()
        DispatchQueue.main.async { [weak self] in self?.insertPage() }
    }

    private func zoomIn(from source: CGRect, tile: UIView?) {
        let size = view.bounds.size
        let scale = Self.fillScale(source.size, in: size)
        layOutOpen()
        clip.frame = source
        clip.layer.cornerRadius = cornerRadius
        card.center = CGPoint(x: source.width / 2, y: source.height / 2)
        card.transform = CGAffineTransform(scaleX: scale, y: scale)
        if let tile {
            // In card coordinates, sized so that the card's starting scale draws it exactly over the tile.
            tile.frame = CGRect(x: (size.width - source.width / scale) / 2, y: (size.height - source.height / scale) / 2,
                                width: source.width / scale, height: source.height / scale)
            // A square crop of a rounded tile: its corners hold Home's background, which would show
            // as light wedges while the clip's corners straighten.
            tile.layer.cornerRadius = cornerRadius / scale
            tile.layer.cornerCurve = .continuous
            tile.layer.masksToBounds = true
            card.addSubview(tile)
            still = tile
        }
        UIView.animate(springDuration: Tuning.springDuration, bounce: Tuning.springBounce) {
            self.layOutOpen()
            self.clip.layer.cornerRadius = 0
            self.card.transform = .identity
        } completion: { [weak self] _ in
            self?.landed()
        }
        land(after: Self.settlingTime)
    }

    /// Builds the page a turn after the tap, behind the still. The views already hold the open
    /// state, so the page lays out once at its final size and safe area, and the card's in-flight
    /// scale draws it from wherever the zoom has got to. A close or dismiss before then skips it.
    private func insertPage() {
        guard Self.current === self, phase != .closing, page == nil else { return }
        let page = UIHostingController(rootView: content { [weak self] in self?.close() })
        // The black card shows through until the page draws.
        page.view.backgroundColor = .clear
        addChild(page)
        page.view.frame = card.bounds
        page.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if let still {
            card.insertSubview(page.view, belowSubview: still)
        } else {
            card.addSubview(page.view)
        }
        page.didMove(toParent: self)
        self.page = page
        // Lay it out in this turn, so the still fades over a drawn page.
        page.view.layoutIfNeeded()
        setNeedsStatusBarAppearanceUpdate()
        if let still {
            UIView.animate(withDuration: Tuning.stillFadeOut, delay: 0, options: .curveEaseOut) { still.alpha = 0 }
        } else {
            UIView.animate(withDuration: Tuning.fade, delay: 0, options: .curveEaseOut) {
                self.wrapper.alpha = 1
            } completion: { [weak self] _ in
                self?.landed()
            }
            land(after: Tuning.fade)
        }
        settle()
    }

    /// Lands by the clock as well: an animation's completion can be lost (Picture in Picture
    /// restoring presents the player mid-zoom), and a page that never lands takes no touches and
    /// blocks every later zoom.
    private func land(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.05) { [weak self] in self?.landed() }
    }

    private func landed() {
        guard Self.current === self, phase == .opening else { return }
        phase = .open
        wrapper.isUserInteractionEnabled = true
        IOSZoomCoverage.shared.update(true)
        // Catches up with a rotation during the zoom.
        view.setNeedsLayout()
        settle()
    }

    /// Once landed with the page built: VoiceOver moves to it, and it takes the keyboard.
    private func settle() {
        guard phase == .open, page != nil, !announced else { return }
        announced = true
        UIAccessibility.post(notification: .screenChanged, argument: nil)
        takeKeyboard(atLanding: true)
    }

    /// The open state: everything at the overlay's full size.
    private func layOutOpen() {
        let bounds = view.bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        wrapper.bounds = bounds
        wrapper.center = center
        clip.frame = bounds
        card.bounds = CGRect(origin: .zero, size: bounds.size)
        card.center = center
    }

    /// The card's scale over the tile: aspect fill, so the clip crops the page rather than squashing it.
    private static func fillScale(_ tile: CGSize, in size: CGSize) -> CGFloat {
        max(tile.width / max(size.width, 1), tile.height / max(size.height, 1))
    }

    private static func isOnScreen(_ rect: CGRect, in bounds: CGRect) -> Bool {
        rect.width >= 1 && rect.height >= 1 && rect.intersects(bounds)
    }

    private func setSourceHidden(_ hidden: Bool) {
        guard sourceHidden != hidden else { return }
        sourceHidden = hidden
        hidesSource(hidden)
    }

    private static func isSameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1
            && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }

    // MARK: - Staying on top

    /// SwiftUI may insert views above a foreign subview; the overlay must stay over all of them.
    /// Deferred, so the root's subviews are not reordered during its own layout pass.
    @objc private func keepOnTopSoon() {
        guard view.superview?.subviews.last !== view else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let superview = view.superview, superview.subviews.last !== view else { return }
            superview.bringSubviewToFront(view)
        }
    }

    // MARK: - Closing

    /// Every way out starts here: the page stops taking touches, and the app's views stop resting.
    private func beginClosing() {
        phase = .closing
        IOSZoomCoverage.shared.update(false)
        // Ends a swipe in progress; its handler ignores the cancel.
        swipe?.isEnabled = false
        wrapper.isUserInteractionEnabled = false
    }

    private func close(fingerVelocity: CGPoint? = nil) {
        guard phase != .closing else { return }
        let held = phase == .dragging ? self.held : nil
        beginClosing()
        if let target = closeTarget() {
            zoomOut(to: target, velocity: releaseVelocity(fingerVelocity, from: held, to: target), held: held)
        } else {
            fadeOut()
        }
    }

    func dismiss(animated: Bool) {
        if !animated {
            tearDown()
            return
        }
        if phase != .closing { beginClosing() }
        fadeOut()
    }

    private func fadeOut() {
        // Under the page as it fades, wherever the tile is now.
        setSourceHidden(false)
        UIView.animate(withDuration: Tuning.fade, delay: 0, options: [.beginFromCurrentState, .curveEaseIn]) {
            self.wrapper.alpha = 0
        }
        tearDown(after: Tuning.fade)
    }

    /// Where the tile is now, read again, since a row may have reordered under the page. Nil fades
    /// instead: the tile is gone or off screen, the window changed size (the still and the page's
    /// layout belong to the old one), the page is still fading in, or Reduce Motion is now on.
    private func closeTarget() -> CGRect? {
        guard !Self.prefersFade, view.bounds.size == openSize, let window = view.window,
              wrapper.alpha >= 1, (wrapper.layer.presentation() ?? wrapper.layer).opacity >= 1,
              let frame = sourceFrame() else { return nil }
        let rect = view.convert(frame, from: window)
        return Self.isOnScreen(rect, in: view.bounds) ? rect : nil
    }

    /// The release as the springs' starting velocity, in spring distances per second: the page's
    /// share of the finger's velocity, along the page's path from where it is held to the tile.
    private func releaseVelocity(_ finger: CGPoint?, from held: CATransform3D?, to target: CGRect) -> CGFloat {
        guard let finger, let held else { return 0 }
        let path = CGVector(dx: target.midX - (wrapper.center.x + held.m41), dy: target.midY - (wrapper.center.y + held.m42))
        let distance = hypot(path.dx, path.dy)
        guard distance >= 1 else { return 0 }
        let along = (finger.x * path.dx + finger.y * path.dy) * Tuning.swipeFollow / distance
        return min(max(along / distance, 0), Tuning.maxReleaseVelocity)
    }

    /// Flies the page back into the tile from wherever it is now: mid-zoom, mid-swipe or settled.
    /// Only the presentation moves, and the page stays live until the overlay is removed.
    private func zoomOut(to target: CGRect, velocity: CGFloat, held: CATransform3D?) {
        let scale = Self.fillScale(target.size, in: openSize)
        let wrapperNow = held ?? (wrapper.layer.presentation() ?? wrapper.layer).transform
        let clipNow = clip.layer.presentation() ?? clip.layer
        let cardNow = card.layer.presentation() ?? card.layer
        let motion: [(CALayer, String, Any, Any)] = [
            (wrapper.layer, "transform", NSValue(caTransform3D: wrapperNow), NSValue(caTransform3D: CATransform3DIdentity)),
            (clip.layer, "bounds", NSValue(cgRect: clipNow.bounds), NSValue(cgRect: CGRect(origin: .zero, size: target.size))),
            (clip.layer, "position", NSValue(cgPoint: clipNow.position), NSValue(cgPoint: CGPoint(x: target.midX, y: target.midY))),
            (clip.layer, "cornerRadius", clipNow.cornerRadius, cornerRadius),
            (card.layer, "position", NSValue(cgPoint: cardNow.position),
             NSValue(cgPoint: CGPoint(x: target.width / 2, y: target.height / 2))),
            (card.layer, "transform", NSValue(caTransform3D: cardNow.transform),
             NSValue(caTransform3D: CATransform3DMakeScale(scale, scale, 1))),
        ]
        // The still lands as the tile only on the frame it was taken from. A tile that has moved
        // shows itself instead, through the card as it fades.
        let landingStill = source.map { Self.isSameFrame($0, target) } == true ? still?.layer : nil
        let stillShown = landingStill.map { ($0.presentation() ?? $0).opacity } ?? 1
        // A fade out added this turn has set the model, but not yet the presentation.
        let stillFaded = landingStill.map { stillShown < 1 || $0.opacity < 1 } ?? false
        // The zoom in, the still's fade and the swipe's hold all give way to the flight back.
        for layer in [wrapper.layer, clip.layer, card.layer, landingStill] { layer?.removeAllAnimations() }

        var settle: CFTimeInterval = 0
        for (layer, keyPath, from, to) in motion {
            let spring = Self.spring(keyPath, from: from, to: to, velocity: velocity)
            // Held at the tile until the overlay goes: the views themselves still hold the open page.
            spring.fillMode = .forwards
            spring.isRemovedOnCompletion = false
            layer.add(spring, forKey: "rivulet.zoom." + keyPath)
            settle = max(settle, spring.duration)
        }
        let landing = CACurrentMediaTime() + settle * Tuning.landingStart
        if let landingStill {
            if stillFaded {
                landingStill.add(Self.fade(from: stillShown, to: 1, at: landing, over: settle * Tuning.landingLength),
                                 forKey: "rivulet.zoom.opacity")
            }
            // The slot stays empty until the card is back in it: the tile shows under the landed
            // still, which matches it, and the overlay goes once SwiftUI has drawn it.
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
                self?.setSourceHidden(false)
                self?.tearDown(after: Tuning.revealLead)
            }
        } else {
            clip.layer.add(Self.fade(from: 1, to: 0, at: landing, over: settle * Tuning.landingLength),
                           forKey: "rivulet.zoom.opacity")
            // The card fades to the live tile, which has to be there by then.
            DispatchQueue.main.asyncAfter(deadline: .now() + settle * Tuning.landingStart) { [weak self] in
                self?.setSourceHidden(false)
            }
            tearDown(after: settle)
        }
    }

    /// By the clock rather than an animation's completion, which may never come if the root's view
    /// leaves the window mid-flight; a zoom left open would block every later one.
    private func tearDown(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.tearDown() }
    }

    func tearDown() {
        guard Self.current === self else { return }
        phase = .closing
        let root = parent
        if let page {
            page.willMove(toParent: nil)
            page.view.removeFromSuperview()
            page.removeFromParent()
        }
        page = nil
        willMove(toParent: nil)
        view.removeFromSuperview()
        removeFromParent()
        Self.current = nil
        DragPacing.run(false)
        setSourceHidden(false)
        IOSZoomCoverage.shared.update(false)
        root?.setNeedsStatusBarAppearanceUpdate()
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    private static func spring(_ keyPath: String, from: Any, to: Any, velocity: CGFloat) -> CASpringAnimation {
        let spring = CASpringAnimation(perceptualDuration: Tuning.springDuration, bounce: Double(Tuning.springBounce))
        spring.keyPath = keyPath
        spring.fromValue = from
        spring.toValue = to
        spring.initialVelocity = velocity
        spring.duration = spring.settlingDuration
        spring.preferredFrameRateRange = Tuning.frameRate
        return spring
    }

    /// Holds `from` until it starts, and `to` until the overlay goes.
    private static func fade(from: Float, to: Float, at start: CFTimeInterval, over duration: CFTimeInterval) -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.beginTime = start
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fade.preferredFrameRateRange = Tuning.frameRate
        fade.fillMode = .both
        fade.isRemovedOnCompletion = false
        return fade
    }

    // MARK: - Edge swipe

    @objc private func swiped(_ swipe: UIScreenEdgePanGestureRecognizer) {
        let width = max(view.bounds.width, 1)
        let direction: CGFloat = isRightToLeft ? -1 : 1
        let translation = swipe.translation(in: view)
        let travel = max(translation.x * direction, 0)
        let progress = min(travel / width, 1)
        switch swipe.state {
        case .began, .changed:
            guard phase == .open || phase == .dragging else { return }
            if phase == .open {
                clip.layer.removeAnimation(forKey: Self.swipeKey)
                // A second finger would tap the page where it lies, not where it is drawn.
                wrapper.isUserInteractionEnabled = false
                phase = .dragging
                DragPacing.run(true)
            }
            let scale = 1 - (1 - Tuning.swipeMinScale) * progress
            let follow = CATransform3DMakeTranslation(travel * direction * Tuning.swipeFollow,
                                                      translation.y * Tuning.swipeFollow, 0)
            hold(CATransform3DScale(follow, scale, scale, 1))
            clip.layer.cornerRadius = Tuning.swipeCornerRadius * progress
        case .ended, .cancelled, .failed:
            DragPacing.run(false)
            guard phase == .dragging else { return }
            let velocity = swipe.velocity(in: view)
            let speed = velocity.x * direction
            // A flick back cancels, as it does for the system's swipe back.
            let commits = speed > Tuning.swipeCommitSpeed
                || (progress > Tuning.swipeCommitProgress && speed > -Tuning.swipeCancelSpeed)
            if swipe.state == .ended, commits {
                close(fingerVelocity: velocity)
            } else {
                // Toward the open state, in spring distances per second.
                let toward = travel > 1 ? -speed / travel : 0
                springBack(velocity: min(max(toward, -Tuning.maxReleaseVelocity), Tuning.maxReleaseVelocity))
            }
        default:
            break
        }
    }

    /// Shows the wrapper at `transform` without moving the view, so the page's layout is untouched.
    private func hold(_ transform: CATransform3D) {
        held = transform
        let hold = CABasicAnimation(keyPath: "transform")
        hold.fromValue = NSValue(caTransform3D: transform)
        hold.toValue = hold.fromValue
        hold.fillMode = .both
        hold.isRemovedOnCompletion = false
        wrapper.layer.add(hold, forKey: Self.swipeKey)
    }

    private func springBack(velocity: CGFloat) {
        phase = .open
        wrapper.isUserInteractionEnabled = true
        let radius = clip.layer.cornerRadius
        clip.layer.cornerRadius = 0
        // Replaces the hold; once it has run, the views' own open state shows again.
        wrapper.layer.add(Self.spring("transform", from: NSValue(caTransform3D: held),
                                      to: NSValue(caTransform3D: CATransform3DIdentity), velocity: velocity),
                          forKey: Self.swipeKey)
        clip.layer.add(Self.spring("cornerRadius", from: radius, to: CGFloat(0), velocity: velocity), forKey: Self.swipeKey)
        held = CATransform3DIdentity
    }

    /// The swipe's return is still visibly moving the card. A new swipe tracks from rest, so taking
    /// the card before it has nearly settled would make it jump.
    private var isSpringingBack: Bool {
        guard wrapper.layer.animation(forKey: Self.swipeKey) != nil,
              let now = wrapper.layer.presentation()?.transform else { return false }
        return abs(now.m41) > Tuning.regrabSlack || abs(now.m42) > Tuning.regrabSlack
            || abs(now.m11 - 1) * view.bounds.width / 2 > Tuning.regrabSlack
    }

    /// Only at the root of the page's own stack: a page pushed inside it is that stack's to pop.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        phase == .open && !isSpringingBack && pageIsAtRoot
    }

    /// A scroll view under the finger waits for the edge swipe to fail, as it does for the system's swipe back.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        (otherGestureRecognizer.view as? UIScrollView)?.panGestureRecognizer === otherGestureRecognizer
    }

    private var pageIsAtRoot: Bool {
        guard let page else { return false }
        return (Self.firstNavigationController(under: page)?.viewControllers.count ?? 0) <= 1
    }

    private static func firstNavigationController(under controller: UIViewController) -> UINavigationController? {
        var queue = controller.children
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let stack = next as? UINavigationController { return stack }
            queue += next.children
        }
        return nil
    }

    // MARK: - Keyboard

    /// Escape and Command-[ close the page from the root of its stack, the edge swipe's rule.
    /// Deeper in, there are none, so the keys go on to whatever the inner stack offers.
    override var keyCommands: [UIKeyCommand]? {
        guard phase == .open, pageIsAtRoot else { return nil }
        return [
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeFromKeyboard)),
            UIKeyCommand(title: String(localized: "Back"), action: #selector(closeFromKeyboard),
                         input: "[", modifierFlags: .command),
        ]
    }

    @objc private func closeFromKeyboard() { close() }

    override var canBecomeFirstResponder: Bool { phase == .open || phase == .dragging }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { recheckKeyboard() }
        return resigned
    }

    /// Key commands only reach the page through the first responder, and with nobody holding it
    /// UIKit starts at the root, under the page. So the page takes it on landing, and while it
    /// lacks it looks again every half second: a player or sheet over the page, or a menu or field
    /// inside it, takes it and leaves nobody holding it when it goes. Later looks never take it
    /// from a holder (taking it from an open menu drops the menu's pick); at landing the overlay
    /// has kept every touch from the app, so a holder outside the page is only the app under it.
    private func takeKeyboard(atLanding: Bool = false) {
        guard Self.current === self, phase == .open || phase == .dragging, !isFirstResponder else { return }
        let holder = UIResponder.zoomFirstResponder
        let nobody = holder == nil || holder is UIWindow
        let inPage = (holder as? UIView)?.isDescendant(of: view) == true
        if parent?.presentedViewController == nil, nobody || (atLanding && !inPage), becomeFirstResponder() { return }
        recheckKeyboard()
    }

    private func recheckKeyboard() {
        guard !keyboardCheckPending, Self.current === self, phase != .closing else { return }
        keyboardCheckPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Tuning.keyboardRecheck) { [weak self] in
            self?.keyboardCheckPending = false
            self?.takeKeyboard()
        }
    }
}

/// Keeps every touch that misses the page, rather than passing it up the responder chain to the
/// root under it, and closes the page on VoiceOver's two-finger Z.
private final class IOSZoomOverlayView: UIView {
    var onEscape: (() -> Bool)?

    override func accessibilityPerformEscape() -> Bool { onEscape?() ?? false }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}
}

private extension UIResponder {
    private static weak var zoomFound: UIResponder?

    /// The app's first responder: an action sent to nil goes to it (the key window when there is none).
    static var zoomFirstResponder: UIResponder? {
        zoomFound = nil
        UIApplication.shared.sendAction(#selector(rivuletZoomRecordFirstResponder), to: nil, from: nil, for: nil)
        return zoomFound
    }

    // Its own selector: IOSPlayerChrome adds a twin to UIResponder, and Objective-C would let one replace the other.
    @objc private func rivuletZoomRecordFirstResponder() { UIResponder.zoomFound = self }
}
