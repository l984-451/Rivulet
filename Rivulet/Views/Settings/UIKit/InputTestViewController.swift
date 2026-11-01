// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InputTestViewController.swift
//  Rivulet
//
//  Settings → About → Run Input Test: walks through `InputTestScript`, records
//  what each press delivered via `InputProbe`, and sends the transcript to Sentry.
//  Menu closes it through a tap recognizer on a focusable card, because a
//  focusless modal is never sent Menu and the transcript would be lost.
//

import UIKit

@MainActor
final class InputTestViewController: UIViewController {

    /// Focusable card, so the modal owns the remote and Menu is delivered here
    /// rather than unwinding a layer of Settings.
    private final class FocusableCard: UIView {
        override var canBecomeFocused: Bool { true }
    }

    private var run = InputTestRun()
    private var secondsLeft = Int(InputTestRun.stepTimeout)
    private var ticker: Timer?
    private var didCapture = false

    private let card = FocusableCard()
    private let promptLabel = UILabel()
    private let progressLabel = UILabel()
    private let transcriptLabel = UILabel()
    private let hintLabel = UILabel()

    init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        refresh()

        let menuTap = UITapGestureRecognizer(target: self, action: #selector(close))
        menuTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        view.addGestureRecognizer(menuTap)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The view must be in the window before a focus request means anything.
        setNeedsFocusUpdate()
        updateFocusIfNeeded()

        InputProbe.beginObserving { [weak self] event in self?.handle(event) }
        startTicker()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stop()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [card] }

    // MARK: Input

    private func handle(_ event: InputProbe.ProbeEvent) {
        switch event {
        case .began(let type):
            run.began(type: type)
        case .finished(let verdict):
            if run.finished(verdict) {
                secondsLeft = Int(InputTestRun.stepTimeout)
                if run.isFinished { complete() }
            }
            refresh()
        }
    }

    private func startTicker() {
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // `.common` so the countdown keeps running if anything ever puts the
        // run loop in tracking mode; a stalled prompt reads as a broken screen.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        guard !run.isFinished else { return }
        secondsLeft -= 1
        if secondsLeft <= 0 {
            run.timedOut()
            secondsLeft = Int(InputTestRun.stepTimeout)
            if run.isFinished { complete() }
        }
        refresh()
    }

    private func complete() {
        stop()
        capture()
        refresh()
    }

    private func stop() {
        ticker?.invalidate()
        ticker = nil
        InputProbe.endObserving()
    }

    /// Captures whatever was recorded, including a run abandoned part way — a
    /// partial transcript that stops at the button the user is complaining
    /// about is the most useful one there is.
    private func capture() {
        guard !didCapture, run.hasResults else { return }
        didCapture = true
        InputProbe.captureTestResult(run.transcript(header: Self.header))
    }

    @objc private func close() {
        stop()
        capture()
        dismiss(animated: true)
    }

    // MARK: Rendering

    private func refresh() {
        if let step = run.currentStep {
            promptLabel.text = step.prompt
            progressLabel.text = String(localized: "Step \(run.index + 1) of \(run.steps.count)   ·   \(max(secondsLeft, 0))s")
            hintLabel.text = String(localized: "Perform these steps in order. Pressing Back will close this screen.")
        } else {
            promptLabel.text = String(localized: "Done")
            progressLabel.text = didCapture
                ? String(localized: "Results sent to Rivulet's diagnostics.")
                : String(localized: "No presses were recorded.")
            hintLabel.text = String(localized: "Press Back to close this screen.")
        }
        // On screen: the step results only, which is bounded by the script. The
        // unprompted presses are counted rather than listed — they can run to
        // dozens on a repeating IR remote and would push the card off screen.
        // The Sentry transcript carries all of them.
        var shown = run.lines
        if !run.extras.isEmpty {
            shown.append("")
            shown.append(String(localized: "\(run.extras.count) unprompted presses also recorded"))
        }
        shown.append("")
        shown.append(Self.header)
        transcriptLabel.text = shown.joined(separator: "\n")
    }

    private static var header: String {
        let short = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        return "Rivulet \(short) (\(build)) · tvOS \(UIDevice.current.systemVersion)"
            + " · hold threshold \(InputPressTracker.ms(InputConfig.holdThreshold))"
    }

    // MARK: Layout

    private func buildUI() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.6)

        // Same card chrome as the other settings modals. (tvOS UIBlurEffect has
        // no systemMaterial styles.)
        let effect: UIVisualEffect
        if #available(tvOS 26.0, *) { effect = UIGlassEffect() }
        else { effect = UIBlurEffect(style: .regular) }
        let blur = UIVisualEffectView(effect: effect)
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 28
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true

        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        card.addSubview(blur)

        let title = UILabel()
        title.text = String(localized: "Remote Input Test")
        title.font = .systemFont(ofSize: 40, weight: .bold)
        title.textColor = .white

        hintLabel.font = .systemFont(ofSize: 26, weight: .regular)
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        hintLabel.numberOfLines = 0

        promptLabel.font = .systemFont(ofSize: 64, weight: .semibold)
        promptLabel.textColor = .white
        promptLabel.adjustsFontSizeToFitWidth = true
        promptLabel.minimumScaleFactor = 0.6

        progressLabel.font = .systemFont(ofSize: 28, weight: .medium)
        progressLabel.textColor = UIColor.white.withAlphaComponent(0.7)

        transcriptLabel.font = .monospacedSystemFont(ofSize: 21, weight: .regular)
        transcriptLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        transcriptLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [
            title, hintLabel, promptLabel, progressLabel, transcriptLabel
        ])
        stack.axis = .vertical
        // `.fill`, not `.leading`: a leading-aligned stack hands each label its
        // intrinsic width, so the multi-line transcript would size itself past
        // the card instead of wrapping inside it.
        stack.alignment = .fill
        stack.spacing = 18
        stack.setCustomSpacing(40, after: hintLabel)
        stack.setCustomSpacing(40, after: progressLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 1240),

            blur.topAnchor.constraint(equalTo: card.topAnchor),
            blur.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 56),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -56),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 64),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -64)
        ])
    }
}
