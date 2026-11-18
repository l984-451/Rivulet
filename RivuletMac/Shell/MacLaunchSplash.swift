// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import AppKit
import CoreImage
import SwiftUI

/// The launch splash over the main window, until `finished` turns true; then it plays the exit
/// and calls `onGone`. The animation is the one every app shares (`LaunchSplashAnimation`).
struct MacLaunchSplash: NSViewRepresentable {
    let finished: Bool
    let onGone: () -> Void

    func makeNSView(context: Context) -> MacLaunchSplashView { MacLaunchSplashView() }

    func updateNSView(_ view: MacLaunchSplashView, context: Context) {
        if finished, !LaunchSplashAnimation.holdsForDebug { view.finish(completion: onGone) }
    }
}

/// Hosts `LaunchSplashAnimation` in AppKit. Clear itself: the splash's own black fades with it,
/// so the window shows through the exit. It takes every click while it is up.
@MainActor
final class MacLaunchSplashView: NSView {
    private let splash = LaunchSplashAnimation(
        river: NSImage(named: "LaunchRiver")?.cgImageRepresentation,
        sky: NSImage(named: "WelcomeStars")?.cgImageRepresentation,
        // AppKit layers take a Core Image filter where UIKit takes the filter's name.
        screenBlend: CIFilter(name: "CIScreenBlendMode"),
        reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Without this AppKit ignores the screen blend's Core Image filter.
        layerUsesCoreImageFilters = true
        layer?.addSublayer(splash.layer)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // The shared tree is laid out top-left. A layer's sublayers are top-left when an odd
        // number of layers above them flip, which depends on the views this one sits in.
        splash.layer.isGeometryFlipped = !(layer?.contentsAreFlipped() ?? false)
        splash.layout(in: bounds)
        applyBackingScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyBackingScale()
    }

    /// Plays the exit, then calls `completion`.
    func finish(completion: @escaping () -> Void) {
        splash.finish(completion: completion)
    }

    /// Layers added by hand draw at 1x; the R, the stars and the gradients follow the window's screen.
    private func applyBackingScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        func apply(_ layer: CALayer) {
            if layer.contentsScale != scale { layer.contentsScale = scale }
            layer.mask.map(apply)
            layer.sublayers?.forEach(apply)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        apply(splash.layer)
        CATransaction.commit()
    }
}

extension EnvironmentValues {
    /// Home's hero has its first artwork on screen, or there is no hero to wait for: the
    /// launch splash may leave (`LaunchSplashGate.heroIsReady`).
    @Entry var macLaunchHeroReady: () -> Void = {}
}
