// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI
import UIKit

/// The launch splash on iOS and iPadOS: hosts `LaunchSplashAnimation`, the layer tree every app shares.
/// Clear itself: the splash's own black fades with it, so Home shows through the exit.
final class IOSLaunchSplashView: UIView {
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

    /// Every pass, so a rotation, Split View or Stage Manager resize keeps the R centred and fitted.
    override func layoutSubviews() {
        super.layoutSubviews()
        splash.layout(in: bounds)
    }

    /// Plays the exit, then calls `completion`.
    func finish(completion: @escaping () -> Void) {
        splash.finish(completion: completion)
    }
}

/// The splash over a window's root. UIKit, so its animations keep their pace while
/// launch holds the main thread. `finished` plays the exit, and `onGone` runs when it has played.
struct IOSLaunchSplash: UIViewRepresentable {
    let finished: Bool
    let onGone: () -> Void

    func makeUIView(context: Context) -> IOSLaunchSplashView { IOSLaunchSplashView() }

    func updateUIView(_ view: IOSLaunchSplashView, context: Context) {
        if finished, !LaunchSplashAnimation.holdsForDebug { view.finish(completion: onGone) }
    }
}

extension EnvironmentValues {
    /// Home's hero has its first artwork on screen, or has none to show, so the
    /// launch splash need not wait for it (`LaunchSplashGate.heroIsReady`).
    @Entry var launchHeroReady: () -> Void = {}
}
