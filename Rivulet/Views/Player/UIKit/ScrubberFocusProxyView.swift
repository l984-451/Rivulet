// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit

/// Invisible focus stop for the scrubber. Sits geometrically below the
/// rail's button cluster (see the container's constraints) so the focus
/// engine's downward search from ANY cluster button lands here rather than
/// settling on a same-row cone candidate — the bug this view fixes. Draws
/// nothing; like AVKit, the bar shows focus by dimming when it leaves
/// (`PlayerProgressBarView.setFocusDimmed(_:coordinator:)`).
final class ScrubberFocusProxyView: UIView {

    /// Focus gate, owned by the host player. Never true while the controls
    /// are hidden.
    var isFocusEnabled = false

    /// Quick Left/Right tap (released before `holdThreshold`) → skip. Arg: forward.
    var onSkip: ((Bool) -> Void)?
    /// Left/Right hold, or any Left/Right press while already scrubbing → shuttle.
    /// Arg: forward.
    var onShuttle: ((Bool) -> Void)?
    /// Center/`.select` press.
    var onSelect: (() -> Void)?
    /// Whether a shuttle is currently running — a press during one bumps speed
    /// immediately instead of waiting to distinguish tap from hold.
    var isScrubbingProvider: (() -> Bool)?

    /// `.select`/`.leftArrow`/`.rightArrow` are consumed here; everything else
    /// (notably `.menu`) is passed to `super` so it bubbles to the container.

    override var canBecomeFocused: Bool { isFocusEnabled }

    // Tap-vs-hold detection for the directional press — the same
    // `DirectionalPressDetector` the content press path uses, so both focus
    // regimes behave identically by construction rather than by two hand
    // -rolled timers staying in sync.
    private let directionalDetector = DirectionalPressDetector()

    override init(frame: CGRect) {
        super.init(frame: frame)
        directionalDetector.onHold = { [weak self] forward in self?.onShuttle?(forward) }
        directionalDetector.onTap = { [weak self] forward in self?.onSkip?(forward) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.type {
            case .select:
                onSelect?()
            case .leftArrow:
                beginArrow(forward: false)
            case .rightArrow:
                beginArrow(forward: true)
            default:
                super.pressesBegan(presses, with: event)
            }
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.type {
            case .leftArrow, .rightArrow:
                endArrow()
            case .select:
                break  // consumed at began
            default:
                super.pressesEnded(presses, with: event)
            }
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.type {
            case .leftArrow, .rightArrow:
                cancelArrow()
            case .select:
                break
            default:
                super.pressesCancelled(presses, with: event)
            }
        }
    }

    private func beginArrow(forward: Bool) {
        // Already shuttling: bump/redirect immediately, no tap-vs-hold wait.
        if isScrubbingProvider?() == true {
            onShuttle?(forward)
            return
        }
        directionalDetector.begin(forward: forward)
    }

    private func endArrow() {
        directionalDetector.end()
    }

    private func cancelArrow() {
        directionalDetector.cancel()
    }
}
