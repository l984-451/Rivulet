// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  The translucent chevron under the collapsed carousel card, hinting that Down (click or
//  swipe) opens the full-screen detail. Decorative only: never focusable, never hit-tested.
//  The bounce and breathing run on Core Animation, so they cost no main-thread work; the
//  host drives `alpha` (visibility and the drag fade).

import UIKit

final class PreviewPullDownHintView: UIView {
    /// Vertical travel of the bounce, in points.
    private static let bounceTravel: CGFloat = 7
    /// One leg of the bounce; a full down-and-back cycle is twice this (1.9 s).
    private static let halfPeriod: CFTimeInterval = 0.95
    private static let bounceKey = "pullDownHint.bounce"
    private static let breatheKey = "pullDownHint.breathe"

    private let chevron = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear

        let config = UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold)
        chevron.image = UIImage(systemName: "chevron.down", withConfiguration: config)
        // Translucent white: present, but never louder than the artwork or the chrome.
        chevron.tintColor = UIColor.white.withAlphaComponent(0.5)
        chevron.contentMode = .center
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)
        NSLayoutConstraint.activate([
            chevron.centerXAnchor.constraint(equalTo: centerXAnchor),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: 64),
            heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PreviewPullDownHintView is not Storyboard-backed")
    }

    /// Starts the slow bounce plus a slight opacity breath, in step. Reduce Motion:
    /// static. Idempotent.
    func startMotion() {
        let layer = chevron.layer
        guard !UIAccessibility.isReduceMotionEnabled else {
            stopMotion()
            return
        }
        guard layer.animation(forKey: Self.bounceKey) == nil else { return }
        let timing = CAMediaTimingFunction(name: .easeInEaseOut)
        let begin = layer.convertTime(CACurrentMediaTime(), from: nil)

        let bounce = CABasicAnimation(keyPath: "transform.translation.y")
        bounce.fromValue = 0
        bounce.toValue = Self.bounceTravel
        bounce.duration = Self.halfPeriod
        bounce.autoreverses = true
        bounce.repeatCount = .infinity
        bounce.timingFunction = timing
        bounce.beginTime = begin
        // Survives the app going to the background and back.
        bounce.isRemovedOnCompletion = false
        layer.add(bounce, forKey: Self.bounceKey)

        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1.0
        breathe.toValue = 0.65
        breathe.duration = Self.halfPeriod
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = timing
        breathe.beginTime = begin
        breathe.isRemovedOnCompletion = false
        layer.add(breathe, forKey: Self.breatheKey)
    }

    func stopMotion() {
        chevron.layer.removeAnimation(forKey: Self.bounceKey)
        chevron.layer.removeAnimation(forKey: Self.breatheKey)
    }
}
