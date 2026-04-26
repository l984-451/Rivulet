//
//  UniversalPlayerView.swift
//  Rivulet
//
//  Universal video player using RivuletPlayer
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

    private var holdTimers: [DirectionalInputKey: Timer] = [:]
    private var holdDirections: [DirectionalInputKey: Bool] = [:]
    private var clickedDirection: Bool?
    private var currentDpadDirection: Bool?
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

    var onAction: ((PlaybackInputAction, PlaybackInputSource) -> Void)?

    private var controllerObserver: NSObjectProtocol?
    private var controllerDisconnectObserver: NSObjectProtocol?
    private var keyboardConnectObserver: NSObjectProtocol?
    private var keyboardDisconnectObserver: NSObjectProtocol?

    private var isScrubbing: Bool {
        isScrubbingCheck?() ?? false
    }

    func startMonitoring() {
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
        holdTimers.values.forEach { $0.invalidate() }
        holdTimers.removeAll()
        holdDirections.removeAll()
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

            // Don't capture dpad when post-video is showing - let SwiftUI handle focus
            if self.isPostVideoCheck?() == true {
                return
            }

            let dir: Bool? = if xValue > InputConfig.dpadThreshold {
                true  // right
            } else if xValue < -InputConfig.dpadThreshold {
                false  // left
            } else {
                nil  // center
            }

            // Calculate radius and angle for click wheel rotation
            let radius = sqrt(xValue * xValue + yValue * yValue)
            let angle = atan2(yValue, xValue)

            Task { @MainActor in
                // Ignore dpad changes while button is pressed (click disrupts touch sensing)
                guard !self.isButtonDown else { return }

                // Track left/right direction for tap/hold detection
                if self.currentDpadDirection != dir {
                }
                self.currentDpadDirection = dir

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
                // Don't capture clicks in error state - let SwiftUI dismiss button work
                if self.isErrorCheck?() == true {
                    return
                }

                // Don't capture clicks when post-video overlay is showing - let buttons work
                if self.isPostVideoCheck?() == true {
                    return
                }

                if pressed {
                    self.isButtonDown = true
                    // Use tracked dpad direction (captured before click disrupted sensing)
                    self.handleClickDown(direction: self.currentDpadDirection)
                } else {
                    self.isButtonDown = false
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
                self?.emit(.playPause, source: .extendedGamepad)
            }
        }

        extended.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            Task { @MainActor [weak self] in
                self?.emit(.back, source: .extendedGamepad)
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
                guard let self else { return }
                if pressed {
                    self.beginDirectionalInput(key: .extendedLeft, forward: false, source: .extendedGamepad)
                } else {
                    self.endDirectionalInput(key: .extendedLeft, source: .extendedGamepad)
                }
            }
        }

        extended.dpad.right.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor [weak self] in
                guard let self else { return }
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

                switch keyCode {
                case .spacebar:
                    if pressed { self.emit(.playPause, source: .keyboard) }
                case .returnOrEnter:
                    if pressed { self.emit(.playPause, source: .keyboard) }
                case .escape:
                    if pressed { self.emit(.back, source: .keyboard) }
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

    private func emit(_ action: PlaybackInputAction, source: PlaybackInputSource) {
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

        holdDirections[key] = forward
        holdTimers[key]?.invalidate()
        holdTimers[key] = Timer.scheduledTimer(withTimeInterval: InputConfig.holdThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.holdDirections[key] != nil else { return }
                self.emit(.scrubNudge(forward: forward), source: source)
            }
        }
    }

    private func endDirectionalInput(
        key: DirectionalInputKey,
        source: PlaybackInputSource,
        tapAction: PlaybackInputAction? = nil
    ) {
        defer {
            holdTimers[key]?.invalidate()
            holdTimers[key] = nil
            holdDirections[key] = nil
        }

        guard let timer = holdTimers[key], timer.isValid else { return }
        timer.invalidate()

        if let tapAction {
            emit(tapAction, source: source)
            return
        }

        if let forward = holdDirections[key] {
            emit(.stepSeek(forward: forward), source: source)
        }
    }

    func reset() {
        holdTimers.values.forEach { $0.invalidate() }
        holdTimers.removeAll()
        holdDirections.removeAll()
        clickedDirection = nil
        currentDpadDirection = nil
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
            guard !vm.showInfoPanel, vm.postVideoState == .hidden else { return }
            if vm.isScrubbing {
                vm.updateSwipeScrubPosition(by: seconds)
            } else {
                Task { await vm.seekRelative(by: seconds) }
            }
            vm.showControlsTemporarily()

        case .seekAbsolute(let time):
            guard !vm.showInfoPanel, vm.postVideoState == .hidden else { return }
            Task { await vm.seek(to: time) }
            vm.showControlsTemporarily()

        case .stepSeek, .jumpSeek:
            break

        case .scrubNudge(let forward):
            guard !vm.showInfoPanel, vm.postVideoState == .hidden else { return }
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
            guard !vm.showInfoPanel, vm.postVideoState == .hidden else { return }
            guard vm.playbackState == .paused else { return }
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
            guard vm.postVideoState == .hidden else { return }
            if vm.isScrubbing {
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
            }
            if !vm.showInfoPanel {
                vm.resetSettingsPanel()
                withAnimation(.easeOut(duration: 0.3)) {
                    vm.showInfoPanel = true
                }
            }

        case .back:
            if vm.postVideoState != .hidden {
                vm.dismissPostVideo()
                vm.shouldDismiss = true
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
            } else if vm.showInfoPanel {
                withAnimation(.easeOut(duration: 0.3)) {
                    vm.showInfoPanel = false
                }
            } else if vm.showControls {
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
    @FocusState private var isSkipButtonFocused: Bool

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

            // Post-Video Summary Overlay - separate layer with its own focus handling
            if viewModel.postVideoState != .hidden {
                PostVideoSummaryView(viewModel: viewModel)
                    .zIndex(100)
            }
        }
        .animation(.easeInOut(duration: 1.0), value: viewModel.playbackState)
        .animation(.easeInOut(duration: 0.25), value: viewModel.showControls)
        .animation(.spring(response: 0.25, dampingFraction: 0.9), value: viewModel.showInfoPanel)
        .animation(.easeInOut(duration: 0.3), value: viewModel.showSkipButton)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: viewModel.seekIndicator)
        .animation(.easeInOut(duration: 0.5), value: viewModel.showPausedPoster)
        .onPlayPauseCommand {
            // Skip button handles its own press via Button action
            guard !isSkipButtonFocused else { return }

            if viewModel.showInfoPanel {
                // Play/pause should still work when panel is open
                inputCoordinator.handle(action: .playPause, source: .swiftUICommand)
            } else {
                handleSelectCommand()
            }
        }
        // Note: Menu/Back button handling is done in PlayerContainerViewController
        // to intercept the event before SwiftUI can dismiss the player.
        // Do NOT add onExitCommand here - it would fire after PlayerContainerViewController
        // has already processed the event, causing double-handling.
        .onAppear {
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
            remoteInput.onAction = { [inputCoordinator] action, source in
                inputCoordinator.handle(action: action, source: source)
            }
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
        // Manage focus scope when settings panel opens/closes
        .onChange(of: viewModel.showInfoPanel) { _, showPanel in
            if showPanel {
                // Reset skip button focus when info panel opens (button becomes hidden)
                isSkipButtonFocused = false
                viewModel.resetSettingsPanel()
            }
        }
        // Auto-focus skip button when it appears
        .onChange(of: viewModel.showSkipButton) { _, showButton in
            if showButton && !viewModel.showInfoPanel && viewModel.postVideoState == .hidden {
                // Brief delay to ensure button is rendered
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    // Re-check conditions before focusing (state may have changed)
                    if viewModel.showSkipButton && !viewModel.showInfoPanel && viewModel.postVideoState == .hidden {
                        isSkipButtonFocused = true
                    }
                }
            } else if !showButton {
                isSkipButtonFocused = false
            }
        }
        // Manage focus scope for post-video overlay
        .onChange(of: viewModel.postVideoState) { previous, state in
            if previous == .hidden && state != .hidden {
                // Reset skip button focus when post-video opens (button becomes hidden)
                isSkipButtonFocused = false
            }
        }
        // Auto-focus skip button when controls hide (if skip button is visible)
        .onChange(of: viewModel.showControls) { _, showControls in
            if !showControls && viewModel.showSkipButton && !viewModel.showInfoPanel && viewModel.postVideoState == .hidden {
                // Controls just hid, skip button is visible - focus it
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if viewModel.showSkipButton && !viewModel.showInfoPanel && viewModel.postVideoState == .hidden && !viewModel.showControls {
                        isSkipButtonFocused = true
                    }
                }
            }
        }
        // System appearance
    }

    // MARK: - Player Content Layer (all player UI except post-video)

    @ViewBuilder
    private var playerContentLayer: some View {
        ZStack {
            if viewModel.player != nil || viewModel.rivuletPlayer != nil {
                SubtitleOverlayView(
                    subtitleManager: viewModel.subtitleManager,
                    bottomOffset: viewModel.showControls ? 140 : 60
                )
                .ignoresSafeArea()
            }

            // Loading State or Paused Poster (shows after 5s pause)
            if viewModel.playbackState == .loading || viewModel.playbackState == .idle || viewModel.showPausedPoster {
                loadingView
                    .transition(
                        .asymmetric(
                            insertion: .opacity.animation(.easeIn(duration: 1.0)),
                            removal: .opacity.animation(.easeOut(duration: 0.5))
                        )
                    )
            }

            // Buffering Indicator
            if viewModel.isBuffering && viewModel.playbackState != .loading {
                bufferingIndicator
            }

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

            // Error State
            if case .failed(let error) = viewModel.playbackState {
                errorView(error: error)
            }

            // Skip Button (intro/credits) - shows regardless of controls visibility, but not during post-video
            if viewModel.showSkipButton && !viewModel.showInfoPanel && viewModel.postVideoState == .hidden {
                skipButtonOverlay
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            // Controls Overlay (transport bar at bottom)
            // Always show when scrubbing so user can see the progress bar, but not during post-video
            if (viewModel.showControls || viewModel.isScrubbing) && viewModel.playbackState.isActive && viewModel.postVideoState == .hidden {
                PlayerControlsOverlay(viewModel: viewModel, showInfoPanel: false, hideTitle: viewModel.showPausedPoster)
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            }

            // Info Panel (independent of controls visibility) - slides from top (triggered by d-pad down)
            if viewModel.showInfoPanel {
                VStack {
                    PlayerControlsOverlay(viewModel: viewModel, showInfoPanel: true)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(10)  // Keep above other elements during animation
            }
        }
        // Focusable when skip button is not focused, post-video is not showing, and not in error state
        // When in error state, let the dismiss button receive focus instead
        .focusable(!isSkipButtonFocused && viewModel.postVideoState == .hidden && !viewModel.playbackState.isFailed)
        .contentShape(Rectangle())
        .onTapGesture {
            // Don't toggle controls if info panel is showing or in error state
            guard !viewModel.showInfoPanel else { return }
            guard !viewModel.playbackState.isFailed else { return }

            // Tap anywhere to show/hide controls
            withAnimation(.easeInOut(duration: 0.25)) {
                if viewModel.showControls {
                    viewModel.showControls = false
                } else {
                    viewModel.showControlsTemporarily()
                }
            }
        }
        .onMoveCommand { direction in
            // When post-video is showing, don't handle - let SwiftUI manage button focus
            guard viewModel.postVideoState == .hidden else { return }

            if viewModel.showInfoPanel {
                // Settings panel navigation - 3 column layout
                switch direction {
                case .up:
                    if viewModel.focusedRowIndex == 0 {
                        // At top row - close panel
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                            viewModel.showInfoPanel = false
                        }
                    } else {
                        viewModel.navigateSettings(direction: direction)
                    }
                case .down, .left, .right:
                    viewModel.navigateSettings(direction: direction)
                @unknown default:
                    break
                }
            } else {
                // Left/right are handled by GameController via RemoteHoldDetector
                // for tap vs hold detection. Only handle up/down here.
                handleMoveCommand(direction)
            }
        }
    }

    // MARK: - Player Layer

    @ViewBuilder
    private var playerLayer: some View {
        if let rp = viewModel.rivuletPlayer {
            SampleBufferDisplayView(player: rp)
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

            // Gradient overlay for readability
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

            // Content
            HStack(alignment: .center, spacing: 0) {
                // Left side - metadata
                VStack(alignment: .leading, spacing: 16) {
                    // Show title (for episodes)
                    if let grandparentTitle = viewModel.metadata.grandparentTitle {
                        Text(grandparentTitle)
                            .font(.title2)
                            .fontWeight(.medium)
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    // Main title
                    Text(viewModel.title)
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    // Season/Episode info
                    if let seasonNum = viewModel.metadata.parentIndex,
                       let episodeNum = viewModel.metadata.index {
                        Text("Season \(seasonNum), Episode \(episodeNum)")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    // Year and duration
                    HStack(spacing: 16) {
                        if let year = viewModel.metadata.year {
                            Text(String(year))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        if let duration = viewModel.metadata.duration {
                            Text(formatDuration(duration))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        if let rating = viewModel.metadata.contentRating {
                            Text(rating)
                                .foregroundStyle(.white.opacity(0.6))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(.white.opacity(0.3), lineWidth: 1)
                                )
                        }
                    }
                    .font(.body)

                    // Description - prefer tagline (short), fallback to summary (long, ellipsed)
                    if let tagline = viewModel.metadata.tagline, !tagline.isEmpty {
                        Text(tagline)
                            .font(.system(size: 32, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(3)
                            .padding(.top, 24)
                    } else if let summary = viewModel.metadata.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(6)
                            .padding(.top, 24)
                    }

                    Spacer(minLength: 120)  // Leave room above scrubber

                    // Loading indicator (only show when actually loading, not when paused)
                    if !viewModel.showPausedPoster {
                        HStack(spacing: 12) {
                            ProgressView()
                                .tint(.white)
                            Text("Loading...")
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                .frame(maxWidth: 700, alignment: .leading)
                .padding(.leading, 80)
                .padding(.vertical, 60)

                Spacer()

                // Right side - poster/thumbnail (passed from detail view - instant display)
                if let thumbImage = viewModel.loadingThumbImage {
                    let isLandscape = thumbImage.size.width > thumbImage.size.height
                    Image(uiImage: thumbImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: isLandscape ? 700 : nil, maxHeight: 500)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 10)
                        .padding(.trailing, 80)
                }
            }
        }
    }

    private func formatDuration(_ milliseconds: Int) -> String {
        let totalMinutes = milliseconds / 60000
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    // MARK: - Buffering Indicator

    private var bufferingIndicator: some View {
        ProgressView()
            .scaleEffect(1.5)
            .tint(.white)
            .padding(20)
            .background(
                Circle()
                    .fill(.black.opacity(0.5))
            )
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
        VStack(spacing: 24) {
            Image(systemName: errorIcon(for: error))
                .font(.system(size: 60))
                .foregroundStyle(errorIconColor(for: error))

            Text(errorTitle(for: error))
                .font(.title)
                .foregroundStyle(.white)

            Text(error.userFacingDescription)
                .font(.body)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 60)

            HStack(spacing: 20) {
                if error.isRetryable {
                    Button("Try Again") {
                        Task { await viewModel.retryPlayback() }
                    }
                    .buttonStyle(AppStoreButtonStyle())
                }

                Button("Dismiss") {
                    viewModel.shouldDismiss = true
                }
                .buttonStyle(AppStoreButtonStyle())
            }
            .padding(.top, 20)
        }
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
        }
    }

    // MARK: - Skip Button Overlay

    /// Returns the skip button label, appending countdown if active
    private var skipButtonDisplayLabel: String {
        if viewModel.introSkipCountdownSeconds > 0 {
            return "\(viewModel.skipButtonLabel) (\(viewModel.introSkipCountdownSeconds))"
        }
        return viewModel.skipButtonLabel
    }

    private var skipButtonOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    Task { await viewModel.skipActiveMarker() }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 20, weight: .semibold))
                        Text(skipButtonDisplayLabel)
                            .font(.system(size: 24, weight: .semibold))
                            .contentTransition(.numericText())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.black.opacity(isSkipButtonFocused ? 0.75 : 0.55))
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(.ultraThinMaterial)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(
                                        isSkipButtonFocused ? .white : .white.opacity(0.15),
                                        lineWidth: isSkipButtonFocused ? 3 : 1
                                    )
                            )
                    )
                    // Focused glow effect - makes selection very obvious
                    .shadow(
                        color: isSkipButtonFocused ? .white.opacity(0.5) : .clear,
                        radius: 16,
                        x: 0,
                        y: 0
                    )
                    // Drop shadow for depth
                    .shadow(
                        color: .black.opacity(0.4),
                        radius: 8,
                        x: 0,
                        y: 4
                    )
                    .scaleEffect(isSkipButtonFocused ? 1.08 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSkipButtonFocused)
                }
                .buttonStyle(CardButtonStyle())
                .focused($isSkipButtonFocused)
            }
            .padding(.trailing, 80)
            // Move button up when controls are visible to avoid overlap with transport bar
            .padding(.bottom, viewModel.showControls ? 200 : 80)
            .animation(.easeInOut(duration: 0.25), value: viewModel.showControls)
        }
    }

    // MARK: - Input Handling

    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        // Hide paused poster on any d-pad input
        viewModel.hidePausedPoster()

        switch direction {
        case .left:
            inputCoordinator.handle(action: .stepSeek(forward: false), source: .swiftUICommand)
        case .right:
            inputCoordinator.handle(action: .stepSeek(forward: true), source: .swiftUICommand)
        case .down:
            if isSkipButtonFocused {
                // Down from skip button: unfocus skip button, show controls
                isSkipButtonFocused = false
                viewModel.showControlsTemporarily()
                return
            }
            // Show info panel (cancels any active scrubbing)
            if viewModel.isScrubbing {
                inputCoordinator.handle(action: .scrubCancel, source: .swiftUICommand)
            }
            inputCoordinator.handle(action: .showInfo, source: .swiftUICommand)
        case .up:
            // If skip button is visible and controls are showing, focus skip button
            if viewModel.showSkipButton && viewModel.showControls && !isSkipButtonFocused {
                isSkipButtonFocused = true
                return
            }
            // Cancel scrubbing on up
            if viewModel.isScrubbing {
                inputCoordinator.handle(action: .scrubCancel, source: .swiftUICommand)
            }
        @unknown default:
            break
        }
    }

    private func handleSelectCommand() {
        // Only handle skip if button is actually visible AND focused
        let skipButtonVisible = viewModel.showSkipButton && !viewModel.showInfoPanel && viewModel.postVideoState == .hidden
        if isSkipButtonFocused && skipButtonVisible {
            // Skip button is focused - trigger skip
            Task { await viewModel.skipActiveMarker() }
            return
        }
        inputCoordinator.handle(action: .playPause, source: .swiftUICommand)
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
