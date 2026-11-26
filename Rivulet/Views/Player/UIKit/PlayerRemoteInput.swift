// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerRemoteInput.swift
//  Rivulet
//
//  The one reading of the remote for the VOD and Live TV players: presses, clicks, taps,
//  swipes, holds, edge clicks and the ring jog become `PlaybackInputAction`s for the
//  coordinator, or a call on the host for what is chrome. A player supplies only what
//  really differs, through `PlayerRemoteInputHost`.
//

import UIKit

/// Where a press that brings the controls up puts focus.
enum PlayerControlsLanding {
    case scrubber, firstTool, infoPane
}

/// Which delivery of Menu is asking for a layer to close: the press itself, or the
/// system's dismiss that follows it.
enum PlayerBackSource {
    case menuPress, systemDismiss
}

@MainActor
protocol PlayerRemoteInputHost: AnyObject {
    // MARK: State

    var isScrubbing: Bool { get }
    /// The shuttle level, 0 when not shuttling.
    var scrubSpeed: Int { get }
    /// The time a full swipe is measured against (VOD: the duration; Live: the window).
    var scrubSpan: TimeInterval { get }
    var isPaused: Bool { get }
    var postVideoUp: Bool { get }
    /// Nothing to play. No model at all counts as failed.
    var playbackFailed: Bool { get }
    var descriptionUp: Bool { get }
    var controlsVisible: Bool { get }
    /// The rail's buttons own focus, so seek input belongs to the focus engine.
    var controlsFocusActive: Bool { get }
    /// Controls focus or a panel open: the ring jog and GameController seeks stand down.
    var controlsOwnFocus: Bool { get }
    var scrubberFocused: Bool { get }
    /// The scrub bar holds focus (as of the last focus update): the ring jog scrubs there.
    var scrubberOwnsFocus: Bool { get }
    /// An open rail panel owns the presses of its own content.
    var panelOwnsPresses: Bool { get }
    var pauseInsightsUp: Bool { get }
    var skipPillOwnsFocus: Bool { get }

    // MARK: Chrome

    func showControlsTemporarily()
    func focusControls(on landing: PlayerControlsLanding)
    func hideControls()
    func toggleClockTimes()
    func toggleFill()
    func cancelScrub()
    /// A shuttle step from the scrubber's own Left/Right hold.
    func scrubInDirection(forward: Bool)
    func chapterSnap()
    /// Runs a play/pause toggle inside the chrome's own animation.
    func animatePlaybackToggle(_ body: () -> Void)
    /// Called first on an Up/Down from the content state, before the chrome is read.
    func contentVerticalBegan()
    /// Down with something to offer instead of the Info pane (VOD: Insights over the pause screen).
    func openPauseInsightsIfOffered() -> Bool
    /// A focused view other than the content anchor that still wants this press (VOD: the skip pill).
    func claimsContentPress(focusedView: UIView, type: UIPress.PressType) -> Bool

    // MARK: Menu

    func closeDescription()
    func exitPlayer()
    /// Closes a layer only this host has (VOD: Up Next, the skip countdown, the skip pill). True if it did.
    func closeHostLayer(for source: PlayerBackSource) -> Bool
    /// Closes the open panel, if any. True if there was one.
    func closeOpenPanel(for source: PlayerBackSource) -> Bool
    /// The chrome layer under the panel: the pause screen, then the controls. True if one closed.
    func peelChromeLayer() -> Bool
    /// Whether the coordinator's Back will close something short of leaving, so the dismiss echo is blocked.
    var backClosesChrome: Bool { get }
    /// Back when the coordinator has no target.
    func handleBackWithoutTarget()
}

extension PlayerRemoteInputHost {
    var pauseInsightsUp: Bool { false }
    var skipPillOwnsFocus: Bool { false }
    func chapterSnap() {}
    func animatePlaybackToggle(_ body: () -> Void) { body() }
    func contentVerticalBegan() {}
    func openPauseInsightsIfOffered() -> Bool { false }
    func claimsContentPress(focusedView: UIView, type: UIPress.PressType) -> Bool { false }
    func closeHostLayer(for source: PlayerBackSource) -> Bool { false }
    func handleBackWithoutTarget() { exitPlayer() }
}

/// Invisible, full-screen focus stop for the content state. Presses bubble to
/// the container, which forwards them to `PlayerRemoteInput`. Full screen so the engine never
/// finds a move from it; above video and scrims, below every control.
final class ContentFocusAnchorView: UIView {

    /// Focus gate, set by the host's chrome pass.
    var isFocusEnabled = false

    override var canBecomeFocused: Bool { isFocusEnabled }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
final class PlayerRemoteInput: NSObject, UIGestureRecognizerDelegate {

    weak var host: PlayerRemoteInputHost?
    /// Focus stop for the content state.
    let contentAnchor = ContentFocusAnchorView()

    private let coordinator: PlaybackInputCoordinator
    /// Ring jog and clickpad state; acts only on input with no `UIPress` copy.
    private let remote = RemoteInputHandler()
    private var isMonitoring = false
    private weak var view: UIView?

    // MARK: Presses

    private var isHandlingMenuPress = false
    private var isHandlingSelectPress = false
    private var isHandlingPlayPausePress = false
    /// Touch twin for the content state's Up/Down (see `install`).
    private var contentSwipeBinding: DirectionalInputBinding?
    /// Tap-vs-hold for a content-state Left/Right press, the same detector the
    /// scrubber proxy uses, so both focus regimes behave identically.
    private let contentPressDetector = DirectionalPressDetector()
    /// The press type that began the detector's current press, so only that
    /// press's release ends it.
    private var contentDirectionalPressType: UIPress.PressType?
    /// A content-state Select is waiting for its release (it acts on the UP,
    /// like the SwiftUI tap gesture it replaces).
    private var contentSelectPending = false
    /// Set once an arrow press arrives with the clickpad physically down: this
    /// remote reports its edge clicks as arrows, so a `.select` is never an
    /// edge click (see `edgeClickDirection`). Static because the remote
    /// outlives any one player.
    private static var clickpadRingSeen = false

    // MARK: Touch

    private var panRecognizer: UIPanGestureRecognizer?
    private var swipeAxisLock = SwipeScrubAxisLock()
    /// A swipe-scrub is under way on this touch.
    private(set) var swipeScrubEntered = false
    private var swipeScrubLastX: CGFloat = 0
    /// A gated Up/Down swipe or a click took this touch, so it never scrubs.
    private var swipeTouchSpent = false
    private var swipeTouchBeganAt: CFTimeInterval = .infinity
    /// This scrub's counts for its diagnostics line.
    private var swipeScrubTravel: Double = 0
    private var swipeScrubPeakSpeed: Double = 0
    private var swipeScrubNetSeconds: Double = 0

    // MARK: Menu

    /// Blocks the dismiss the system's own Menu gesture echoes after a press we consumed.
    private var blockNextDismiss = false
    private var blockDismissResetWorkItem: DispatchWorkItem?

    init(coordinator: PlaybackInputCoordinator) {
        self.coordinator = coordinator
        super.init()

        contentPressDetector.onTap = { [weak self] forward in
            // Shift+arrow on a keyboard jumps, as it did on the GameController path.
            let action: PlaybackInputAction = RemoteInputHandler.isShiftHeld
                ? .jumpSeek(forward: forward) : .stepSeek(forward: forward)
            self?.coordinator.handle(action: action, source: .irPress)
        }
        contentPressDetector.onHold = { [weak self] forward in
            self?.coordinator.handle(action: .scrubNudge(forward: forward), source: .irPress)
        }

        remote.isPostVideoCheck = { [weak self] in self?.host?.postVideoUp ?? true }
        remote.isPausedCheck = { [weak self] in self?.host?.isPaused ?? false }
        remote.isControlsFocusCheck = { [weak self] in self?.host?.controlsOwnFocus ?? false }
        remote.isScrubberFocusCheck = { [weak self] in self?.host?.scrubberOwnsFocus ?? false }
        remote.durationCheck = { [weak self] in self?.host?.scrubSpan ?? 0 }
        remote.isSkipPillFocusCheck = { [weak self] in self?.host?.skipPillOwnsFocus ?? false }
        remote.onAction = { [weak self] action, source in self?.coordinator.handle(action: action, source: source) }
    }

    // MARK: - Setup

    /// Mounts the content anchor (above `sibling`, the video) and every recognizer on `view`.
    func install(in view: UIView, above sibling: UIView?) {
        self.view = view

        // The player opens in the content state; enabled before the first focus
        // pass so it is the initial landing (the host's chrome pass owns it after).
        contentAnchor.isFocusEnabled = true
        contentAnchor.frame = view.bounds
        contentAnchor.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if let sibling {
            view.insertSubview(contentAnchor, aboveSubview: sibling)
        } else {
            view.addSubview(contentAnchor)
        }

        // Up/Down's touch twin (the iPhone Remote sends no arrow presses).
        // Not while the clickpad is down: a click jolts the touch into a fake swipe.
        // Nor in a ring jog or a swipe-scrub; a swipe that acts here spends the touch.
        contentSwipeBinding = DirectionalInputBinding(
            gatedSwipesOn: contentAnchor,
            directions: [.up, .down],
            shouldHandle: { [weak self] direction in
                guard let self, !RemoteInputHandler.isClickpadDown,
                      !RemoteInputHandler.isRingJogging, !self.swipeScrubEntered else { return false }
                return self.contentOwnsPress(direction == .up ? .upArrow : .downArrow)
            },
            onSwipe: { [weak self] direction in
                guard let self else { return }
                self.swipeTouchSpent = true
                self.handleContentVertical(up: direction == .up)
            }
        )

        // Pan gesture for swipe-to-scrub on the Siri Remote touchpad.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        // Indirect touches only (the touchpad, not the screen).
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        // Observes alongside every recognizer and acts only once `SwipeScrubAxisLock`
        // locks the touch horizontal.
        pan.cancelsTouchesInView = false
        pan.delegate = self
        view.addGestureRecognizer(pan)
        panRecognizer = pan

        // Bare tap on the touch surface (no click): shows the timeline.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTouchSurfaceTap))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        // tvOS defaults allowedPressTypes to [.select], which would wait for a click.
        tap.allowedPressTypes = []
        view.addGestureRecognizer(tap)

        // Double tap zooms, as AVKit's tap-to-zoom does (#589). The single tap
        // waits it out, which is the same short delay AVKit pays.
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleTouchSurfaceDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        doubleTap.allowedPressTypes = []
        view.addGestureRecognizer(doubleTap)
        tap.require(toFail: doubleTap)
    }

    /// Wires the scrubber proxy's own Left/Right/Select into the same grammar.
    func wire(scrubberProxy proxy: ScrubberFocusProxyView) {
        // Controls-focus mode stays active so the GameController seek path stays
        // swallowed and no press seeks twice.
        proxy.isScrubbingProvider = { [weak self] in self?.host?.isScrubbing ?? false }
        proxy.onSkip = { [weak self] forward in
            guard let self, let host = self.host else { return }
            self.coordinator.handle(action: .stepSeek(forward: forward), source: .irPress)
            host.showControlsTemporarily()
        }
        proxy.onShuttle = { [weak self] forward in
            guard let host = self?.host else { return }
            host.scrubInDirection(forward: forward)
            host.showControlsTemporarily()
        }
        proxy.onSelect = { [weak self] in self?.scrubberSelect() }
    }

    /// Center commits an active scrub; otherwise it toggles play/pause, as Apple's
    /// system player does, with the chrome up or not.
    private func scrubberSelect() {
        guard let host else { return }
        if host.isScrubbing {
            coordinator.handle(action: .scrubCommit, source: .irPress)
        } else if let forward = edgeClickDirection() {
            // A 1st-gen Siri Remote edge click skips here too, as it does from the content state.
            coordinator.handle(action: .stepSeek(forward: forward), source: .irPress)
            host.showControlsTemporarily()
        } else if !host.controlsVisible {
            // The proxy keeps focus after the rail auto-hides, so the click arrives here.
            selectFromContent()
        } else {
            coordinator.handle(action: .playPause, source: .irPress)
        }
    }

    // MARK: - Lifecycle

    /// Starts the ring jog and clickpad state. Safe to call on every appearance.
    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        remote.startMonitoring()
    }

    func stop() {
        blockDismissResetWorkItem?.cancel()
        blockDismissResetWorkItem = nil
        guard isMonitoring else { return }
        isMonitoring = false
        remote.stopMonitoring()
        remote.reset()
    }

    /// Drops a Left/Right or Select press in flight (the host's state changed under it).
    func cancelPendingPress() {
        contentPressDetector.cancel()
        contentDirectionalPressType = nil
        contentSelectPending = false
    }

    /// A gated swipe elsewhere (the skip pill's) took this touch, so it never scrubs.
    func markTouchSpent() {
        swipeTouchSpent = true
    }

    // MARK: - Press forwarding
    //
    // The host forwards its press overrides here and skips `super` when these return true.
    // Menu, Play/Pause, and the content state's arrows and Select. Do not move these to
    // a focused SwiftUI layer, gesture recognizers or GameController (#212, #232, #305).

    func pressesBegan(_ presses: Set<UIPress>) -> Bool {
        guard let host else { return false }
        for press in presses {
            if press.type == .menu {
                isHandlingMenuPress = true
                handleMenuPress()
                return true
            }
            if press.type == .select {
                if host.isScrubbing {
                    isHandlingSelectPress = true
                    // A 1st-gen Siri Remote edge click while shuttling bumps the
                    // speed, as an arrow press does on later remotes; a centre
                    // click commits.
                    if host.scrubSpeed != 0, contentOwnsPress(.select), let forward = edgeClickDirection() {
                        coordinator.handle(action: .scrubNudge(forward: forward), source: .irPress)
                    } else {
                        coordinator.handle(action: .scrubCommit, source: .irPress)
                    }
                    return true
                }
                if contentOwnsPress(.select) {
                    beginContentSelect()
                }
                return true
            }
            if press.type == .playPause {
                // Always honored, whatever holds focus: rail buttons, the scrubber stop,
                // the content anchor, or an open panel. Commits an active scrub, else toggles.
                isHandlingPlayPausePress = true
                coordinator.handle(action: .playPause, source: .irPress)
                return true
            }
            if Self.isArrow(press.type) {
                if RemoteInputHandler.isClickpadDown { Self.clickpadRingSeen = true }
                if contentOwnsPress(press.type) {
                    beginContentArrow(press.type)
                }
                return true
            }
        }
        return false
    }

    func pressesEnded(_ presses: Set<UIPress>) -> Bool {
        for press in presses {
            if press.type == .menu {
                // Menu is always handled at the began phase, either by a popup or by
                // `handleMenuPress`. If focus moved mid-press (a popup closed itself), the
                // ended phase arrives on a responder chain that never saw the began, and
                // letting it bubble triggers the system's default dismiss and peels an
                // extra layer (focus "goes to nil").
                isHandlingMenuPress = false
                return true
            }
            if press.type == .select && isHandlingSelectPress {
                isHandlingSelectPress = false
                return true
            }
            if press.type == .playPause && isHandlingPlayPausePress {
                isHandlingPlayPausePress = false
                return true
            }
            if press.type == .select || Self.isArrow(press.type) {
                endContentPress(press.type)
                return true
            }
        }
        return false
    }

    func pressesCancelled(_ presses: Set<UIPress>) -> Bool {
        for press in presses {
            if press.type == .menu && isHandlingMenuPress {
                isHandlingMenuPress = false
                return true
            }
            if press.type == .select && isHandlingSelectPress {
                isHandlingSelectPress = false
                return true
            }
            if press.type == .playPause && isHandlingPlayPausePress {
                isHandlingPlayPausePress = false
                return true
            }
            if press.type == .select || Self.isArrow(press.type) {
                cancelContentPress(press.type)
                return true
            }
        }
        return false
    }

    /// Arrows and Select stop here, as in the other phases.
    func pressesChanged(_ presses: Set<UIPress>) -> Bool {
        presses.contains { $0.type == .select || Self.isArrow($0.type) }
    }

    // MARK: - Content-state presses
    //
    // The one handler for directional and Select presses when no chrome control
    // owns them: focus on the content anchor, the skip pill, or nowhere.
    // Arrow and Select presses never travel past the host, so the presenter
    // behind the player cannot react to them.

    private static func isArrow(_ type: UIPress.PressType) -> Bool {
        switch type {
        case .upArrow, .downArrow, .leftArrow, .rightArrow: return true
        default: return false
        }
    }

    /// Whether a directional or Select press that reached the host belongs to the content-state grammar.
    func contentOwnsPress(_ type: UIPress.PressType) -> Bool {
        guard let host, !host.postVideoUp, !host.playbackFailed else { return false }
        // A presented rail panel owns its own content's presses.
        if host.panelOwnsPresses { return false }
        guard let view, let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem else { return true }
        // Rail buttons and the scrubber proxy: the focus engine (or the proxy's
        // own press handling) already acted on this press.
        guard let focusedView = focused as? UIView else { return false }
        if focusedView === contentAnchor { return true }
        return host.claimsContentPress(focusedView: focusedView, type: type)
    }

    private func beginContentArrow(_ type: UIPress.PressType) {
        switch type {
        case .upArrow:
            handleContentVertical(up: true)
        case .downArrow:
            handleContentVertical(up: false)
        case .leftArrow, .rightArrow:
            beginContentDirectional(forward: type == .rightArrow, pressType: type)
        default:
            break
        }
    }

    /// Left/Right: a quick release skips (`tapSeekSeconds`), a hold starts the
    /// FF/RW shuttle, and any press while already shuttling bumps or redirects
    /// it at once (ShuttleGrammar) with no tap-vs-hold wait.
    private func beginContentDirectional(forward: Bool, pressType: UIPress.PressType) {
        guard let host else { return }
        if host.isScrubbing && host.scrubSpeed != 0 {
            coordinator.handle(action: .scrubNudge(forward: forward), source: .irPress)
            return
        }
        contentDirectionalPressType = pressType
        contentPressDetector.begin(forward: forward)
    }

    /// Up/Down: while scrubbing, Up snaps to the next chapter in the direction
    /// of travel and Down cancels. Otherwise they surface the controls as AVKit
    /// does: Up lands on the first tool button, Down opens the Info pane.
    func handleContentVertical(up: Bool) {
        guard let host else { return }
        if !up, !host.isScrubbing, host.openPauseInsightsIfOffered() { return }
        host.contentVerticalBegan()
        if host.isScrubbing {
            if up {
                host.chapterSnap()
            } else {
                coordinator.handle(action: .scrubCancel, source: .irPress)
            }
            return
        }
        host.focusControls(on: up ? .firstTool : .infoPane)
    }

    /// Select acts on its release, like the tap gesture it replaces: acting on
    /// the down can move focus mid-press (hiding the chrome hands focus to the
    /// skip pill when a marker is up), and the release would then land on
    /// whatever took focus.
    private func beginContentSelect() {
        if let forward = edgeClickDirection() {
            contentDirectionalPressType = .select
            contentPressDetector.begin(forward: forward)
        } else {
            contentSelectPending = true
        }
    }

    /// A 1st-generation Siri Remote reports EVERY click as `.select`, so its
    /// "click the right edge to skip" can only be recovered from where the
    /// finger rested before the click (tracked by RemoteInputHandler). Later
    /// remotes report edge clicks as arrow presses, which is authoritative;
    /// once one has been seen, a `.select` is only ever a centre click. The
    /// clickpad must be physically down, so a Select from anything else (IR,
    /// CEC, a keyboard's Return, a gamepad's A) never reads a stale touch.
    private func edgeClickDirection() -> Bool? {
        guard !Self.clickpadRingSeen, RemoteInputHandler.isClickpadDown else { return nil }
        return RemoteInputHandler.active?.clickpadEdge
    }

    private func endContentPress(_ type: UIPress.PressType) {
        if type == .select, contentSelectPending {
            contentSelectPending = false
            selectFromContent()
            return
        }
        if type == contentDirectionalPressType {
            contentDirectionalPressType = nil
            contentPressDetector.end()
        }
    }

    private func cancelContentPress(_ type: UIPress.PressType) {
        if type == .select { contentSelectPending = false }
        if type == contentDirectionalPressType {
            contentDirectionalPressType = nil
            contentPressDetector.cancel()
        }
    }

    /// Select with nothing else focused toggles playback and brings the controls up
    /// on the scrubber, as AVKit's click does (#410); a touch-surface tap only shows them.
    private func selectFromContent() {
        guard let host, !host.playbackFailed else { return }
        host.animatePlaybackToggle {
            coordinator.handle(action: .playPause, source: .irPress)
        }
        host.focusControls(on: .scrubber)
    }

    // MARK: - Menu

    /// Menu closes one layer per press: description, error, the host's own layers, an open
    /// panel, then the coordinator's Back (scrub, pause screen, controls, exit).
    func handleMenuPress() {
        guard let host else { return }

        if host.descriptionUp {
            host.closeDescription()
            blockDismissTemporarily()
            return
        }

        // The error overlay is all that is up: Menu closes it, as its Dismiss button does.
        if host.playbackFailed {
            host.exitPlayer()
            return
        }

        // The block matters for each: the system's own dismiss for this press lands after
        // the layer is gone, finds nothing to close, and exits the player.
        if host.closeHostLayer(for: .menuPress) || host.closeOpenPanel(for: .menuPress) {
            blockDismissTemporarily()
            return
        }

        if coordinator.target == nil {
            host.handleBackWithoutTarget()
            return
        }

        if host.backClosesChrome {
            blockDismissTemporarily()
        }
        coordinator.handle(action: .back, source: .irPress)
    }

    /// True once per consumed Menu press: the system's dismiss echo, to swallow.
    func consumesDismissEcho() -> Bool {
        guard blockNextDismiss else { return false }
        blockNextDismiss = false
        return true
    }

    /// The layer peel for a system dismiss that no press handled. True if it closed something.
    func peelForSystemDismiss() -> Bool {
        guard let host else { return false }
        if host.closeHostLayer(for: .systemDismiss) { return true }
        if host.isScrubbing {
            host.cancelScrub()
            return true
        }
        if host.closeOpenPanel(for: .systemDismiss) { return true }
        return host.peelChromeLayer()
    }

    func blockDismissTemporarily() {
        blockNextDismiss = true
        blockDismissResetWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.blockNextDismiss = false
            self?.blockDismissResetWorkItem = nil
        }
        blockDismissResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + InputConfig.blockDismissTimeout, execute: workItem)
    }

    // MARK: - Touch surface

    /// True when a touch-surface swipe may drive the scrubber.
    private var panCanDriveScrub: Bool {
        guard let host else { return false }
        return host.isPaused
            && !host.postVideoUp
            && !host.descriptionUp
            && !focusIsOnTransportButton
            && !host.pauseInsightsUp
    }

    /// Focus is parked on a transport button rather than the scrubber. While
    /// controls focus is active, the scrubber proxy is the only focusable element
    /// that wants swipes; anything else in the rail needs left/right to move
    /// focus, not to seek.
    private var focusIsOnTransportButton: Bool {
        guard host?.controlsFocusActive == true else { return false }
        return host?.scrubberFocused != true
    }

    /// True when the touch-surface tap was the touch half of a clickpad click.
    private var tapWasClick: Bool {
        RemoteInputHandler.isClickpadDown
            || CACurrentMediaTime() - RemoteInputHandler.lastClickpadDownAt < 0.6
            || CACurrentMediaTime() - MenuPressInterceptor.lastPressBeganAt < 0.6
    }

    private var touchSurfaceTapAllowed: Bool {
        guard let host else { return false }
        return !host.isScrubbing
            && !host.postVideoUp
            && !host.playbackFailed
            && !host.descriptionUp
    }

    @objc private func handleTouchSurfaceTap() {
        guard let host, touchSurfaceTapAllowed else { return }

        // With the controls up, a bare tap (not a click) cycles the bar
        // between play time and the clock.
        if host.controlsVisible, !tapWasClick {
            host.toggleClockTimes()
        }
        host.showControlsTemporarily()
    }

    @objc private func handleTouchSurfaceDoubleTap() {
        // A double click is two play/pause presses, never a zoom.
        guard let host, touchSurfaceTapAllowed, !tapWasClick else { return }
        host.toggleFill()
    }

    /// The clickpad is down, or clicked down since the pan began on this touch.
    private var swipeTouchClicked: Bool {
        RemoteInputHandler.isClickpadDown || RemoteInputHandler.lastClickpadDownAt >= swipeTouchBeganAt
    }

    /// Does nothing until `SwipeScrubAxisLock` decides the touch: horizontal scrubs,
    /// vertical and undecided touches belong to the focus engine and the gated swipes.
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let host, let view else { return }
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)

        switch gesture.state {
        case .began, .changed:
            if gesture.state == .began {
                swipeAxisLock.reset()
                swipeScrubEntered = false
                swipeTouchSpent = false
                swipeTouchBeganAt = CACurrentMediaTime()
            }
            // A touch that turned into a ring jog belongs to the jog from then on.
            guard !RemoteInputHandler.isRingJogging else { return }
            // A click jolts the touch into a fake swipe, so it spends the touch.
            if swipeTouchClicked { swipeTouchSpent = true }
            guard !swipeTouchSpent else { return }
            guard swipeAxisLock.axis == .undecided else {
                guard swipeScrubEntered, panCanDriveScrub else { return }
                // The playhead follows the finger; right = forward.
                let dx = Double(translation.x - swipeScrubLastX)
                let speed = abs(Double(velocity.x))
                swipeScrubLastX = translation.x
                let seekDelta = SwipeScrubTransfer.seconds(
                    forTravel: dx, speed: speed, duration: host.scrubSpan)
                noteSwipeScrubSample(travel: dx, speed: speed, seconds: seekDelta)
                coordinator.handle(action: .scrubRelative(seconds: seekDelta), source: .irPress)
                return
            }
            let axis = swipeAxisLock.update(
                translationX: Double(translation.x), translationY: Double(translation.y))
            // Undecided or vertical: the focus engine's and the gated swipes'.
            guard axis == .horizontal else { return }
            guard panCanDriveScrub else {
                DiagLog.notice(.playback, "[scrub] swipe did not start a scrub: "
                    + (focusIsOnTransportButton ? "focus is on a control" : "player state"))
                return
            }
            swipeScrubEntered = true
            swipeScrubLastX = translation.x
            swipeScrubTravel = 0
            swipeScrubPeakSpeed = 0
            swipeScrubNetSeconds = 0
            DiagLog.notice(.playback, "[scrub] swipe started a scrub")
            // The travel that decided the lock counts, at the base rate.
            let lockTravel = Double(translation.x)
            let lockSeconds = SwipeScrubTransfer.baseSeconds(
                forTravel: lockTravel, duration: host.scrubSpan)
            noteSwipeScrubSample(travel: lockTravel, speed: abs(Double(velocity.x)), seconds: lockSeconds)
            coordinator.handle(action: .scrubRelative(seconds: lockSeconds), source: .irPress)

        case .ended, .cancelled:
            if swipeScrubEntered {
                // No post-lift flick; the lift sample may be jitter, so it is not applied.
                let liftTravel = gesture.state == .ended ? Double(translation.x - swipeScrubLastX) : 0
                logSwipeScrubEnd(blocked: swipeScrubBlockedReason, liftTravel: liftTravel)
            } else if gesture.state == .ended, swipeAxisLock.axis != .horizontal,
                      abs(translation.x) >= abs(translation.y) {
                // A sideways touch that never became a scrub says why (#632).
                DiagLog.notice(.playback, "[scrub] swipe did not start a scrub: "
                    + (swipeScrubBlockedReason ?? "not 2:1 sideways past 24 pt")
                    + ", t=\(Int(translation.x)),\(Int(translation.y))")
            }
            swipeScrubEntered = false

        default:
            swipeScrubEntered = false
        }
    }

    /// Adds one sent scrub update to this scrub's diagnostics counts.
    private func noteSwipeScrubSample(travel: Double, speed: Double, seconds: Double) {
        if travel.isFinite { swipeScrubTravel += abs(travel) }
        if speed.isFinite { swipeScrubPeakSpeed = max(swipeScrubPeakSpeed, speed) }
        if seconds.isFinite { swipeScrubNetSeconds += seconds }
    }

    /// One counts-only line per swipe-scrub, for tuning `SwipeScrubTransfer` (#632).
    private func logSwipeScrubEnd(blocked: String?, liftTravel: Double) {
        let runtimeMinutes = (host?.scrubSpan ?? 0) / 60
        let counts = String(
            format: "travel=%.0fpt peak=%.0fpt/s net=%+.1fs runtime=%.0fmin lift=%+.0fpt",
            swipeScrubTravel, swipeScrubPeakSpeed, swipeScrubNetSeconds,
            runtimeMinutes.isFinite ? runtimeMinutes : 0, liftTravel.isFinite ? liftTravel : 0)
        DiagLog.notice(.playback, "[scrub] swipe ended" + (blocked.map { " blocked: \($0);" } ?? ":") + " " + counts)
    }

    /// Why this touch cannot drive a scrub now, or nil if it can, for the diagnostics lines (#632).
    private var swipeScrubBlockedReason: String? {
        if RemoteInputHandler.isRingJogging { return "ring jog" }
        if swipeTouchClicked { return "clickpad down" }
        if swipeTouchSpent { return "an Up or Down swipe took it" }
        if host?.isPaused != true { return "not paused" }
        if !panCanDriveScrub { return focusIsOnTransportButton ? "focus is on a control" : "player state" }
        return nil
    }

    // MARK: - UIGestureRecognizerDelegate

    /// Lets the scrub pan begin where a scrub could start; the axis is decided later.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
              pan === panRecognizer, let host, let view
        else { return true }

        // Insights over the pause screen pages its cards sideways.
        guard !host.pauseInsightsUp else { return false }
        let velocity = pan.velocity(in: view)
        guard panCanDriveScrub else {
            return refuseScrub(focusIsOnTransportButton ? "focus is on a control" : "player state", velocity)
        }

        // Never while the clickpad is down: a click jolts the touch into a fake swipe.
        guard !RemoteInputHandler.isClickpadDown else { return refuseScrub("clickpad down", velocity) }
        guard !RemoteInputHandler.isRingJogging else { return refuseScrub("ring jog", velocity) }
        return true
    }

    /// The scrub pan never takes a swipe from the focus engine or the gated swipes.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === panRecognizer || otherGestureRecognizer === panRecognizer
    }

    /// A sideways swipe that did not start a scrub leaves a line for Send Diagnostics (#632).
    /// Vertical swipes are the focus engine's and say nothing.
    private func refuseScrub(_ why: String, _ velocity: CGPoint) -> Bool {
        if abs(velocity.x) >= abs(velocity.y) {
            DiagLog.notice(.playback, "[scrub] swipe did not start a scrub: \(why)")
        }
        return false
    }
}
