//
//  PlayerContainerViewController.swift
//  Rivulet
//
//  UIViewController wrapper for video player that intercepts Menu button on tvOS.
//  This bypasses SwiftUI's fullScreenCover gesture handling to give us full control.
//

import SwiftUI
import UIKit
import Combine


/// Container view controller that hosts the SwiftUI player view and intercepts button presses.
/// This allows us to handle Menu button presses before SwiftUI dismisses the player.
class PlayerContainerViewController: UIViewController {

    // MARK: - Properties

    private var hostingController: UIHostingController<AnyView>?
    private var cancellables = Set<AnyCancellable>()
    private var panGestureRecognizer: UIPanGestureRecognizer?

    // Directional gesture recognizers for IR remote support
    private var dPadLeftTapGesture: UITapGestureRecognizer?
    private var dPadRightTapGesture: UITapGestureRecognizer?
    private var dPadLeftLongPressGesture: UILongPressGestureRecognizer?
    private var dPadRightLongPressGesture: UILongPressGestureRecognizer?

    private let inputCoordinator: PlaybackInputCoordinator

    /// Reference to the player view model for handling Menu button logic
    weak var viewModel: UniversalPlayerViewModel?

    /// Callback when player is dismissed (to update SwiftUI state)
    var onDismiss: (() -> Void)?

    // MARK: - Initialization

    init<Content: View>(
        rootView: Content,
        viewModel: UniversalPlayerViewModel? = nil,
        inputCoordinator: PlaybackInputCoordinator
    ) {
        self.viewModel = viewModel
        self.inputCoordinator = inputCoordinator
        super.init(nibName: nil, bundle: nil)

        self.modalPresentationStyle = .fullScreen

        let hosting = UIHostingController(rootView: AnyView(rootView))
        hosting.view.backgroundColor = .black
        self.hostingController = hosting
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        if let hosting = hostingController {
            addChild(hosting)
            view.addSubview(hosting.view)
            hosting.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
                hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            ])
            hosting.didMove(toParent: self)
        }

        // Menu button is handled via pressesBegan (not gesture recognizer)
        // to avoid double-firing issues
        // Left/right arrows are handled by SwiftUI's onMoveCommand with RemoteHoldDetector
        // (UIKit gesture recognizers don't receive events when SwiftUI has focus)

        // Pan gesture for swipe-to-scrub on Siri Remote touchpad
        setupPanGesture()

        // Directional gestures for IR remote support (learned remotes, universal remotes)
        // These fire UIPress events with leftArrow/rightArrow, NOT GameController events
        setupDirectionalGestures()

        // Observe viewModel's shouldDismiss property for programmatic dismissal
        viewModel?.$shouldDismiss
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shouldDismiss in
                if shouldDismiss {
                    self?.dismissPlayer()
                }
            }
            .store(in: &cancellables)

    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Ensure we're first responder to intercept all button events
        becomeFirstResponder()
    }

    override var canBecomeFirstResponder: Bool {
        return true
    }

    /// Override dismiss to intercept system-triggered dismissals (e.g., from Menu button)
    /// and only allow dismissal when we've explicitly decided to dismiss.
    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        // If we just handled a menu action that closed something, block this dismiss
        if blockNextDismiss {
            blockNextDismiss = false
            return
        }

        // Check if we have something to close before allowing dismiss
        if let vm = viewModel {
            // Cancel intro skip countdown if active
            if vm.introSkipCountdownSeconds > 0 {
                vm.cancelIntroSkipCountdown()
                return
            }
            if vm.postVideoState != .hidden {
                print("🎮 [DISMISS INTERCEPT] Post-video visible - dismissing normally")
                vm.dismissPostVideo()
                super.dismiss(animated: flag, completion: completion)
                return
            }
            if vm.isScrubbing {
                vm.cancelScrub()
                return
            }
            if vm.showInfoPanel {
                withAnimation(.easeOut(duration: 0.3)) {
                    vm.showInfoPanel = false
                }
                return
            }
            if vm.showControls {
                withAnimation(.easeOut(duration: 0.25)) {
                    vm.showControls = false
                }
                return
            }
        }
        // Nothing to close, allow normal dismiss
        super.dismiss(animated: flag, completion: completion)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        blockDismissResetWorkItem?.cancel()
        blockDismissResetWorkItem = nil

        // Notify when dismissed
        if isBeingDismissed || isMovingFromParent {
            onDismiss?()
        }
    }

    // MARK: - Button Interception (Menu and Select only)
    // Left/right arrows are handled by UITapGestureRecognizer and UILongPressGestureRecognizer
    // configured in setupDirectionalGestures()

    /// Track if we're currently consuming presses
    private var isHandlingMenuPress = false
    private var isHandlingSelectPress = false

    /// Flag to block dismiss calls that occur immediately after we handled a menu action
    /// This prevents the double-handling issue where handleMenuButton() closes something,
    /// then SwiftUI's responder chain also calls dismiss().
    private var blockNextDismiss = false
    private var blockDismissResetWorkItem: DispatchWorkItem?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.type == .menu {
                isHandlingMenuPress = true
                handleMenuButton()
                return
            }
            if press.type == .select {
                if let vm = viewModel {
                    if vm.isScrubbing {
                        isHandlingSelectPress = true
                        inputCoordinator.handle(action: .scrubCommit, source: .irPress)
                        return
                    } else if vm.showInfoPanel {
                        isHandlingSelectPress = true
                        handleSelectButton()
                        return
                    }
                }
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.type == .menu && isHandlingMenuPress {
                isHandlingMenuPress = false
                return
            }
            if press.type == .select && isHandlingSelectPress {
                isHandlingSelectPress = false
                return
            }
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.type == .menu && isHandlingMenuPress {
                isHandlingMenuPress = false
                return
            }
            if press.type == .select && isHandlingSelectPress {
                isHandlingSelectPress = false
                return
            }
        }
        super.pressesCancelled(presses, with: event)
    }

    /// Handle Menu button press with priority:
    /// 1. Cancel intro skip countdown if active
    /// 2. Dismiss post-video overlay if showing
    /// 3. Cancel scrubbing if active
    /// 4. Close info panel if open
    /// 5. Hide controls if visible
    /// 6. Dismiss player if nothing else to close
    private func handleMenuButton() {
        guard let vm = viewModel else {
            print("🎮 [MENU] No viewModel - dismissing player")
            dismissPlayer()
            return
        }

        // Cancel intro skip countdown if active (highest priority)
        if vm.introSkipCountdownSeconds > 0 {
            vm.cancelIntroSkipCountdown()
            blockDismissTemporarily()
            return
        }

        if inputCoordinator.target == nil {
            if vm.postVideoState != .hidden {
                vm.dismissPostVideo()
                dismissPlayer()
            } else if vm.isScrubbing {
                vm.cancelScrub()
            } else if vm.showInfoPanel {
                withAnimation(.easeOut(duration: 0.3)) {
                    vm.showInfoPanel = false
                }
            } else if vm.showControls {
                withAnimation(.easeOut(duration: 0.25)) {
                    vm.showControls = false
                }
            } else {
                dismissPlayer()
            }
            return
        }

        // If we're consuming this menu press in-app (not dismissing), block SwiftUI fallback dismiss briefly.
        let shouldBlockDismiss = vm.postVideoState == .hidden && (vm.isScrubbing || vm.showInfoPanel || vm.showControls)
        if shouldBlockDismiss {
            blockDismissTemporarily()
        }

        inputCoordinator.handle(action: .back, source: .irPress)
    }

    /// Handle Select button press when info panel is open
    private func handleSelectButton() {
        guard let vm = viewModel else { return }
        vm.selectFocusedSetting()
    }

    // MARK: - Swipe-to-Scrub Gesture

    private func setupPanGesture() {
        let panRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
        // Only recognize indirect touches (Siri Remote touchpad, not direct screen touches)
        panRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        view.addGestureRecognizer(panRecognizer)
        panGestureRecognizer = panRecognizer
    }

    // MARK: - Directional Gestures (IR Remote Support)

    /// Sets up gesture recognizers for left/right arrow key presses.
    /// IR remotes (learned remotes, One For All, Harmony, etc.) send UIPress events
    /// rather than GameController events. This ensures FF/RW works on all remote types.
    private func setupDirectionalGestures() {
        // Tap gestures for short press (skip 10 seconds)
        let leftTap = UITapGestureRecognizer(target: self, action: #selector(handleDPadLeftTap))
        leftTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.leftArrow.rawValue)]
        view.addGestureRecognizer(leftTap)
        dPadLeftTapGesture = leftTap

        let rightTap = UITapGestureRecognizer(target: self, action: #selector(handleDPadRightTap))
        rightTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.rightArrow.rawValue)]
        view.addGestureRecognizer(rightTap)
        dPadRightTapGesture = rightTap

        // Long press gestures for hold (start scrubbing)
        let leftLong = UILongPressGestureRecognizer(target: self, action: #selector(handleDPadLeftLongPress(_:)))
        leftLong.allowedPressTypes = [NSNumber(value: UIPress.PressType.leftArrow.rawValue)]
        leftLong.minimumPressDuration = InputConfig.holdThreshold
        view.addGestureRecognizer(leftLong)
        dPadLeftLongPressGesture = leftLong

        let rightLong = UILongPressGestureRecognizer(target: self, action: #selector(handleDPadRightLongPress(_:)))
        rightLong.allowedPressTypes = [NSNumber(value: UIPress.PressType.rightArrow.rawValue)]
        rightLong.minimumPressDuration = InputConfig.holdThreshold
        view.addGestureRecognizer(rightLong)
        dPadRightLongPressGesture = rightLong

        // Long press should prevent tap from firing
        leftTap.require(toFail: leftLong)
        rightTap.require(toFail: rightLong)

    }

    @objc private func handleDPadLeftTap() {
        guard let vm = viewModel else { return }
        guard !vm.showInfoPanel && vm.postVideoState == .hidden else { return }

        inputCoordinator.handle(action: .stepSeek(forward: false), source: .irPress)
    }

    @objc private func handleDPadRightTap() {
        guard let vm = viewModel else { return }
        guard !vm.showInfoPanel && vm.postVideoState == .hidden else { return }

        inputCoordinator.handle(action: .stepSeek(forward: true), source: .irPress)
    }

    @objc private func handleDPadLeftLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let vm = viewModel else { return }
        guard !vm.showInfoPanel && vm.postVideoState == .hidden else { return }

        switch gesture.state {
        case .began:
            inputCoordinator.handle(action: .scrubNudge(forward: false), source: .irPress)

        case .changed:
            // Continue scrubbing - speed increases are handled by clicking again
            break

        case .ended, .cancelled:
            break

        default:
            break
        }
    }

    @objc private func handleDPadRightLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let vm = viewModel else { return }
        guard !vm.showInfoPanel && vm.postVideoState == .hidden else { return }

        switch gesture.state {
        case .began:
            inputCoordinator.handle(action: .scrubNudge(forward: true), source: .irPress)

        case .changed:
            // Continue scrubbing - speed increases are handled by clicking again
            break

        case .ended, .cancelled:
            break

        default:
            break
        }
    }

    @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
        guard let vm = viewModel else { return }

        // Bail in error / post-video states regardless of mode.
        if vm.playbackState.isFailed || vm.postVideoState != .hidden {
            return
        }

        // The same touch-surface pan drives two distinct interactions
        // depending on player state:
        //   • paused, panel closed → continuous swipe-to-scrub (existing).
        //   • panel open OR active playback → discrete swipe gesture
        //     that opens the panel (downward, when closed) or navigates
        //     the menu (any direction, when open).
        // For the discrete-swipe case we wait for the gesture to end
        // and decide direction from total translation + final velocity,
        // which reads the user's intent more reliably than sampling the
        // first directional crossing during motion.
        let isSwipeMode = vm.showInfoPanel || vm.playbackState != .paused
        if isSwipeMode {
            if gesture.state == .ended {
                handleEndOfSwipe(gesture, vm: vm)
            }
            return
        }

        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)

        switch gesture.state {
        case .began:
            inputCoordinator.handle(action: .scrubRelative(seconds: 0), source: .irPress)

        case .changed:
            // Proportional scrubbing: horizontal translation maps to seek time
            // Sensitivity: ~1 second per 2 points of horizontal movement
            // Positive translation.x = swipe right = forward
            let seekDelta = translation.x * 0.5
            inputCoordinator.handle(action: .scrubRelative(seconds: seekDelta), source: .irPress)
            gesture.setTranslation(.zero, in: view)

        case .ended, .cancelled:
            // If significant horizontal velocity, apply a final "flick" adjustment
            if abs(velocity.x) > 500 {
                let flickSeekDelta = velocity.x * 0.02  // Small multiplier for flick
                inputCoordinator.handle(action: .scrubRelative(seconds: flickSeekDelta), source: .irPress)
            }
            // Don't auto-commit - wait for user to press play/select to confirm position

        default:
            break
        }
    }

    /// Translate an end-of-pan gesture into a discrete swipe and dispatch
    /// the corresponding action. Called only in the swipe-mode branch of
    /// handlePanGesture (panel open, or active non-paused playback) — the
    /// scrubbing path still owns paused-state pans.
    private func handleEndOfSwipe(_ gesture: UIPanGestureRecognizer, vm: UniversalPlayerViewModel) {
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)

        let absX = abs(translation.x)
        let absY = abs(translation.y)
        let dominantHorizontal = absX > absY
        let displacement = dominantHorizontal ? absX : absY
        let speed = dominantHorizontal ? abs(velocity.x) : abs(velocity.y)

        // Recognize a swipe if there's either meaningful displacement
        // or a strong final velocity. Either alone is sufficient — a
        // short fast flick reads as a swipe even if the displacement
        // is small, and a slow long drag reads as a swipe even at
        // low velocity.
        let minDistance: CGFloat = 30
        let minVelocity: CGFloat = 150
        guard displacement >= minDistance || speed >= minVelocity else { return }

        let direction: MoveCommandDirection
        if dominantHorizontal {
            direction = translation.x > 0 ? .right : .left
        } else {
            direction = translation.y > 0 ? .down : .up
        }

        if vm.showInfoPanel {
            // Mirror UniversalPlayerView's onMoveCommand: swipe-up at
            // the topmost row closes the panel.
            if direction == .up && vm.focusedRowIndex == 0 {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                    vm.showInfoPanel = false
                }
            } else {
                vm.navigateSettings(direction: direction)
            }
        } else if direction == .down {
            // Active, non-paused playback: downward swipe opens the panel.
            inputCoordinator.handle(action: .showInfo, source: .siriMicroGamepad)
        }
    }

    private func dismissPlayer() {
        // Use super.dismiss to bypass our override checks
        super.dismiss(animated: true) { [weak self] in
            self?.onDismiss?()
        }
    }

    private func blockDismissTemporarily() {
        blockNextDismiss = true
        blockDismissResetWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.blockNextDismiss = false
            self?.blockDismissResetWorkItem = nil
        }
        blockDismissResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + InputConfig.blockDismissTimeout, execute: workItem)
    }
}

