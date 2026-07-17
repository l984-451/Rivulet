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
    private var rail: PlayerRailView?
    private var progressBar: PlayerProgressBarView?
    private var scrubberProxy: ScrubberFocusProxyView?
    private var skipPill: SkipPillButton?
    private var pausedDimView: UIView?
    private var pauseIndicator: UIStackView?
    private var pauseTimeLabel: UILabel?
    private var loadingLabel: UILabel?
    private var chromeScrim = ChromeScrimView()
    private var ambientScrim: BottomScrimView?
    private var cancellables = Set<AnyCancellable>()
    /// The one floating panel shared by CC/audio/info (Task 5) and Up
    /// Next (Task 6). Only one can be up at a time — presenting a new
    /// one dismisses whatever's showing first.
    private var activeRailPanel: PlayerRailPanelView?
    /// Snapshot of the last `$upNextEpisodes` emission — Task 6's panel
    /// reads this when it comes online; Task 3 only derives the rail
    /// button's availability from it.
    private var upNextEpisodesCache: [PlexMetadata] = []
    /// Snapshot of the last `$insightsCast` emission, read when the rail's
    /// Insights panel is presented.
    private var insightsCastCache: [MediaPerson] = []
    /// Snapshot of the last `$insightsTrivia`/`$suppressedTriviaIDs` emission,
    /// read when the rail's Insights panel is presented (P2a).
    private var insightsTriviaCache: TitleTrivia?
    private var suppressedTriviaIDsCache: Set<String> = []
    /// True while `activeRailPanel` is showing Up Next content, so the
    /// `$upNextEpisodes` sink can dismiss a now-stale list without
    /// touching the CC/audio/info panels, which don't go stale off that
    /// publisher.
    private var isShowingUpNextPanel = false
    private var panGestureRecognizer: UIPanGestureRecognizer?
    private var touchSurfaceTapGesture: UITapGestureRecognizer?

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

        if let vm = viewModel {
            chromeScrim.isUserInteractionEnabled = false

            // Full-frame pause dim sits just above the video, below every
            // other chrome layer (z-order bottom-up: scrim, dim, rail,
            // progress bar, skip pill, pause indicator, loading label).
            let dim = UIView()
            dim.backgroundColor = UIColor.black.withAlphaComponent(0.28)
            dim.alpha = 0
            dim.isUserInteractionEnabled = false

            let ambientBottomScrim = BottomScrimView()
            ambientBottomScrim.alpha = 0
            let railView = PlayerRailView()
            let bar = PlayerProgressBarView()
            let proxy = ScrubberFocusProxyView()
            let pill = SkipPillButton()
            // Alpha-driven visibility (see applyChromeVisibility): alpha 0 also
            // makes the pill non-focusable, so it can't steal focus while hidden.
            pill.alpha = 0
            pill.onSelect = { [weak self] in
                Task { await self?.viewModel?.skipActiveMarker() }
            }
            // Up/Down while the pill owns focus (chrome hidden) surfaces the
            // controls; while the chrome is up, let the engine move focus back
            // to the rail on Down (return false → not consumed).
            pill.onDirectionalPress = { [weak self] _ in
                guard let vm = self?.viewModel else { return false }
                if vm.showControls { return false }
                vm.showControlsTemporarily()
                return true
            }

            // Top-left pause indicator: two bars + "Paused · Xm left".
            let barsStack = UIStackView()
            barsStack.axis = .horizontal
            barsStack.spacing = 6
            barsStack.alignment = .center
            for _ in 0..<2 {
                let bar = UIView()
                bar.backgroundColor = .white
                bar.layer.cornerRadius = 2
                bar.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    bar.widthAnchor.constraint(equalToConstant: 7),
                    bar.heightAnchor.constraint(equalToConstant: 24),
                ])
                barsStack.addArrangedSubview(bar)
            }
            let timeLabel = UILabel()
            timeLabel.font = .systemFont(ofSize: 22, weight: .medium)
            timeLabel.textColor = UIColor.white.withAlphaComponent(0.6)

            let indicator = UIStackView(arrangedSubviews: [barsStack, timeLabel])
            indicator.axis = .horizontal
            indicator.spacing = 12
            indicator.alignment = .center
            indicator.alpha = 0

            // Top-left "Loading" label — same spot the paused indicator
            // occupies, styled like its time label. The progress bar's own
            // skeleton shimmer (see `PlayerProgressBarView.setSkeleton`) is
            // the primary loading visual; this is a quiet text-only cue,
            // no spinner.
            let loadingLabel = UILabel()
            loadingLabel.font = .systemFont(ofSize: 22, weight: .medium)
            loadingLabel.textColor = UIColor.white.withAlphaComponent(0.6)
            loadingLabel.text = "Loading"
            loadingLabel.isHidden = true

            [chromeScrim, dim, ambientBottomScrim, railView, bar, proxy, pill, indicator, loadingLabel].forEach {
                view.addSubview($0)
                $0.translatesAutoresizingMaskIntoConstraints = false
            }
            // Z-order bottom-up, explicit (subview-add order above already
            // matches, but state this is intentional, not incidental).
            view.bringSubviewToFront(chromeScrim)
            view.bringSubviewToFront(dim)
            // Ambient bottom scrim sits above the dim/chrome scrim but below
            // the scrubber, so during ambient pause the scrubber reads over it.
            view.bringSubviewToFront(ambientBottomScrim)
            view.bringSubviewToFront(railView)
            view.bringSubviewToFront(bar)
            view.bringSubviewToFront(proxy)
            view.bringSubviewToFront(pill)
            view.bringSubviewToFront(indicator)
            view.bringSubviewToFront(loadingLabel)

            NSLayoutConstraint.activate([
                chromeScrim.topAnchor.constraint(equalTo: view.topAnchor),
                chromeScrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                chromeScrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                chromeScrim.bottomAnchor.constraint(equalTo: view.bottomAnchor),

                dim.topAnchor.constraint(equalTo: view.topAnchor),
                dim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                dim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                dim.bottomAnchor.constraint(equalTo: view.bottomAnchor),

                // Ambient bottom scrim: full-width, pinned to the bottom, tall
                // enough to sit behind the scrubber (which is ~118pt off the
                // bottom) during ambient pause.
                ambientBottomScrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                ambientBottomScrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                ambientBottomScrim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                ambientBottomScrim.heightAnchor.constraint(equalToConstant: 320),

                // Rail: left/right 90, pinned to the bottom.
                railView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 90),
                railView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -90),
                railView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -84),
                railView.heightAnchor.constraint(equalToConstant: PlayerRailView.railHeight),

                // Scrubber lives in the rail's lower region — a container
                // sibling overlaid on the rail, not a rail child (its
                // morph/behavior layer is untouched by this task). Leading/
                // trailing inset stays 132 at rest AND while scrubbing —
                // the bar never moves (see PlayerProgressBarView).
                bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 132),
                bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -132),
                bar.bottomAnchor.constraint(equalTo: railView.bottomAnchor, constant: -34),

                // Invisible focus proxy: geometrically below the button
                // cluster (leading/trailing match the bar's; top/bottom pad
                // 8pt around it) so the focus engine's downward search from
                // ANY cluster button lands here rather than settling on a
                // same-row cone candidate (the bug this proxy fixes). The
                // bar itself is the visible indicator — this view draws
                // nothing.
                proxy.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                proxy.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                proxy.topAnchor.constraint(equalTo: bar.topAnchor, constant: -8),
                proxy.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),

                // Skip pill: right-aligned with the scrubber's right end. Its
                // vertical position is driven from applyChromeVisibility (see
                // skipPillBottomConstraint): just above the rail plate when the
                // chrome is up, dropped lower over the video when it's hidden.
                pill.trailingAnchor.constraint(equalTo: bar.trailingAnchor),

                // Pause indicator: top 44 / leading 64.
                indicator.topAnchor.constraint(equalTo: view.topAnchor, constant: 44),
                indicator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 64),

                // Loading label occupies the exact same spot as the pause
                // indicator (the two are disjoint states — never shown at
                // the same time — but kept as separate views).
                loadingLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 44),
                loadingLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 64),
            ])
            // Adjustable vertical position (constant retargeted in
            // applyChromeVisibility). Starts in the rail-hidden (lower) spot.
            let pillBottom = pill.bottomAnchor.constraint(
                equalTo: railView.topAnchor, constant: Self.skipPillLoweredOffset)
            pillBottom.isActive = true
            skipPillBottomConstraint = pillBottom

            // Focus bridge so an Up press from ANY rail button reaches the pill,
            // not just the buttons that happen to sit under it. Spans the rail
            // width in the gap between the button row and the pill; enabled only
            // while the pill is visible (see applyChromeVisibility).
            let skipGuide = UIFocusGuide()
            view.addLayoutGuide(skipGuide)
            skipGuide.preferredFocusEnvironments = [pill]
            skipGuide.isEnabled = false
            NSLayoutConstraint.activate([
                skipGuide.leadingAnchor.constraint(equalTo: railView.leadingAnchor),
                skipGuide.trailingAnchor.constraint(equalTo: railView.trailingAnchor),
                skipGuide.bottomAnchor.constraint(equalTo: railView.topAnchor),
                skipGuide.topAnchor.constraint(equalTo: pill.bottomAnchor),
            ])
            skipPillFocusGuide = skipGuide

            // The proxy is a sibling of the rail, so the rail can't reach it
            // through the view tree — hand it over so its preferredFocus can
            // make the scrubber the first landing.
            railView.scrubberFocusProxy = proxy

            rail = railView
            progressBar = bar
            scrubberProxy = proxy
            skipPill = pill
            ambientScrim = ambientBottomScrim
            pausedDimView = dim
            pauseIndicator = indicator
            pauseTimeLabel = timeLabel
            self.loadingLabel = loadingLabel

            bindChrome(to: vm)
        }

        // Menu button is handled via pressesBegan (not gesture recognizer)
        // to avoid double-firing issues
        // Left/right arrows are handled by SwiftUI's onMoveCommand with RemoteHoldDetector
        // (UIKit gesture recognizers don't receive events when SwiftUI has focus)

        // Pan gesture for swipe-to-scrub on Siri Remote touchpad
        setupPanGesture()

        // Bare-tap on the Siri Remote touch surface surfaces the timeline
        // overlay briefly (matches Plex's tvOS client behavior).
        setupTouchSurfaceTapGesture()

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
        // Fallback press target for when NOTHING holds focus. Presses go to
        // the focused view and bubble up the responder chain; the first
        // responder only receives them directly in the focusless case.
        becomeFirstResponder()
    }

    override var canBecomeFirstResponder: Bool {
        return true
    }

    /// Focus routing for the UIKit transport layer. Controls-focus mode
    /// prefers the rail (its own preferred-focus handles which button
    /// lands, remembering the last-focused control).
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let panel = activeRailPanel, panel.window != nil {
            return [panel]
        }
        // Chrome hidden + a skip marker up: the pill is the lone affordance, so
        // it owns focus and a single Select jumps forward. (Ownership is false
        // whenever the rail/panel is up, so this never fights the checks above.)
        if viewModel?.skipPillOwnsFocus == true, let skipPill {
            return [skipPill]
        }
        if viewModel?.controlsFocusActive == true, let rail {
            return [rail]
        }
        return super.preferredFocusEnvironments
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
            // Cancel auto-skip countdown if active
            if vm.skipCountdownSeconds > 0 {
                vm.cancelSkipCountdown()
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
            if let panel = activeRailPanel {
                panel.dismissPanel()
                return
            }
            // Back from the transport buttons closes the whole chrome in one
            // press (not first de-focusing onto the scrubber). Hiding
            // showControls cascades to clear controlsFocusActive via its didSet.
            if vm.controlsFocusActive || vm.showControls {
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
    private var isHandlingPlayPausePress = false
    /// False until the first `.playing` of the current load; gates the
    /// paused presentation so a transient startup `.paused` never flashes
    /// "Paused" chrome before playback has begun.
    private var hasPlayedSinceLoad = false

    /// Last-seen value of `viewModel.skipPillOwnsFocus`, so a change can
    /// trigger a focus re-resolution toward/away from the pill exactly once.
    private var lastSkipPillOwnsFocus = false

    /// Pill's bottom-to-rail-top constraint, retargeted between the raised and
    /// lowered offsets as the chrome shows/hides.
    private var skipPillBottomConstraint: NSLayoutConstraint?
    /// Redirects an Up press from any rail button to the pill.
    private var skipPillFocusGuide: UIFocusGuide?
    /// Just above the rail plate — used while the transport chrome is visible.
    private static let skipPillRaisedOffset: CGFloat = -20
    /// Dropped lower over the video — used while the chrome is hidden, so the
    /// pill reads as a standalone lower affordance rather than a floating strip.
    private static let skipPillLoweredOffset: CGFloat = 200

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
                if let vm = viewModel, vm.isScrubbing {
                    isHandlingSelectPress = true
                    inputCoordinator.handle(action: .scrubCommit, source: .irPress)
                    return
                }
            }
            if press.type == .playPause {
                // Always honored, whatever holds focus — rail buttons, the
                // scrubber stop, or an open panel. SwiftUI's
                // .onPlayPauseCommand only fires while focus is in the
                // SwiftUI hierarchy, so the UIKit chrome dead-zoned the
                // button without this. Same coordinator action as the
                // SwiftUI path: commits an active scrub, else toggles.
                isHandlingPlayPausePress = true
                inputCoordinator.handle(action: .playPause, source: .irPress)
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.type == .menu {
                // Menu is always handled at the began phase, either by a
                // popup or by handleMenuButton. If focus moved mid-press
                // (a popup closed itself), the ended phase arrives on a
                // responder chain that never saw the began - letting it
                // bubble triggers the system's default dismiss and peels
                // an extra unwind layer (focus "goes to nil").
                isHandlingMenuPress = false
                return
            }
            if press.type == .select && isHandlingSelectPress {
                isHandlingSelectPress = false
                return
            }
            if press.type == .playPause && isHandlingPlayPausePress {
                isHandlingPlayPausePress = false
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
            if press.type == .playPause && isHandlingPlayPausePress {
                isHandlingPlayPausePress = false
                return
            }
        }
        super.pressesCancelled(presses, with: event)
    }

    /// Handle Menu button press with priority:
    /// 1. Cancel auto-skip countdown if active
    /// 2. Dismiss post-video overlay if showing
    /// 3. Cancel scrubbing if active
    /// 4. Close an open pill popup (Subtitles/Audio/Info) if any
    /// 5. Hide controls if visible
    /// 6. Dismiss player if nothing else to close
    private func handleMenuButton() {
        guard let vm = viewModel else {
            print("🎮 [MENU] No viewModel - dismissing player")
            dismissPlayer()
            return
        }

        // Cancel auto-skip countdown if active (highest priority)
        if vm.skipCountdownSeconds > 0 {
            vm.cancelSkipCountdown()
            blockDismissTemporarily()
            return
        }

        if inputCoordinator.target == nil {
            if vm.postVideoState != .hidden {
                vm.dismissPostVideo()
                dismissPlayer()
            } else if vm.isScrubbing {
                vm.cancelScrub()
            } else if let panel = activeRailPanel {
                // Edge case only: while focus is inside the panel, Menu is
                // consumed by PlayerRailPanelView.pressesBegan (presses go
                // to the focused view and bubble up — they reach the panel
                // before this VC). This branch covers a Menu press arriving
                // with focus OUTSIDE the panel; same content-first-refusal
                // contract, see RailPanelMenuHandling.
                if !panel.contentHandlesMenuPress() {
                    panel.dismissPanel()
                }
            } else if vm.controlsFocusActive {
                vm.exitControlsFocus()
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
        let shouldBlockDismiss = vm.postVideoState == .hidden && (vm.isScrubbing || vm.showControls)
        if shouldBlockDismiss {
            blockDismissTemporarily()
        }

        inputCoordinator.handle(action: .back, source: .irPress)
    }

    // MARK: - Swipe-to-Scrub Gesture

    private func setupPanGesture() {
        let panRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
        // Only recognize indirect touches (Siri Remote touchpad, not direct screen touches)
        panRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        // The focus engine reads the SAME indirect touch stream this recognizer
        // does, and a recognizer that reaches .began cancels the competing
        // interaction. An unconstrained pan therefore swallowed vertical swipes
        // and the engine never turned them into the move commands that drive
        // `.onMoveCommand` (swipe up/down to the transport controls). Gate the
        // begin so only a clearly horizontal, actionable swipe is claimed.
        panRecognizer.delegate = self
        view.addGestureRecognizer(panRecognizer)
        panGestureRecognizer = panRecognizer
    }

    /// True when a touch-surface swipe should drive the scrubber. Mirrors the
    /// bail conditions in `handlePanGesture` so the recognizer never *begins*
    /// in a state where it would no-op — beginning is what steals the gesture
    /// from the focus engine.
    ///
    /// Controls-focus mode does NOT disqualify a swipe. The scrubber is only
    /// on screen once the controls are up, and raising them is what sets
    /// `controlsFocusActive` — gating on it meant the pan refused to begin in
    /// exactly the state where the user can see the thing they want to drag.
    /// Only focus resting on a transport BUTTON blocks the swipe, so a
    /// horizontal flick there still moves focus along the row.
    private var panCanDriveScrub: Bool {
        guard let vm = viewModel else { return false }
        return !vm.playbackState.isFailed
            && vm.postVideoState == .hidden
            && !focusIsOnTransportButton
    }

    /// Focus is parked on a transport button rather than the scrubber. While
    /// `controlsFocusActive`, the scrubber proxy is the only focusable element
    /// that wants swipes (see `updateScrubberFocusEnabled`); anything else in
    /// the rail needs left/right to move focus, not to seek.
    private var focusIsOnTransportButton: Bool {
        guard viewModel?.controlsFocusActive == true else { return false }
        return scrubberProxy?.isFocused != true
    }

    // MARK: - Touch-Surface Tap (timeline overlay)

    /// Bare-tap on the Siri Remote touch surface (no force/click). Fires
    /// only on `.indirect` touches — the touchpad — and not on `.select`
    /// presses (those are the click and are routed to play/pause via the
    /// micro-gamepad buttonA handler). Coexists with the pan recognizer:
    /// if the user starts moving, pan takes over and tap doesn't fire.
    private func setupTouchSurfaceTapGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTouchSurfaceTap))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        // On tvOS, UITapGestureRecognizer defaults allowedPressTypes to
        // [.select], so without this it would silently wait for a click
        // rather than a bare finger tap.
        tap.allowedPressTypes = []
        view.addGestureRecognizer(tap)
        touchSurfaceTapGesture = tap
    }

    @objc private func handleTouchSurfaceTap() {
        guard let vm = viewModel else { return }
        guard !vm.isScrubbing,
              vm.postVideoState == .hidden,
              !vm.playbackState.isFailed
        else { return }

        vm.showControlsTemporarily()
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
        guard vm.postVideoState == .hidden, !vm.controlsFocusActive,
              scrubberProxy?.isFocused != true else { return }

        inputCoordinator.handle(action: .stepSeek(forward: false), source: .irPress)
    }

    @objc private func handleDPadRightTap() {
        guard let vm = viewModel else { return }
        guard vm.postVideoState == .hidden, !vm.controlsFocusActive,
              scrubberProxy?.isFocused != true else { return }

        inputCoordinator.handle(action: .stepSeek(forward: true), source: .irPress)
    }

    @objc private func handleDPadLeftLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let vm = viewModel else { return }
        guard vm.postVideoState == .hidden, !vm.controlsFocusActive,
              scrubberProxy?.isFocused != true else { return }

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
        guard vm.postVideoState == .hidden, !vm.controlsFocusActive,
              scrubberProxy?.isFocused != true else { return }

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
        // Kept in sync with `panCanDriveScrub`, which stops the recognizer from
        // beginning (and thus stealing the gesture) in these same states.
        guard panCanDriveScrub else { return }

        // Touch-surface pan drives continuous swipe-to-scrub whether the item
        // is playing or paused. It used to require `.paused`, so a swipe during
        // playback did nothing at all — the recognizer still began and swallowed
        // the gesture, but the handler returned immediately.

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

    // MARK: - Chrome Bindings

    private func bindChrome(to vm: UniversalPlayerViewModel) {
        guard let rail, let bar = progressBar else { return }

        // Static metadata (re-applied on episode advance via itemGeneration).
        applyRailMetadata(vm: vm)

        // Scrubber focus proxy: an invisible view geometrically below the
        // rail's button cluster (see its constraints above) so the focus
        // engine's own downward search from ANY cluster button lands here,
        // not on a same-row cone candidate. The bar itself renders the
        // focus indication (grow-and-brighten) — the proxy draws nothing.
        scrubberProxy?.onFocusChange = { [weak bar] focused in
            bar?.setFocusEmphasis(focused)
        }
        scrubberProxy?.onActivate = { [weak self, weak vm] pressType in
            guard let vm else { return }
            // While the proxy is focused it owns these presses OUTRIGHT:
            // the container's DPad gesture handlers all defer to a focused
            // proxy (not just to controls-focus mode). That deferral is
            // load-bearing — the first press below exits controls-focus
            // mode but the proxy KEEPS focus through the shuttle, so
            // without it every follow-up click would fire both here (in
            // pressesBegan) and in the tap gesture handler, bumping the
            // shuttle two levels per press (2x straight to 6x).
            vm.exitControlsFocus()
            switch pressType {
            case .leftArrow:
                vm.scrubInDirection(forward: false)
                vm.showControlsTemporarily()
            case .rightArrow:
                vm.scrubInDirection(forward: true)
                vm.showControlsTemporarily()
            default:
                // .select commits an active scrub — the proxy consumes
                // select, so the container's select-commit branch in
                // pressesBegan never sees this press. Otherwise: seek
                // entry at the current position, same as touchpad pan.
                if vm.isScrubbing {
                    self?.inputCoordinator.handle(action: .scrubCommit, source: .irPress)
                } else {
                    self?.inputCoordinator.handle(action: .scrubRelative(seconds: 0), source: .irPress)
                }
            }
        }

        vm.$itemGeneration
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak vm] _ in
                self?.progressBar?.resetFilmstrip()
                if let vm { self?.applyRailMetadata(vm: vm) }
            }
            .store(in: &cancellables)

        // The meta row's audio slot names the track that is playing, so it has
        // to follow the selection — both the user's pick and the engine's own
        // late-arriving track list (issue #200).
        vm.$currentAudioTrackId
            .combineLatest(vm.$audioTracks)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak vm] _ in
                if let vm { self?.applyRailMetadata(vm: vm) }
            }
            .store(in: &cancellables)

        vm.$currentTime
            .combineLatest(vm.$duration, vm.$isScrubbing, vm.$scrubTime)
            .combineLatest(vm.$wheelScrubbing.removeDuplicates())
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak vm] combined, isWheelScrubbing in
                let (currentTime, duration, isScrubbing, scrubTime) = combined
                guard let self, let vm else { return }
                self.progressBar?.update(
                    currentTime: currentTime, duration: duration,
                    isScrubbing: isScrubbing, scrubTime: scrubTime,
                    scrubStepLabelText: vm.scrubStepLabel,
                    scrubThumbnail: vm.scrubThumbnail,
                    markers: vm.metadata.allMarkers,
                    chapters: vm.metadata.Chapter ?? [],
                    isWheelScrubbing: isWheelScrubbing
                )
                // Scrubbing hides the rail and skip pill; scrubber and
                // scrim stay (design mock state 2). The bar itself keeps
                // its rest geometry — no inset swap.
                self.applyChromeVisibility()
            }
            .store(in: &cancellables)

        vm.$showControls
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyChromeVisibility() }
            .store(in: &cancellables)

        // Ambient pause: the whole chrome yields to the clean backdrop.
        vm.$pausePresentation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyChromeVisibility() }
            .store(in: &cancellables)

        vm.$playbackState
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak vm] state in
                guard let self, let vm else { return }
                let loading = state == .loading || state == .idle
                // Startup can pass through a split-second .paused before
                // the first .playing; the paused presentation (indicator,
                // dims) must not flash for it. Only a pause AFTER playback
                // has actually begun counts; a new load resets the gate.
                if state == .playing {
                    self.hasPlayedSinceLoad = true
                } else if loading {
                    self.hasPlayedSinceLoad = false
                }
                self.rail?.setLoading(loading)
                self.progressBar?.setSkeleton(loading)
                self.progressBar?.setPausedDim(state == .paused && self.hasPlayedSinceLoad)

                // Mid-playback buffering (seek landings, engine stalls)
                // borrows the same quiet cue — no skeleton, no centered
                // spinner, just the label. Buffering must NOT feed the
                // skeleton/focus gates above: the bar keeps its fill and the
                // scrubber stays focusable through a rebuffer.
                self.loadingLabel?.isHidden = !(loading || state == .buffering)

                if state == .paused, vm.duration > 0 {
                    let minutesLeft = Int(max(0, vm.duration - vm.currentTime) / 60)
                    self.pauseTimeLabel?.text = "Paused · \(minutesLeft)m left"
                }

                self.applyChromeVisibility()
            }
            .store(in: &cancellables)

        // Pill title + visibility + focus-ownership all react to the skip
        // button toggling and to the live countdown ticking.
        vm.$showSkipButton
            .combineLatest(vm.$skipCountdownSeconds)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshSkipPill() }
            .store(in: &cancellables)

        // Post-video takes its own focus layer and hides the pill; keep the
        // pill's visibility/ownership in sync when it appears or dismisses.
        vm.$postVideoState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyChromeVisibility() }
            .store(in: &cancellables)

        vm.$subtitleTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak rail] tracks in
                // Port of the old card binding: same enabled-look, applied
                // to the rail's subtitles button now.
                rail?.subtitlesButton.alpha = tracks.isEmpty ? 0.4 : 1
            }
            .store(in: &cancellables)

        vm.$upNextEpisodes
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak vm] episodes in
                guard let self, let vm else { return }
                self.upNextEpisodesCache = episodes
                self.rail?.setUpNextAvailable(!episodes.isEmpty && vm.metadata.type == "episode")
                // The open Up Next panel is reading a snapshot of the old
                // list — a fresh instance is built per presentation, so
                // there's no way to refresh it in place. Dismiss rather
                // than leave a stale list on screen; doesn't touch the
                // CC/audio/info panels, which don't key off this publisher.
                if self.isShowingUpNextPanel {
                    self.activeRailPanel?.dismissPanel()
                }
            }
            .store(in: &cancellables)

        vm.$insightsCast
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cast in
                guard let self else { return }
                self.insightsCastCache = cast
                self.updateInsightsAvailability()
            }
            .store(in: &cancellables)

        vm.$insightsTrivia
            .combineLatest(vm.$suppressedTriviaIDs)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] trivia, suppressed in
                guard let self else { return }
                self.insightsTriviaCache = trivia
                self.suppressedTriviaIDsCache = suppressed
                self.updateInsightsAvailability()
            }
            .store(in: &cancellables)

        // Kick the cast + trivia loads per item. @Published replays the
        // current value on subscribe, so this also fires once at bind time
        // for the first item.
        vm.$itemGeneration
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak vm] _ in
                Task { await vm?.loadInsightsCast() }
                Task { await vm?.loadInsightsTrivia() }
            }
            .store(in: &cancellables)

        vm.$controlsFocusActive
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                guard let self else { return }
                // The scrubber proxy is the rail's FIRST landing, and its
                // `canBecomeFocused` is gated on `controlsFocusActive` — which
                // has only just flipped. Refresh that gate BEFORE resolving
                // focus, or the engine polls a still-unfocusable proxy and the
                // rail falls through to the subtitles button.
                self.applyChromeVisibility()
                // Leaving controls-focus ends this visit to the rail, so the
                // next one starts on the scrubber again rather than on whatever
                // button happened to be focused when the user backed out.
                if !active { self.rail?.resetFocusMemory() }
                self.setNeedsFocusUpdate()
                self.updateFocusIfNeeded()
            }
            .store(in: &cancellables)

        // Rail actions. (No play/pause control, no skip-back — the remote owns seeking.)
        rail.onReplayLongPress = { [weak vm] in vm?.replayWithCaptions() }
        rail.onSubtitles = { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            self.presentRailPanel(
                content: CardTrackListView(
                    header: "Subtitles", tracks: vm.subtitleTracks,
                    selectedTrackId: vm.currentSubtitleTrackId, showsOffRow: true,
                    steppers: [
                        // Delay: sticky per movie/episode (ratingKey).
                        CardStepperConfig(
                            title: "Delay",
                            value: { [weak vm] in SubtitleAdjustments.formattedDelay(vm?.subtitleDelaySeconds ?? 0) },
                            onStep: { [weak vm] step in vm?.adjustSubtitleDelay(bySteps: step) }),
                        // Height: global across all media.
                        CardStepperConfig(
                            title: "Height",
                            value: { SubtitleAdjustments.formattedHeight(SubtitleAdjustments.heightUnits) },
                            onStep: { step in SubtitleAdjustments.setHeightUnits(SubtitleAdjustments.heightUnits + step) }),
                    ],
                    onSelect: { [weak vm, weak self] id in
                        vm?.selectSubtitleTrack(id: id)
                        self?.activeRailPanel?.dismissPanel()
                    }),
                width: 520, from: rail.subtitlesButton)
        }
        rail.onAudio = { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            self.presentRailPanel(
                content: CardTrackListView(
                    header: "Audio", tracks: vm.audioTracks,
                    selectedTrackId: vm.currentAudioTrackId, showsOffRow: false,
                    onSelect: { [weak vm, weak self] id in
                        if let id { vm?.selectAudioTrack(id: id) }
                        self?.activeRailPanel?.dismissPanel()
                    }),
                width: 520, from: rail.audioButton)
        }
        rail.onInfo = { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            self.presentRailPanel(
                content: CardInfoView(metadata: vm.metadata, modes: vm.streamingModeInfo, liveStatsProvider: { [weak vm] in vm?.aetherPlayer?.liveStats() }),
                width: 560, from: rail.infoButton)
        }
        rail.onUpNext = { [weak self] in
            guard let self, let vm = self.viewModel, !self.upNextEpisodesCache.isEmpty else { return }
            let presented = self.presentRailPanel(
                content: UpNextListView(
                    episodes: self.upNextEpisodesCache, currentRatingKey: vm.metadata.ratingKey,
                    seasonNumber: vm.metadata.parentIndex, serverURL: vm.serverURL, authToken: vm.authToken,
                    onSelect: { [weak self, weak vm] episode in
                        vm?.exitControlsFocus()
                        Task { await vm?.playEpisode(episode) }
                        self?.activeRailPanel?.dismissPanel()
                    }),
                width: 520, from: rail.upNextButton)
            self.isShowingUpNextPanel = presented
        }

        rail.onInsights = { [weak self] in
            guard let self, self.insightsButtonShouldBeAvailable else { return }
            self.presentRailPanel(
                content: InsightsPanelContainerView(
                    cast: self.insightsCastCache,
                    trivia: self.insightsTriviaCache,
                    suppressedTriviaIDs: self.suppressedTriviaIDsCache,
                    hideSpoilers: SettingsStore.bool("hideTriviaSpoilers", default: true)),
                width: 640, from: rail.insightsButton)
        }
    }

    /// Whether the Insights panel has anything to show: a non-empty cast
    /// list, or at least one trivia fact left after the hide-spoilers /
    /// suppression filter. Either section alone is enough to surface the
    /// rail button; both empty means fully graceful-absent (no button).
    private var insightsButtonShouldBeAvailable: Bool {
        if !insightsCastCache.isEmpty { return true }
        guard let trivia = insightsTriviaCache else { return false }
        let hideSpoilers = SettingsStore.bool("hideTriviaSpoilers", default: true)
        return !trivia.visibleFacts(hideSpoilers: hideSpoilers, suppressed: suppressedTriviaIDsCache).isEmpty
    }

    /// Re-derives the rail's Insights button visibility from the current
    /// cast + trivia snapshots. Called from both the `$insightsCast` and
    /// `$insightsTrivia` sinks since either can flip the combined
    /// availability independently of the other.
    private func updateInsightsAvailability() {
        rail?.setInsightsAvailable(insightsButtonShouldBeAvailable)
    }

    /// Shared presenter for the CC/audio/info/Up Next rail panel. Only
    /// one panel is ever up: presenting a new one dismisses whatever's
    /// showing. Guarded on the rail cluster actually being visible and
    /// not mid-scrub — the rail's buttons are hidden during a scrub and
    /// while loading, but a stray callback firing in that window (e.g.
    /// a race on the loading→ready edge) must not construct a panel
    /// anchored to a rail that isn't there to anchor to.
    ///
    /// Returns whether a panel was actually presented, so callers that
    /// track "which content is showing" (Task 6's Up Next staleness
    /// check) know whether their flag should stick.
    @discardableResult
    private func presentRailPanel(content: UIView, width: CGFloat, from button: UIView) -> Bool {
        guard let rail, rail.alpha > 0.5, viewModel?.isScrubbing != true else { return false }
        // Every presentation resets the content-type flag — only onUpNext
        // re-marks it (after this call returns). Without this, a CC/audio/info
        // panel superseding an open Up Next panel leaves the flag stuck true
        // (the old panel's onDismiss identity guard rightly won't touch it),
        // and the next $upNextEpisodes emission would dismiss the wrong panel.
        isShowingUpNextPanel = false
        activeRailPanel?.dismissPanel()
        let panel = PlayerRailPanelView.present(content: content, width: width,
                                                in: view, aboveRail: rail, towards: button)
        // The system's Menu gesture recognizer races the panel's own
        // responder-chain consumption and calls dismiss(animated:) on this
        // VC afterwards — arm the block so that echo is swallowed instead
        // of force-dismissing a panel that just handled Menu internally.
        panel.onMenuHandled = { [weak self] in self?.blockDismissTemporarily() }
        panel.onDismiss = { [weak self, weak panel] in
            guard let self else { return }
            // Guard on identity: a superseding presentRailPanel() call
            // dismisses this panel asynchronously (0.15s fade) then
            // synchronously swaps in the next one, so this completion can
            // fire after `activeRailPanel`/`isShowingUpNextPanel` already
            // describe a newer panel — must not clobber that state.
            if self.activeRailPanel === panel {
                self.activeRailPanel = nil
                self.isShowingUpNextPanel = false
                // Only clear the ambient-suppression flag if nothing
                // superseded this panel (the identity guard above already
                // confirms that) — a superseding presentRailPanel() call
                // sets it back to true right below before this can fire.
                self.viewModel?.isRailPanelOpen = false
            }
            self.setNeedsFocusUpdate(); self.updateFocusIfNeeded()
        }
        activeRailPanel = panel
        // A rail panel is a full-screen-adjacent overlay the ambient-pause
        // backdrop must not show through/around — see
        // UniversalPlayerViewModel.isRailPanelOpen.
        viewModel?.isRailPanelOpen = true
        view.setNeedsFocusUpdate(); view.updateFocusIfNeeded()
        return true
    }

    /// Eyebrow + title + meta row from the current item, ported from the
    /// 2a card's identical composition.
    ///
    /// The audio slot names the track that is actually PLAYING, so it must be
    /// derived from the view model's live selection rather than the item's
    /// stream list — reading the part's first audio stream showed the same
    /// label no matter which track the user picked (issue #200). Re-applied on
    /// every `$currentAudioTrackId` / `$audioTracks` emission (see bindChrome).
    private func applyRailMetadata(vm: UniversalPlayerViewModel) {
        let meta = vm.metadata
        rail?.setTitle(vm.title, eyebrow: vm.subtitle)

        let runtime = meta.duration.map { "\($0 / 60000) min" }
        rail?.setMeta(rating: meta.contentRating, runtime: runtime,
                      audio: railAudioLabel(vm: vm))
    }

    /// One-line name for the selected audio track, e.g. "English · TrueHD 7.1".
    /// Falls back to the track's own display name when there is no codec/channel
    /// detail to add, and to nil (slot hidden) before tracks have loaded.
    private func railAudioLabel(vm: UniversalPlayerViewModel) -> String? {
        // Before the engine publishes its track list the selection is unknown;
        // the default track is the honest guess, and the sink below corrects it
        // the moment a real selection lands.
        let track = vm.audioTracks.first(where: { $0.id == vm.currentAudioTrackId })
            ?? vm.audioTracks.first(where: { $0.isDefault })
        guard let track else { return nil }

        let format = track.audioFormatString
        let language = track.language ?? track.languageDisplay.capitalized
        guard !format.isEmpty, format != "Audio" else { return language }
        return "\(language) · \(format)"
    }

    /// Single writer for all chrome alphas. Every visibility rule lives
    /// here so no two sinks can fight over the same view's alpha (the old
    /// setChromeHidden / setAuxChromeHidden split let the ~0.5s time-sink
    /// re-reveal card/pill/panel over hidden controls). Called from the
    /// showControls, pausePresentation, playbackState, and time sinks; the
    /// guard-on-change makes per-tick calls free.
    ///
    /// Rules:
    /// - chromeVisible: controls up AND the frame is live (not ambient
    ///   pause). `|| isScrubbing` keeps the scrubber + scrim up during a
    ///   scrub even on the one off-device path (MPRemoteCommand
    ///   scrubNudge) that can begin a scrub without showControls being set.
    /// - railVisible: chrome visible AND not scrubbing — scrubbing hides
    ///   the rail and skip pill so focus reads unambiguously on the
    ///   scrubber (user call 2026-07-03).
    /// - paused: playback paused AND the frame is live (not ambient) —
    ///   drives the top-left pause indicator and the full-frame dim.
    /// - loading: the top-left "Loading" label shows whenever loading/idle
    ///   AND not ambient (the progress bar's own skeleton shimmer carries
    ///   the rest of the loading look); it uses `isHidden` from the state
    ///   sink too so it never intercepts focus while alpha is mid-fade.
    /// - scrubberProxy.isFocusEnabled: a FOCUS gate, not an alpha write (the
    ///   proxy is always invisible) — it must never be focusable while
    ///   controls are hidden, mid-scrub, or ambient, and only actually
    ///   reachable once controls-focus mode has moved focus onto the rail.
    private func applyChromeVisibility() {
        guard let vm = viewModel else { return }
        let ambient = vm.pausePresentation != .frame
        let isLoading = vm.playbackState == .loading || vm.playbackState == .idle
        // Buffering shares the loading label but none of the other loading
        // treatment (no skeleton, no focus gate) — see the state sink.
        let showsActivityCue = isLoading || vm.playbackState == .buffering
        let chromeVisible = (vm.showControls || vm.isScrubbing) && !ambient
        let railVisible = chromeVisible && !vm.isScrubbing
        let paused = vm.playbackState == .paused && !ambient && hasPlayedSinceLoad
        // Ambient pause keeps the scrubber (and its bottom scrim) up as a
        // read-only position indicator even though the rail fades. Not shown
        // while loading — there is no meaningful position yet.
        let scrubberVisible = chromeVisible || (ambient && !isLoading)
        // For a show, the episode title stays put in the rail during ambient
        // (same place, same size) while the rest of the rail empties out. The
        // rail view itself is held at alpha 1 so that held title shows; the
        // plate/eyebrow/meta/buttons fade inside `setAmbient`. Movies keep
        // nothing here (logo only).
        let keepRailTitle = ambient && vm.metadata.type == "episode"
        let railAlpha: CGFloat = keepRailTitle ? 1 : (railVisible ? 1 : 0)

        // The proxy is the rail's first focus landing, so it must be focusable
        // as soon as the chrome is up — NOT only after controls-focus mode has
        // already moved focus onto a rail button (the old rule, which made the
        // subtitles button the de-facto first landing).
        //
        // The `isFocused` term is load-bearing: a left/right press on the
        // focused proxy calls exitControlsFocus() and begins a scrub, which
        // clears BOTH `controlsFocusActive` and `railVisible`. Without this
        // term the proxy would stop being focusable in the middle of the very
        // gesture it is servicing, and the focus update that follows would yank
        // focus off the scrubber mid-shuttle. A view that currently holds focus
        // keeps it; the gate only governs whether focus may ARRIVE here.
        let proxyHasFocus = scrubberProxy?.isFocused == true
        scrubberProxy?.isFocusEnabled =
            (railVisible && !isLoading) || (proxyHasFocus && !isLoading && !ambient)

        // The skip pill lives independently of the rail: it stays up whenever a
        // marker is active (chrome shown OR hidden), so the user can jump forward
        // without first surfacing the controls. Hidden only while loading, during
        // ambient pause, or when post-video has taken over.
        let skipVisible = vm.showSkipButton && !isLoading && !ambient && vm.postVideoState == .hidden

        // Whether the pill owns focus (e.g. controls just hid with a marker up).
        // The focus re-resolution happens AFTER the alpha write below: the engine
        // only treats the pill as focusable once its model alpha is 1, so pushing
        // focus before the fade write would land nowhere.
        let ownsFocus = vm.skipPillOwnsFocus
        let ownershipChanged = ownsFocus != lastSkipPillOwnsFocus
        lastSkipPillOwnsFocus = ownsFocus

        // Pill sits just above the rail plate while the chrome is up, and drops
        // lower over the video when it hides.
        let pillOffset = railVisible ? Self.skipPillRaisedOffset : Self.skipPillLoweredOffset
        let pillOffsetChanged = skipPillBottomConstraint?.constant != pillOffset
        skipPillBottomConstraint?.constant = pillOffset
        refreshSkipGuideEnabled()

        // The panel floats above the rail — a scrub/ambient/hide that
        // takes the rail away must take the panel with it, since it
        // has nothing to anchor to and no route back to visible.
        if !railVisible {
            activeRailPanel?.dismissPanel()
        }

        let targets: [(UIView?, CGFloat)] = [
            (chromeScrim, chromeVisible ? 1 : 0),
            (progressBar, scrubberVisible ? 1 : 0),
            (ambientScrim, (ambient && !isLoading) ? 1 : 0),
            (rail, railAlpha),
            (skipPill, skipVisible ? 1 : 0),
            (pauseIndicator, paused ? 1 : 0),
            (pausedDimView, paused ? 1 : 0),
            (loadingLabel, showsActivityCue && !ambient ? 1 : 0),
        ]
        // `setAmbient` also drives the rail's sub-view alphas (plate/eyebrow/
        // meta/buttons vs. the held title), which the `targets` diff below
        // doesn't see, so fold its own change-detection in. (No rail → nothing
        // to animate there, so treat as unchanged.)
        let railAmbientChanged = rail.map { $0.ambientState != (ambient, keepRailTitle) } ?? false
        let targetsChanged = targets.contains(where: { view, alpha in
            view.map { abs($0.alpha - alpha) > 0.01 } == true
        })
        guard targetsChanged || railAmbientChanged || ownershipChanged || pillOffsetChanged else { return }
        UIView.animate(withDuration: 0.25) {
            for (view, alpha) in targets { view?.alpha = alpha }
            self.rail?.setAmbient(ambient, keepTitle: keepRailTitle)
            if pillOffsetChanged { self.view.layoutIfNeeded() }
        }
        // Model alpha is now 1 for a visible pill, so the engine will accept it
        // as a focus target. Re-resolve toward/away from the pill exactly once.
        if ownershipChanged {
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
    }

    /// Sync the pill's title, drive the auto-skip fill sweep, and re-evaluate
    /// visibility + focus ownership. The fill starts when the countdown
    /// begins (seconds jump 0 → N, which IS the total duration) and clears
    /// when it cancels or fires; mid-countdown re-shows restart with the
    /// remaining seconds so the sweep still lands with the skip.
    private func refreshSkipPill() {
        skipPill?.setTitle(viewModel?.skipButtonDisplayLabel, for: .normal)
        let seconds = viewModel?.skipCountdownSeconds ?? 0
        if seconds > 0 {
            if skipPill?.isFillRunning == false {
                skipPill?.beginFill(duration: TimeInterval(seconds))
            }
        } else {
            skipPill?.cancelFill()
        }
        applyChromeVisibility()
    }

    /// The Up→pill focus bridge is live only while the rail AND pill are on
    /// screen and the pill isn't already focused — disabling it when the pill
    /// holds focus keeps Down from being trapped straight back onto the pill.
    private func refreshSkipGuideEnabled(pillFocusedOverride: Bool? = nil) {
        guard let vm = viewModel else { skipPillFocusGuide?.isEnabled = false; return }
        let isLoading = vm.playbackState == .loading || vm.playbackState == .idle
        let railVisible = vm.showControls && !vm.isScrubbing && vm.pausePresentation == .frame
        let skipVisible = vm.showSkipButton && !isLoading
            && vm.pausePresentation == .frame && vm.postVideoState == .hidden
        let pillFocused = pillFocusedOverride ?? (skipPill?.isFocused ?? false)
        skipPillFocusGuide?.isEnabled = railVisible && skipVisible && !pillFocused
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        // Focus moved to/from the pill: retoggle the Up→pill bridge so it never
        // traps the pill's own Down press. Read the new focus from the context —
        // `isFocused` isn't reliably updated yet mid-transition.
        refreshSkipGuideEnabled(pillFocusedOverride: context.nextFocusedView === skipPill)
    }
}

/// Invisible focus stop for the scrubber. Sits geometrically below the
/// rail's button cluster (see the container's constraints) so the focus
/// engine's downward search from ANY cluster button lands here rather than
/// settling on a same-row cone candidate — the bug this view fixes. Draws
/// nothing; the progress bar itself is the visible focus indicator
/// (`PlayerProgressBarView.setFocusEmphasis(_:)`).
private final class ScrubberFocusProxyView: UIView {

    /// Focus gate, set by `PlayerContainerViewController.applyChromeVisibility()`.
    /// Never true while controls are hidden, mid-scrub, or ambient.
    var isFocusEnabled = false

    /// Fired when this view gains or loses focus.
    var onFocusChange: ((Bool) -> Void)?

    /// Fired on `.select`/`.leftArrow`/`.rightArrow` while focused; those
    /// press types are consumed here. Everything else (notably `.menu`) is
    /// passed to `super` so it bubbles to the container's own handling.
    var onActivate: ((UIPress.PressType) -> Void)?

    override var canBecomeFocused: Bool { isFocusEnabled }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if context.nextFocusedView === self {
            onFocusChange?(true)
        } else if context.previouslyFocusedView === self {
            onFocusChange?(false)
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.type {
            case .select, .leftArrow, .rightArrow:
                onActivate?(press.type)
            default:
                super.pressesBegan(presses, with: event)
            }
        }
    }
}

/// 2a left-readability scrim: horizontal black gradient behind the card
/// (rgba(0,0,0,.8) → .2 @46% → transparent @66%).
final class ChromeScrimView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    override init(frame: CGRect) {
        super.init(frame: frame)
        let gradient = layer as! CAGradientLayer
        gradient.colors = [
            UIColor.black.withAlphaComponent(0.8).cgColor,
            UIColor.black.withAlphaComponent(0.2).cgColor,
            UIColor.black.withAlphaComponent(0).cgColor,
        ]
        gradient.locations = [0, 0.46, 0.66]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Bottom-anchored legibility gradient for the ambient-pause scrubber. The
/// glass rail normally grounds the scrubber; during ambient the rail is gone,
/// so this thin transparent→black gradient keeps the scrubber readable over
/// bright backdrops.
final class BottomScrimView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let gradient = layer as! CAGradientLayer
        gradient.colors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(0.55).cgColor,
        ]
        gradient.locations = [0, 1]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}


// MARK: - UIGestureRecognizerDelegate

extension PlayerContainerViewController: UIGestureRecognizerDelegate {

    /// Only let the swipe-to-scrub pan claim a gesture that is clearly
    /// HORIZONTAL and that it will actually act on. On tvOS the focus engine
    /// consumes the same indirect-touch stream; once a recognizer begins, the
    /// competing interaction is cancelled. Refusing here (rather than bailing
    /// inside the action) leaves vertical swipes to the focus engine, which is
    /// what surfaces the transport controls via `.onMoveCommand`.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
              pan === panGestureRecognizer
        else { return true }

        guard panCanDriveScrub else { return false }

        // Decide on VELOCITY, not translation. This is called the instant the
        // pan clears its slop threshold, when translation is still near zero
        // and its direction is noise; velocity is already well-defined. Require
        // a decisive horizontal bias (2:1) so a diagonal drift toward the
        // controls still reads as vertical and reaches the focus engine.
        let velocity = pan.velocity(in: view)
        guard velocity != .zero else { return false }
        return abs(velocity.x) > abs(velocity.y) * 2
    }
}
