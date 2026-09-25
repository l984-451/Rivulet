// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  UniversalPlayerView.swift
//  Rivulet
//
//  Universal VOD video player container
//

import SwiftUI
import Combine
import GameController

// MARK: - Simple Remote Input Handler

/// Simplified remote input detection using GameController.
/// Reads dpad position synchronously when button is pressed to avoid race conditions.
@MainActor
final class RemoteInputHandler: ObservableObject {
    private enum DirectionalInputKey: Hashable {
        case microClick
        case extendedLeft
        case extendedRight
        case keyboardLeft
        case keyboardRight
    }

    /// One tap-vs-hold detector per key — see `DirectionalPressDetector`.
    private var directionalDetectors: [DirectionalInputKey: DirectionalPressDetector] = [:]
    private var clickedDirection: Bool?
    private var currentDpadDirection: Bool?
    /// Last touch position on the clickpad, frozen while a click is down.
    private var lastTouch: (x: Float, y: Float)?
    private var isButtonDown = false

    // Click wheel rotation tracking (iPod-style)
    private var lastAngle: Float?
    private var accumulatedRotation: Float = 0

    // Check viewModel's scrubbing state (single source of truth)
    var isScrubbingCheck: (() -> Bool)?
    // Check if actively scrubbing with timer (hold-based), vs passive scrubbing (swipe/wheel)
    var isActivelyScrubbing: (() -> Bool)?
    // Check if player is in error state (don't capture clicks - let dismiss button work)
    var isErrorCheck: (() -> Bool)?
    // Check if post-video overlay is showing (don't capture clicks - let buttons work)
    var isPostVideoCheck: (() -> Bool)?
    // Check if player is paused (taps start scrubbing when paused)
    var isPausedCheck: (() -> Bool)?

    /// True while the transport bar's buttons own focus. Directional and
    /// seek input then belongs to the focus engine, not this handler.
    var isControlsFocusCheck: (() -> Bool)?

    /// True while the Skip pill owns focus (chrome hidden). The pill handles
    /// Select itself as a UIPress, so this handler must swallow the keyboard/
    /// Menu MIRRORS of that same press (Enter→play/pause, Esc→back) that would
    /// otherwise pause the video and pop the chrome. Seek and real play/pause
    /// still pass through, so left/right keeps scrubbing behind the pill.
    var isSkipPillFocusCheck: (() -> Bool)?

    var onAction: ((PlaybackInputAction, PlaybackInputSource) -> Void)?

    /// Set by a host whose own responder chain handles every input tvOS ALSO
    /// delivers as a `UIPress`: clickpad-ring clicks (arrow presses), a game
    /// controller's d-pad and B, a keyboard's arrows and Escape. For those the
    /// GameController copy is a mirror of a press the host already acted on,
    /// and listening to both is what made one click land zero, one or two
    /// skips depending on which copy arrived first (and when the two paths
    /// disagreed on direction, a left click and a phantom right click summed
    /// to no skip at all). With this set, the handler only acts on clickpad
    /// rotation, shoulder buttons, X, a gamepad's A and the keyboard's Space /
    /// Return / I. A and Return still double as Select presses (so they toggle
    /// playback here and the controls in the host), as they always have. The
    /// VOD player sets it (`PlayerContainerViewController` owns its presses);
    /// Live TV's Channels layout still relies on the mirrors and leaves it off.
    var uikitOwnsPresses = false

    /// The monitoring handler, so the VOD container can ask where the finger
    /// rested before a click without owning GameController itself (its
    /// handlers are single-slot, so a second listener would clobber this one).
    private(set) static weak var active: RemoteInputHandler?

    /// Horizontal edge the finger rested on just before the current (or last)
    /// clickpad click: true = right, false = left, nil = centre, vertical, or
    /// no touch reported (a clicks-only clickpad reports none). Frozen for the
    /// duration of a click, because the click itself disturbs touch sensing.
    /// Uses the stricter `edgeClickThreshold`: it decides whether a centre
    /// `.select` was really an edge click, and a wrong yes skips the video.
    var clickpadEdge: Bool? {
        guard let lastTouch else { return nil }
        return InputConfig.clickpadHorizontalDirection(
            x: lastTouch.x, y: lastTouch.y, threshold: InputConfig.edgeClickThreshold)
    }

    private var controllerObserver: NSObjectProtocol?
    private var controllerDisconnectObserver: NSObjectProtocol?
    private var keyboardConnectObserver: NSObjectProtocol?
    private var keyboardDisconnectObserver: NSObjectProtocol?

    private var isScrubbing: Bool {
        isScrubbingCheck?() ?? false
    }

    func startMonitoring() {
        Self.active = self
        for controller in GCController.controllers() {
            setupController(controller)
        }
        setupKeyboard()

        controllerObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let controller = notification.object as? GCController {
                Task { @MainActor [weak self] in
                    self?.setupController(controller)
                }
            }
        }

        controllerDisconnectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let controller = notification.object as? GCController {
                Task { @MainActor [weak self] in
                    self?.teardownController(controller)
                }
            }
        }

        keyboardConnectObserver = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.setupKeyboard()
            }
        }

        keyboardDisconnectObserver = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.teardownKeyboard()
            }
        }
    }

    func stopMonitoring() {
        if Self.active === self { Self.active = nil }
        for controller in GCController.controllers() {
            teardownController(controller)
        }
        teardownKeyboard()

        if let observer = controllerObserver {
            NotificationCenter.default.removeObserver(observer)
            controllerObserver = nil
        }
        if let observer = controllerDisconnectObserver {
            NotificationCenter.default.removeObserver(observer)
            controllerDisconnectObserver = nil
        }
        if let observer = keyboardConnectObserver {
            NotificationCenter.default.removeObserver(observer)
            keyboardConnectObserver = nil
        }
        if let observer = keyboardDisconnectObserver {
            NotificationCenter.default.removeObserver(observer)
            keyboardDisconnectObserver = nil
        }
        directionalDetectors.values.forEach { $0.cancel() }
    }

    private func setupController(_ controller: GCController) {
        if let extended = controller.extendedGamepad {
            setupExtendedGamepad(extended)
            return
        }

        guard let micro = controller.microGamepad else { return }
        setupMicroGamepad(micro)
    }

    private func teardownController(_ controller: GCController) {
        controller.microGamepad?.dpad.valueChangedHandler = nil
        controller.microGamepad?.buttonA.pressedChangedHandler = nil

        controller.extendedGamepad?.dpad.left.pressedChangedHandler = nil
        controller.extendedGamepad?.dpad.right.pressedChangedHandler = nil
        controller.extendedGamepad?.leftShoulder.pressedChangedHandler = nil
        controller.extendedGamepad?.rightShoulder.pressedChangedHandler = nil
        controller.extendedGamepad?.buttonA.pressedChangedHandler = nil
        controller.extendedGamepad?.buttonB.pressedChangedHandler = nil
        controller.extendedGamepad?.buttonX.pressedChangedHandler = nil
    }

    private func setupMicroGamepad(_ micro: GCMicroGamepad) {
        micro.reportsAbsoluteDpadValues = true

        // Track dpad position and detect circular rotation (iPod-style click wheel)
        micro.dpad.valueChangedHandler = { [weak self] (dpad, xValue, yValue) in
            guard let self else { return }

            // Calculate radius and angle for click wheel rotation
            let radius = sqrt(xValue * xValue + yValue * yValue)
            let angle = atan2(yValue, xValue)

            Task { @MainActor in
                // Ignore dpad changes while button is pressed (click disrupts touch sensing)
                guard !self.isButtonDown else { return }

                // Position is tracked in every state, so the edge a click reads
                // is never left over from before post-video appeared.
                self.lastTouch = (xValue, yValue)
                let dir = InputConfig.clickpadHorizontalDirection(x: xValue, y: yValue)

                // Track left/right direction for tap/hold detection
                if self.currentDpadDirection != dir {
                    InputProbe.gamepad("micro dpad dir=\(dir.map { $0 ? "right" : "left" } ?? "center")")
                }
                self.currentDpadDirection = dir

                // Don't drive rotation while post-video is showing - its
                // buttons own the remote.
                if self.isPostVideoCheck?() == true {
                    self.lastAngle = nil
                    self.accumulatedRotation = 0
                    return
                }

                // Click wheel rotation: only track when finger is on outer edge
                if radius > InputConfig.wheelRadiusThreshold {
                    if let lastAngle = self.lastAngle {
                        var delta = angle - lastAngle

                        // Handle wrap-around at ±π
                        if delta > .pi { delta -= 2 * .pi }
                        if delta < -.pi { delta += 2 * .pi }

                        self.accumulatedRotation += delta

                        // Trigger rotation callback when threshold exceeded
                        if abs(self.accumulatedRotation) > InputConfig.wheelRotationThreshold {
                            let rotation = self.accumulatedRotation
                            self.accumulatedRotation = 0
                            if self.isPausedCheck?() == true {
                                let seekSeconds = TimeInterval(rotation) * InputConfig.wheelSecondsPerRadian
                                self.emit(.scrubRelative(seconds: seekSeconds), source: .siriMicroGamepad)
                            }
                        }
                    }
                    self.lastAngle = angle
                } else {
                    // Finger moved to center - reset rotation tracking
                    self.lastAngle = nil
                    self.accumulatedRotation = 0
                }
            }
        }

        // Handle buttonA click (physical press on touchpad)
        micro.buttonA.pressedChangedHandler = { [weak self] (button, value, pressed) in
            guard let self else { return }

            Task { @MainActor in
                // Logged before the gates below, so a swallowed click is still
                // visible as a click that arrived.
                InputProbe.gamepad("micro buttonA \(pressed ? "down" : "up")")

                // Physical state first, before any gate. The gates below used
                // to return before this, and they are not symmetric in time: an
                // Up/Down click that raises the rail passes the gate on the way
                // down and hits it on the way up. That stranded `isButtonDown`
                // true, which froze the tracked touch position (clickpad
                // rotation went dead) until some later click happened to
                // release ungated, and that click then skipped in whatever
                // direction was frozen, not the one the user clicked.
                self.isButtonDown = pressed

                // The host acts on this click as the arrow or select UIPress it
                // also arrives as. See `uikitOwnsPresses`.
                if self.uikitOwnsPresses { return }

                // Error state: let the SwiftUI dismiss button work. Post-video:
                // let its buttons work. Transport bar focused: Select belongs to
                // the focused control (the same click also arrives as a .select
                // press), not play/pause.
                let gated = self.isErrorCheck?() == true
                    || self.isPostVideoCheck?() == true
                    || self.isControlsFocusCheck?() == true

                if pressed {
                    guard !gated else { return }
                    // Use tracked dpad direction (captured before click disrupted sensing)
                    self.handleClickDown(direction: self.currentDpadDirection)
                } else if gated {
                    // Released into a state that owns the click elsewhere: drop
                    // it, so nothing fires later from a stale direction.
                    self.cancelClick()
                } else {
                    self.handleClickUp(source: .siriMicroGamepad)
                }
            }
        }
    }

    private func setupExtendedGamepad(_ extended: GCExtendedGamepad) {
        extended.leftShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            Task { @MainActor [weak self] in
                self?.emit(.jumpSeek(forward: false), source: .extendedGamepad)
            }
        }

        extended.rightShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            Task { @MainActor [weak self] in
                self?.emit(.jumpSeek(forward: true), source: .extendedGamepad)
            }
        }

        extended.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Select belongs to the focused transport-bar control while
                // controls-focus mode is active (buttonA also routes to the
                // focus engine as a .select press).
                if self.isControlsFocusCheck?() == true { return }
                self.emit(.playPause, source: .extendedGamepad)
            }
        }

        extended.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            Task { @MainActor [weak self] in
                // B also arrives as a .menu press. When the host owns presses,
                // acting on this copy too peels TWO layers per press (hide the
                // controls, then exit the player) whenever the pair lands
                // further apart than the coordinator's dedupe window.
                guard let self, !self.uikitOwnsPresses else { return }
                self.emit(.back, source: .extendedGamepad)
            }
        }

        extended.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            Task { @MainActor [weak self] in
                self?.emit(.showInfo, source: .extendedGamepad)
            }
        }

        extended.dpad.left.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor [weak self] in
                // The d-pad also arrives as arrow presses; see `uikitOwnsPresses`.
                guard let self, !self.uikitOwnsPresses else { return }
                if pressed {
                    self.beginDirectionalInput(key: .extendedLeft, forward: false, source: .extendedGamepad)
                } else {
                    self.endDirectionalInput(key: .extendedLeft, source: .extendedGamepad)
                }
            }
        }

        extended.dpad.right.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor [weak self] in
                guard let self, !self.uikitOwnsPresses else { return }
                if pressed {
                    self.beginDirectionalInput(key: .extendedRight, forward: true, source: .extendedGamepad)
                } else {
                    self.endDirectionalInput(key: .extendedRight, source: .extendedGamepad)
                }
            }
        }
    }

    private func setupKeyboard() {
        guard let keyboardInput = GCKeyboard.coalesced?.keyboardInput else { return }

        keyboardInput.keyChangedHandler = { [weak self] keyboard, _, keyCode, pressed in
            Task { @MainActor [weak self] in
                guard let self else { return }

                // Arrow keys also arrive as arrow presses, and a host that owns
                // presses reads Shift itself (`isShiftHeld`).
                if self.uikitOwnsPresses, keyCode == .leftArrow || keyCode == .rightArrow {
                    return
                }

                switch keyCode {
                case .spacebar:
                    if pressed { self.emit(.playPause, source: .keyboard) }
                case .returnOrEnter:
                    if pressed { self.emit(.playPause, source: .keyboard) }
                case .escape:
                    // Escape also arrives as a .menu press (see buttonB above).
                    if pressed, !self.uikitOwnsPresses { self.emit(.back, source: .keyboard) }
                case .keyI:
                    if pressed { self.emit(.showInfo, source: .keyboard) }
                case .leftArrow:
                    if pressed {
                        self.beginDirectionalInput(key: .keyboardLeft, forward: false, source: .keyboard)
                    } else {
                        self.endDirectionalInput(
                            key: .keyboardLeft,
                            source: .keyboard,
                            tapAction: self.isShiftPressed(keyboard) ? .jumpSeek(forward: false) : .stepSeek(forward: false)
                        )
                    }
                case .rightArrow:
                    if pressed {
                        self.beginDirectionalInput(key: .keyboardRight, forward: true, source: .keyboard)
                    } else {
                        self.endDirectionalInput(
                            key: .keyboardRight,
                            source: .keyboard,
                            tapAction: self.isShiftPressed(keyboard) ? .jumpSeek(forward: true) : .stepSeek(forward: true)
                        )
                    }
                default:
                    break
                }
            }
        }
    }

    private func teardownKeyboard() {
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = nil
    }

    private func isShiftPressed(_ keyboard: GCKeyboardInput) -> Bool {
        let leftShift = keyboard.button(forKeyCode: .leftShift)?.isPressed ?? false
        let rightShift = keyboard.button(forKeyCode: .rightShift)?.isPressed ?? false
        return leftShift || rightShift
    }

    /// Whether a connected keyboard is holding Shift right now. Read by a host
    /// that handles arrow keys as presses, so Shift+arrow still jumps.
    static var isShiftHeld: Bool {
        guard let keyboard = GCKeyboard.coalesced?.keyboardInput else { return false }
        let leftShift = keyboard.button(forKeyCode: .leftShift)?.isPressed ?? false
        let rightShift = keyboard.button(forKeyCode: .rightShift)?.isPressed ?? false
        return leftShift || rightShift
    }

    /// Whether the Siri Remote clickpad is physically depressed right now.
    /// Read synchronously (not from `isButtonDown`, which trails by an async
    /// hop) so a gesture recognizer can decide in `gestureRecognizerShouldBegin`.
    static var isClickpadDown: Bool {
        GCController.controllers().contains { $0.microGamepad?.buttonA.isPressed == true }
    }

    private func emit(_ action: PlaybackInputAction, source: PlaybackInputSource) {
        // While the transport bar's buttons own focus, swallow seek and
        // scrub input so d-pad presses move focus instead of the
        // playhead. Play/pause and back stay meaningful.
        if isControlsFocusCheck?() == true {
            switch action {
            case .play, .pause, .playPause:
                // The keyboard's Enter mirrors Select (the same press is
                // already delivered to the focused control as a UIPress);
                // only real play/pause buttons pass through.
                if source == .keyboard {
                    return
                }
            case .back:
                // Menu always reaches PlayerContainerViewController through
                // the responder chain, which owns the unwind order (popup ->
                // focus mode -> controls -> dismiss). The GameController /
                // keyboard mirrors of the same press would double-peel.
                return
            default:
                return
            }
        } else if isSkipPillFocusCheck?() == true {
            // The Skip pill owns focus and handles Select itself as a UIPress.
            // Swallow only the MIRRORS of that press — the keyboard's Enter
            // (which would toggle play/pause and pop the chrome) and Menu/back
            // (owned by the responder chain). Seek and real play/pause buttons
            // pass through, so left/right still scrubs behind the pill.
            switch action {
            case .play, .pause, .playPause:
                if source == .keyboard {
                    return
                }
            case .back:
                return
            default:
                break
            }
        }
        onAction?(action, source)
    }

    private func handleClickDown(direction: Bool?) {

        guard let forward = direction else {
            // Center click - handled by SwiftUI (play/pause) or confirm scrub
            if isScrubbing {
                endDirectionalInput(key: .microClick, source: .siriMicroGamepad)
                emit(.scrubCommit, source: .siriMicroGamepad)
            }
            return
        }

        clickedDirection = forward
        beginDirectionalInput(key: .microClick, forward: forward, source: .siriMicroGamepad)
    }

    private func handleClickUp(source: PlaybackInputSource) {
        if let forward = clickedDirection {
            let action: PlaybackInputAction = .stepSeek(forward: forward)
            endDirectionalInput(key: .microClick, source: source, tapAction: action)
        }
        clickedDirection = nil
    }

    /// Abandon an in-progress click without firing its tap or its hold.
    private func cancelClick() {
        directionalDetectors[.microClick]?.cancel()
        clickedDirection = nil
    }

    /// Lazily creates the one `DirectionalPressDetector` slot owns per key —
    /// each key tracks an independent press (e.g. an extended gamepad's Left
    /// AND a keyboard's Right could both be held at once).
    private func detector(for key: DirectionalInputKey) -> DirectionalPressDetector {
        if let existing = directionalDetectors[key] { return existing }
        let detector = DirectionalPressDetector()
        directionalDetectors[key] = detector
        return detector
    }

    private func beginDirectionalInput(key: DirectionalInputKey, forward: Bool, source: PlaybackInputSource) {
        if isErrorCheck?() == true {
            return
        }
        if isPostVideoCheck?() == true {
            return
        }

        let activelyScrubbingWithTimer = isActivelyScrubbing?() ?? false
        if isScrubbing && activelyScrubbingWithTimer {
            emit(.scrubNudge(forward: forward), source: source)
            return
        }

        let slot = detector(for: key)
        slot.onHold = { [weak self] forward in self?.emit(.scrubNudge(forward: forward), source: source) }
        slot.onTap = { [weak self] forward in self?.emit(.stepSeek(forward: forward), source: source) }
        slot.begin(forward: forward)
    }

    private func endDirectionalInput(
        key: DirectionalInputKey,
        source: PlaybackInputSource,
        tapAction: PlaybackInputAction? = nil
    ) {
        guard let slot = directionalDetectors[key] else { return }
        if let tapAction {
            slot.end(tapOverride: { [weak self] in self?.emit(tapAction, source: source) })
        } else {
            slot.end()
        }
    }

    func reset() {
        directionalDetectors.values.forEach { $0.cancel() }
        clickedDirection = nil
        currentDpadDirection = nil
        lastTouch = nil
        isButtonDown = false
        // Reset rotation tracking
        lastAngle = nil
        accumulatedRotation = 0
    }
}

@MainActor
private final class UniversalPlaybackInputTarget: PlaybackInputTarget {
    weak var viewModel: UniversalPlayerViewModel?
    var onResetRemoteInput: (() -> Void)?

    init(viewModel: UniversalPlayerViewModel) {
        self.viewModel = viewModel
    }

    var isScrubbingForInput: Bool {
        viewModel?.isScrubbing ?? false
    }

    private func transitionForScrubNudge(
        wasScrubbing: Bool,
        speedBefore: Int,
        speedAfter: Int
    ) -> PlaybackInputTelemetry.ScrubTransition {
        if !wasScrubbing || speedBefore == 0 {
            return .start
        }

        let beforeDirection = speedBefore > 0 ? 1 : -1
        let afterDirection = speedAfter > 0 ? 1 : -1
        if beforeDirection != afterDirection {
            return .reverse
        }
        if abs(speedAfter) > abs(speedBefore) {
            return .speedUp
        }
        if abs(speedAfter) < abs(speedBefore) {
            return .slowDown
        }
        return .start
    }

    func handleInputAction(_ action: PlaybackInputAction, source: PlaybackInputSource) {
        guard let vm = viewModel else { return }

        if vm.playbackState.isFailed {
            if case .back = action {
                vm.shouldDismiss = true
            }
            return
        }

        switch action {
        case .play:
            if vm.isScrubbing {
                let speedBefore = vm.scrubSpeed
                PlaybackInputTelemetry.shared.recordScrubTransition(
                    surface: .vod,
                    transition: .commit,
                    source: source,
                    speedBefore: speedBefore,
                    speedAfter: 0
                )
                Task { await vm.commitScrub() }
                onResetRemoteInput?()
            } else {
                vm.resume()
            }
            vm.showControlsTemporarily()

        case .pause:
            if vm.isScrubbing {
                let speedBefore = vm.scrubSpeed
                PlaybackInputTelemetry.shared.recordScrubTransition(
                    surface: .vod,
                    transition: .commit,
                    source: source,
                    speedBefore: speedBefore,
                    speedAfter: 0
                )
                Task { await vm.commitScrub() }
                onResetRemoteInput?()
            } else {
                vm.pause()
            }
            vm.showControlsTemporarily()

        case .playPause:
            if vm.isScrubbing {
                let speedBefore = vm.scrubSpeed
                PlaybackInputTelemetry.shared.recordScrubTransition(
                    surface: .vod,
                    transition: .commit,
                    source: source,
                    speedBefore: speedBefore,
                    speedAfter: 0
                )
                Task { await vm.commitScrub() }
                onResetRemoteInput?()
            } else {
                vm.togglePlayPause()
            }
            vm.showControlsTemporarily()

        case .seekRelative(let seconds):
            guard vm.postVideoState == .hidden else { return }
            if vm.isScrubbing && vm.scrubSpeed != 0 && source != .mpRemoteCommand {
                // Active shuttle: a plain click bumps/steps-down the
                // multiplier via ShuttleGrammar, same grammar as a
                // long-press nudge. See F1 in final-branch-review.md —
                // clicks must be able to reach the bump, not just holds.
                // Excluded for .mpRemoteCommand: MPRemoteCommand skipForward/
                // skipBackward also emit .seekRelative(±N) (NowPlayingService),
                // and an external skip arriving mid-shuttle should keep its
                // nudge-by-N magnitude rather than bump the multiplier. See R1
                // in final-branch-review.md.
                let wasScrubbing = vm.isScrubbing
                let speedBefore = vm.scrubSpeed
                vm.scrubInDirection(forward: seconds > 0)
                let speedAfter = vm.scrubSpeed
                PlaybackInputTelemetry.shared.recordScrubTransition(
                    surface: .vod,
                    transition: transitionForScrubNudge(
                        wasScrubbing: wasScrubbing,
                        speedBefore: speedBefore,
                        speedAfter: speedAfter
                    ),
                    source: source,
                    speedBefore: speedBefore,
                    speedAfter: speedAfter
                )
            } else if vm.isScrubbing {
                vm.updateSwipeScrubPosition(by: seconds)
            } else {
                Task { await vm.seekRelative(by: seconds) }
            }
            // REFRESH the auto-hide timer when the chrome is already up; do not
            // SUMMON it. A single click with the rail closed is a skip, not a
            // request for chrome. This ran unconditionally, so every skip from a
            // hidden-chrome state raised the rail, and raising it flips
            // `controlsFocusActive`, which disarms the container's own Left/Right
            // recognizers — so the click after a skip did nothing. That is the
            // "sometimes it skips, sometimes it opens the rail, sometimes
            // nothing happens" sequence, and it is one bug, not three.
            if vm.showControls { vm.showControlsTemporarily() }

        case .seekAbsolute(let time):
            guard vm.postVideoState == .hidden else { return }
            vm.clearReplayWindow()
            Task { await vm.seek(to: time) }
            vm.showControlsTemporarily()

        case .stepSeek, .jumpSeek:
            break

        case .scrubNudge(let forward):
            guard vm.postVideoState == .hidden else { return }
            let wasScrubbing = vm.isScrubbing
            let speedBefore = vm.scrubSpeed
            vm.scrubInDirection(forward: forward)
            let speedAfter = vm.scrubSpeed
            PlaybackInputTelemetry.shared.recordScrubTransition(
                surface: .vod,
                transition: transitionForScrubNudge(
                    wasScrubbing: wasScrubbing,
                    speedBefore: speedBefore,
                    speedAfter: speedAfter
                ),
                source: source,
                speedBefore: speedBefore,
                speedAfter: speedAfter
            )
            vm.showControlsTemporarily()

        case .scrubRelative(let seconds):
            guard vm.postVideoState == .hidden else { return }
            // Swipe-to-scrub works during playback as well as while paused.
            // `updateSwipeScrubPosition` enters scrub state on its own (via
            // `startSwipeScrubbing`) without pausing, matching the shuttle path.
            vm.updateSwipeScrubPosition(by: seconds)
            vm.showControlsTemporarily()

        case .scrubCommit:
            guard vm.isScrubbing else { return }
            let speedBefore = vm.scrubSpeed
            PlaybackInputTelemetry.shared.recordScrubTransition(
                surface: .vod,
                transition: .commit,
                source: source,
                speedBefore: speedBefore,
                speedAfter: 0
            )
            Task { await vm.commitScrub() }
            onResetRemoteInput?()
            vm.showControlsTemporarily()

        case .scrubCancel:
            guard vm.isScrubbing else { return }
            let speedBefore = vm.scrubSpeed
            PlaybackInputTelemetry.shared.recordScrubTransition(
                surface: .vod,
                transition: .cancel,
                source: source,
                speedBefore: speedBefore,
                speedAfter: 0
            )
            vm.cancelScrub()
            onResetRemoteInput?()

        case .showInfo:
            // Legacy swipe-down/gamepad/keyboard trigger for the old SwiftUI
            // info panel. Media info is now reached only via the Info pill
            // on the UIKit transport bar, so surface the controls (where the
            // pill lives) instead of leaving the input silently dead.
            guard vm.postVideoState == .hidden else { return }
            vm.showControlsTemporarily()

        case .back:
            if vm.postVideoState != .hidden {
                // Back from the post-video / Up Next overlay returns to the
                // still-playing fullscreen video — it does NOT exit the player.
                // Matches Apple TV convention and the overlays' own
                // .onExitCommand intent (which the UIKit press interception
                // pre-empts, so it has to be honored here too).
                vm.dismissPostVideo()
            } else if vm.isScrubbing {
                let speedBefore = vm.scrubSpeed
                PlaybackInputTelemetry.shared.recordScrubTransition(
                    surface: .vod,
                    transition: .cancel,
                    source: source,
                    speedBefore: speedBefore,
                    speedAfter: 0
                )
                vm.cancelScrub()
                onResetRemoteInput?()
            } else if vm.showPausedPoster {
                // Back with the ambient pause backdrop up returns to the
                // paused frame — it does not exit the player. The timer does
                // not re-arm until the next pause, so the frame stays clean.
                vm.hidePausedPoster()
            } else if vm.controlsFocusActive || vm.showControls {
                // Back from the transport buttons (or from any visible chrome)
                // closes the whole chrome in one press, rather than first
                // de-focusing the buttons onto the scrubber and leaving the rail
                // up. Hiding showControls cascades to clear controlsFocusActive
                // via its didSet, so this single step exits focus mode too.
                withAnimation(.easeOut(duration: 0.25)) {
                    vm.showControls = false
                }
            } else {
                vm.shouldDismiss = true
            }
        }
    }
}

struct UniversalPlayerView: View {
    @StateObject private var viewModel: UniversalPlayerViewModel
    @StateObject private var remoteInput = RemoteInputHandler()
    @State private var inputTarget: UniversalPlaybackInputTarget?
    private let inputCoordinator: PlaybackInputCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var hasStartedPlayback = false
    @State private var lastReportedTime: TimeInterval = 0

    /// Caption appearance for the Aether subtitle overlay. Refreshed on
    /// CaptionAppearance.changedNotification so restyles apply live.
    @State private var captionStyle: CaptionStyle = CaptionAppearance.current()

    /// Full-resolution decode of the ambient-pause backdrop. Loaded via
    /// ImageCacheManager at `.full` (3840px) so it matches the preview
    /// carousel; CachedAsyncImage would decode at the `.thumb` 900px
    /// default and look soft full-screen on a 4K panel.
    @State private var ambientBackdropImage: UIImage?

    /// Initialize with metadata (creates viewModel internally)
    @MainActor
    init(
        metadata: PlexMetadata,
        serverURL: String,
        authToken: String,
        startOffset: TimeInterval? = nil
    ) {
        self.init(
            metadata: metadata,
            serverURL: serverURL,
            authToken: authToken,
            startOffset: startOffset,
            inputCoordinator: PlaybackInputCoordinator()
        )
    }

    /// Initialize with metadata (creates viewModel internally)
    @MainActor
    init(
        metadata: PlexMetadata,
        serverURL: String,
        authToken: String,
        startOffset: TimeInterval? = nil,
        inputCoordinator: PlaybackInputCoordinator
    ) {
        _viewModel = StateObject(wrappedValue: UniversalPlayerViewModel(
            metadata: metadata,
            serverURL: serverURL,
            authToken: authToken,
            startOffset: startOffset
        ))
        self.inputCoordinator = inputCoordinator
    }

    /// Initialize with an externally-created viewModel (for UIViewController presentation)
    @MainActor
    init(viewModel: UniversalPlayerViewModel) {
        self.init(viewModel: viewModel, inputCoordinator: PlaybackInputCoordinator())
    }

    /// Initialize with an externally-created viewModel and shared input coordinator.
    @MainActor
    init(viewModel: UniversalPlayerViewModel, inputCoordinator: PlaybackInputCoordinator) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.inputCoordinator = inputCoordinator
    }

    var body: some View {
        ZStack {
            // Background
            Color.black
                .ignoresSafeArea()
                .zIndex(0)

            // Video player layer - floats above post-video overlay when shrunk
            playerLayer
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .zIndex(viewModel.videoFrameState == .shrunk ? 200 : 1)

            // Player controls and overlays (subtitles, loading, controls, etc.)
            playerContentLayer
                .zIndex(2)

            // Post-video ("Up Next") is UIKit, mounted by
            // PlayerContainerViewController above this hosting view — it needs
            // to be a real focus environment the container can hand focus to.
        }
        .animation(.easeInOut(duration: 1.0), value: viewModel.playbackState)
        .animation(.easeInOut(duration: 0.25), value: viewModel.showControls)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: viewModel.seekIndicator)
        .animation(.easeInOut(duration: 0.5), value: viewModel.pausePresentation)
        // No press handling in this view at all: no .onPlayPauseCommand,
        // .onExitCommand, .onMoveCommand or .onTapGesture. Every press is
        // PlayerContainerViewController's (see its "Content-state presses"),
        // which is the only presenter of this view. A focused SwiftUI layer here
        // kept arrow presses away from the container, so remotes with no
        // GameController copy of the press (IR, HDMI-CEC, a clicks-only Siri
        // Remote) could not skip (#212, #232, #305).
        .onAppear {
            // App Hang triage: mark the player screen as foreground (RIVULET-41).
            AppHangContext.setScreen("player")
            // Wire up remote input callbacks
            let target = UniversalPlaybackInputTarget(viewModel: viewModel)
            target.onResetRemoteInput = { [remoteInput] in
                remoteInput.reset()
            }
            inputTarget = target
            inputCoordinator.target = target

            remoteInput.isScrubbingCheck = { [weak viewModel] in
                viewModel?.isScrubbing ?? false
            }
            remoteInput.isActivelyScrubbing = { [weak viewModel] in
                // Active scrubbing = hold-based with timer running (scrubSpeed != 0)
                // Passive scrubbing = swipe/wheel (scrubSpeed == 0)
                (viewModel?.scrubSpeed ?? 0) != 0
            }
            remoteInput.isErrorCheck = { [weak viewModel] in
                viewModel?.playbackState.isFailed ?? false
            }
            remoteInput.isPostVideoCheck = { [weak viewModel] in
                viewModel?.postVideoState != .hidden
            }
            remoteInput.isPausedCheck = { [weak viewModel] in
                viewModel?.playbackState == .paused
            }
            remoteInput.isControlsFocusCheck = { [weak viewModel] in
                guard let viewModel else { return false }
                // A presented rail panel (Info, Up Next, Insights) owns Left/Right
                // for its own content, and focus inside it is NOT inside the rail,
                // so `controlsFocusActive` is false there. Without this term the
                // GameController path kept seeking behind an open popup — the
                // container's own press handling already stands down for a live
                // panel (`contentOwnsPresses`), and this is its twin.
                return viewModel.controlsFocusActive || viewModel.isRailPanelOpen
            }
            remoteInput.isSkipPillFocusCheck = { [weak viewModel] in
                viewModel?.skipPillOwnsFocus ?? false
            }
            remoteInput.onAction = { [inputCoordinator] action, source in
                inputCoordinator.handle(action: action, source: source)
            }
            // The container acts on every press that also arrives as a UIPress;
            // GameController only adds what has no UIPress (rotation, shoulders).
            remoteInput.uikitOwnsPresses = true
            remoteInput.startMonitoring()
        }
        .task {
            guard !hasStartedPlayback else { return }
            hasStartedPlayback = true
            // Notify that playback is starting (pauses hub polling)
            NotificationCenter.default.post(name: .plexPlaybackStarted, object: nil)
            // Activate audio session BEFORE playback starts
            NowPlayingService.shared.attach(to: viewModel, inputCoordinator: inputCoordinator)
            await viewModel.startPlayback()
        }
        .onDisappear {
            // App Hang triage: left the player; coarse "browse" until the
            // next screen tags itself (RIVULET-41).
            AppHangContext.setScreen("browse")
            // Notify that playback is stopping (resumes hub polling)
            NotificationCenter.default.post(name: .plexPlaybackStopped, object: nil)
            // Stop playback first, then detach from Now Playing
            // (audio session must remain active until player stops)
            viewModel.stopPlayback()
            NowPlayingService.shared.detach()
            reportFinalProgressAndRefresh()
            remoteInput.stopMonitoring()
            remoteInput.reset()
            inputCoordinator.invalidate()
            inputTarget = nil
        }
        .onChange(of: viewModel.currentTime) { _, newTime in
            // Report progress periodically
            reportProgress(time: newTime)
        }
        .onChange(of: viewModel.playbackState) { oldState, newState in
            // Immediately report state changes to Plex
            reportStateChange(from: oldState, to: newState)
        }
        // System appearance
    }

    // MARK: - Player Content Layer (all player UI except post-video)

    @ViewBuilder
    private var playerContentLayer: some View {
        ZStack {
            // Captions are UIKit (`CaptionOverlayView`), mounted by
            // PlayerContainerViewController above the video surface and below
            // the chrome. Nothing subtitle-related belongs in this layer.

            // Loading State or Paused Poster (shows after 5s pause)
            if viewModel.playbackState == .loading || viewModel.playbackState == .idle || viewModel.pausePresentation != .frame {
                if viewModel.pausePresentation != .frame, let ambientURL = viewModel.ambientBackdropURL {
                    // Ambient pause moment: full-resolution backdrop crossfade,
                    // deeper dim once the second (2 minute) tier kicks in.
                    ambientBackdropView(url: ambientURL)
                        .transition(
                            .asymmetric(
                                insertion: .opacity.animation(.easeIn(duration: 1.0)),
                                removal: .opacity.animation(.easeOut(duration: 0.5))
                            )
                        )
                } else {
                    loadingView
                        .transition(
                            .asymmetric(
                                insertion: .opacity.animation(.easeIn(duration: 1.0)),
                                removal: .opacity.animation(.easeOut(duration: 0.5))
                            )
                        )
                }
            }

            // Mid-playback buffering has no centered indicator: the quiet
            // top-left "Loading" cue in PlayerContainerViewController covers
            // it in the same slot the Paused indicator uses.

            // Seek Indicator (10s skip)
            if let indicator = viewModel.seekIndicator {
                seekIndicatorView(indicator)
                    .transition(.scale.combined(with: .opacity))
            }

            // Compatibility Notice (e.g., DV fallback)
            if let notice = viewModel.compatibilityNotice {
                VStack {
                    HStack {
                        Spacer()
                        compatibilityNoticeView(notice)
                    }
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(15)
            }

            // Error State. zIndex above the controls overlay so the
            // SwiftUI focus engine sees the error buttons as topmost.
            // The focus container itself (.focusSection + .defaultFocus
            // + delayed onAppear claim) lives inside PlayerErrorOverlay.
            if case .failed(let error) = viewModel.playbackState {
                errorView(error: error)
                    .zIndex(50)
            }

        }
        // Deliberately NOT focusable. The content-state focus stop is the
        // container's UIKit `ContentFocusAnchorView`; only the error overlay's
        // own buttons take focus in this hierarchy.
    }

    // MARK: - Player Layer

    @ViewBuilder
    private var playerLayer: some View {
        if let aether = viewModel.aetherPlayer {
            // Aether route: host the engine's own render surface. It
            // covers both backends (AVPlayerLayer / sample-buffer layer)
            // and survives internal AVPlayer swaps without rebinding.
            AetherVideoSurfaceView(player: aether)
                .scaleEffect(viewModel.videoFrameState.scale, anchor: .topLeading)
                .offset(viewModel.videoFrameState.offset)
                .animation(.spring(response: 0.5, dampingFraction: 0.85), value: viewModel.videoFrameState)
        } else if let player = viewModel.player, viewModel.streamURL != nil {
            AVPlayerLayerView(player: player)
                .scaleEffect(viewModel.videoFrameState.scale, anchor: .topLeading)
                .offset(viewModel.videoFrameState.offset)
                .animation(.spring(response: 0.5, dampingFraction: 0.85), value: viewModel.videoFrameState)
        }
    }

    // MARK: - Ambient Pause Backdrop

    /// Full-resolution backdrop for the ambient pause moment: full-bleed
    /// raw Plex art decoded at `.full` (3840px) via ImageCacheManager —
    /// same source and decode ceiling as the preview carousel, so it reads
    /// crisp on a 4K panel (CachedAsyncImage would decode at the `.thumb`
    /// 900px default and look soft). A deeper dim overlay layers in once
    /// `pausePresentation` reaches `.dimmed` (OLED burn-in guard after 2
    /// minutes paused).
    /// Bottom inset for the ambient title logo. For a show the logo sits just
    /// above the rail's held episode title (which stays at its rail position
    /// ~278pt off the bottom), keeping the same small gap the logo has from
    /// the rail title normally. For a movie there is no held title, so the
    /// logo floats a touch lower in the lower third.
    private var ambientLogoBottomInset: CGFloat {
        viewModel.metadata.type == "episode" ? 292 : 260
    }

    @ViewBuilder
    private func ambientBackdropView(url: URL) -> some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if let image = ambientBackdropImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .ignoresSafeArea()
            }

            if viewModel.pausePresentation == .dimmed {
                Color.black
                    .opacity(0.35)
                    .ignoresSafeArea()
            }

            // Title logo, sitting just above the rail's episode title. For a
            // show the episode name stays put in the glass rail (kept visible
            // by PlayerRailView.setAmbient); the logo sits the same distance
            // above it that it has from the rail title normally. For a movie
            // there is no held title — the logo just floats in the lower third.
            if let logo = viewModel.titleLogoImage {
                VStack {
                    Spacer()
                    HStack {
                        Image(uiImage: logo)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 500, maxHeight: 130, alignment: .bottomLeading)
                            .padding(.leading, 132)
                            .padding(.bottom, ambientLogoBottomInset)
                        Spacer()
                    }
                }
                .transition(.opacity)
            }
        }
        .task(id: url) {
            ambientBackdropImage = await ImageCacheManager.shared.image(for: url, quality: .full)
        }
        .animation(.easeInOut(duration: 0.5), value: viewModel.pausePresentation)
    }

    // MARK: - Loading View

    private var loadingView: some View {
        ZStack {
            // Solid black background (fallback)
            Color.black
                .ignoresSafeArea()

            // Background art (passed from detail view - instant display)
            if let artImage = viewModel.loadingArtImage {
                Image(uiImage: artImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .ignoresSafeArea()
            }

            // Gradient overlay for readability. The UIKit focus card owns
            // the loading identity (spinner, title, skeleton bars) — this
            // view is now just the full-bleed backdrop it renders above.
            LinearGradient(
                colors: [
                    .black.opacity(0.9),
                    .black.opacity(0.6),
                    .black.opacity(0.4),
                    .black.opacity(0.6)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .ignoresSafeArea()
        }
    }

    // MARK: - Seek Indicator View

    private func seekIndicatorView(_ indicator: SeekIndicator) -> some View {
        Image(systemName: indicator.systemImage)
            .font(.system(size: 48, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 88, height: 88)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.black.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 4)
    }

    // MARK: - Compatibility Notice

    private func compatibilityNoticeView(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
            )
            .padding(.trailing, 36)
            .padding(.top, 24)
    }

    // MARK: - Error View

    private func errorView(error: PlayerError) -> some View {
        PlayerErrorOverlay(
            error: error,
            iconSystemName: errorIcon(for: error),
            iconColor: errorIconColor(for: error),
            title: errorTitle(for: error),
            onRetry: { Task { await viewModel.retryPlayback() } },
            onDismiss: { viewModel.shouldDismiss = true }
        )
    }

    private func errorIcon(for error: PlayerError) -> String {
        switch error {
        case .networkError, .loadFailed:
            return "wifi.exclamationmark"
        case .codecUnsupported:
            return "film.fill"
        case .invalidURL:
            return "link.badge.plus"
        case .unknown:
            return "exclamationmark.triangle.fill"
        case .engineFailure(let kind, _):
            // Reuse the one engine-kind taxonomy instead of opening a third
            // switch over the same strings. "Is this a network thing or a
            // codec thing" is the same question the router already answers.
            switch DirectPlayFailureKind(engineKind: kind) {
            case .network: return "wifi.exclamationmark"
            case .unsupportedCodec: return "film.fill"
            default: return "exclamationmark.triangle.fill"
            }
        }
    }

    private func errorIconColor(for error: PlayerError) -> Color {
        switch error {
        case .networkError, .loadFailed:
            return .orange
        case .codecUnsupported:
            return .red
        default:
            return .yellow
        }
    }

    private func errorTitle(for error: PlayerError) -> String {
        switch error {
        case .networkError:
            return "Connection Problem"
        case .loadFailed:
            return "Couldn't Load Video"
        case .codecUnsupported:
            return "Format Not Supported"
        case .invalidURL:
            return "Invalid Stream"
        case .unknown:
            return "Playback Error"
        case .engineFailure(let kind, _):
            switch DirectPlayFailureKind(engineKind: kind) {
            case .network: return "Connection Problem"
            case .unsupportedCodec: return "Format Not Supported"
            default: return "Playback Error"
            }
        }
    }

    // MARK: - Progress Reporting

    private let reportingInterval: TimeInterval = 10

    private func reportProgress(time: TimeInterval) {
        // Report every 10 seconds
        guard abs(time - lastReportedTime) >= reportingInterval else { return }
        lastReportedTime = time

        Task {
            await PlexProgressReporter.shared.reportProgress(
                ratingKey: viewModel.metadata.ratingKey ?? "",
                time: time,
                duration: viewModel.duration,
                state: viewModel.isPlaying ? "playing" : "paused"
            )
        }
    }

    private func reportFinalProgressAndRefresh() {
        Task {
            // 1. Report stopped state to Plex
            await PlexProgressReporter.shared.reportProgress(
                ratingKey: viewModel.metadata.ratingKey ?? "",
                time: viewModel.currentTime,
                duration: viewModel.duration,
                state: "stopped",
                forceReport: true
            )

            // 2. Mark as watched if > 90% complete
            if viewModel.duration > 0 && viewModel.currentTime / viewModel.duration > 0.9 {
                await PlexProgressReporter.shared.markAsWatched(
                    ratingKey: viewModel.metadata.ratingKey ?? ""
                )
            }

            // 3. Wait for Plex server to process (2 seconds)
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            // 4. Trigger refresh after progress is confirmed
            await MainActor.run {
                NotificationCenter.default.post(name: .plexDataNeedsRefresh, object: nil)
            }
        }
    }

    private func reportStateChange(from oldState: UniversalPlaybackState, to newState: UniversalPlaybackState) {
        // Only report significant state changes
        let plexState: String?
        switch newState {
        case .playing:
            plexState = "playing"
        case .paused:
            plexState = "paused"
        case .ended:
            plexState = "stopped"
        default:
            plexState = nil
        }

        guard let state = plexState else { return }

        Task {
            await PlexProgressReporter.shared.reportProgress(
                ratingKey: viewModel.metadata.ratingKey ?? "",
                time: viewModel.currentTime,
                duration: viewModel.duration,
                state: state,
                forceReport: true
            )
        }
    }
}

// MARK: - Convenience Initializer

extension UniversalPlayerView {
    /// Creates a player view using the shared auth manager for credentials
    init(metadata: PlexMetadata, startOffset: TimeInterval? = nil) {
        let authManager = PlexAuthManager.shared
        self.init(
            metadata: metadata,
            serverURL: authManager.selectedServerURL ?? "",
            authToken: authManager.selectedServerToken ?? "",
            startOffset: startOffset
        )
    }
}

/// Player error overlay with explicit default focus.
///
/// Lifted out of `UniversalPlayerView.errorView` so it can carry its own
/// `@FocusState` and per-button `.focused()` bindings — without that, the
/// error buttons were technically reachable from the Siri Remote (clicks
/// fired their actions) but never visually highlighted, leaving the user
/// unable to tell which button they were about to press. The visual
/// highlight is driven off the outer `@FocusState` rather than
/// `AppStoreButtonStyle`'s broken internal `@FocusState`, which doesn't
/// reliably reflect the button's true focus state when wrapped in a
/// `ButtonStyle.makeBody`.
@MainActor
private struct PlayerErrorOverlay: View {
    let error: PlayerError
    let iconSystemName: String
    let iconColor: Color
    let title: String
    let onRetry: () -> Void
    let onDismiss: () -> Void

    private enum Field: Hashable { case retry, dismiss }

    @FocusState private var focused: Field?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: iconSystemName)
                .font(.system(size: 60))
                .foregroundStyle(iconColor)

            Text(title)
                .font(.title)
                .foregroundStyle(.white)

            Text(error.userFacingDescription)
                .font(.body)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 60)

            HStack(spacing: 20) {
                if error.isRetryable {
                    actionButton(label: "Try Again", field: .retry, action: onRetry)
                }

                actionButton(label: "Dismiss", field: .dismiss, action: onDismiss)
            }
            .padding(.top, 20)
        }
        // focusSection + defaultFocus + delayed onAppear claim, ALL on
        // the same view. Mirrors the proven pattern in
        // WaitingToStartOverlay / HostDisconnectModal in this file.
        // Splitting any of these (e.g. .focusSection at the call site)
        // breaks directional navigation between Try Again and Dismiss.
        .focusSection()
        .defaultFocus($focused, error.isRetryable ? .retry : .dismiss)
        .onAppear {
            // Delay the focus claim slightly: when playbackState
            // transitions to .failed and this overlay mounts, the focus
            // engine takes a tick to register our focus container.
            // Without the delay the @FocusState assignment races and
            // lands before the engine is ready.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focused = error.isRetryable ? .retry : .dismiss
            }
        }
    }

    /// Focus-aware button for the error overlay. Mirrors the visual
    /// language of `AppStoreButtonStyle` but reads the *outer*
    /// `@FocusState` so the highlight reflects actual focus.
    private func actionButton(label: String, field: Field, action: @escaping () -> Void) -> some View {
        let isFocused = focused == field
        return Button(action: action) {
            Text(label)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(isFocused ? .black : .white)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isFocused ? Color.white : Color.white.opacity(0.15))
                )
                .scaleEffect(isFocused ? 1.1 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isFocused)
        }
        .buttonStyle(.plain)
        .focused($focused, equals: field)
        .focusEffectDisabled()
    }
}

#Preview {
    UniversalPlayerView(
        metadata: PlexMetadata(
            ratingKey: "123",
            type: "movie",
            title: "Sample Movie",
            year: 2024,
            duration: 7200000
        ),
        serverURL: "http://localhost:32400",
        authToken: "test-token"
    )
}
