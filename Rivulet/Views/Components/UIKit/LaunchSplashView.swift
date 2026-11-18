// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit

/// The launch splash on tvOS: hosts `LaunchSplashAnimation`, the layer tree every app shares.
/// Clear itself: the splash's own black fades with it, so Home shows through the exit.
final class LaunchSplashView: UIView {
    private let splash = LaunchSplashAnimation(
        river: UIImage(named: "LaunchRiver")?.cgImage,
        sky: UIImage(named: "WelcomeStars")?.cgImage,
        screenBlend: "screenBlendMode",
        reduceMotion: UIAccessibility.isReduceMotionEnabled)

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityElementsHidden = true
        layer.addSublayer(splash.layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        splash.layout(in: bounds)
    }

    /// Plays the exit, then calls `completion`.
    func finish(completion: @escaping () -> Void) {
        splash.finish(completion: completion)
    }
}
