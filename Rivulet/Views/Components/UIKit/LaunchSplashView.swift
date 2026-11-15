// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit

/// The launch splash: the app icon's river R on its starry sky. The R pours in
/// along its curve, a light runs down it while Home loads, and it zooms away
/// into Home once Home is ready.
///
/// Core Animation only, no display link and no SwiftUI animation: the splash is
/// up while launch keeps the main thread busiest, and these animations run in
/// the render server, so they hold their pace through it.
final class LaunchSplashView: UIView {

    private enum Timing {
        static let skyFade: CFTimeInterval = 0.7
        static let revealDelay: CFTimeInterval = 0.15
        static let reveal: CFTimeInterval = 1.1
        static let sheenTrip: CFTimeInterval = 1.7
        static let sheenRest: CFTimeInterval = 0.8
        static let skyDrift: CFTimeInterval = 20
        static let bloomBreath: CFTimeInterval = 2.6
        /// Home is ready when the exit starts, so it is short.
        static let exit: CFTimeInterval = 0.25
    }

    private enum Layout {
        /// The R's height in screen heights.
        static let riverHeight: CGFloat = 0.5
        /// The pour and the light follow the R down and slightly right, as it flows.
        static let flowLean: CGFloat = 0.3
        static let revealFeather: CGFloat = 0.35
        /// The light's band, in R heights.
        static let sheenBand: CGFloat = 0.42
        static let sheenPeak: CGFloat = 0.55
        static let bloomSize: CGFloat = 1.7
        static let skyDriftScale: CGFloat = 1.06
        static let exitScale: CGFloat = 1.12
        static let starCount = 16
    }

    private let sky = CALayer()
    private let stars = CALayer()
    /// The R and everything drawn with it, so the exit zooms them as one.
    private let logo = CALayer()
    private let bloom = CAGradientLayer()
    private let river = CALayer()
    private let reveal = CAGradientLayer()
    private let sheen = CALayer()
    private let sheenMask = CALayer()
    private let sheenBand = CAGradientLayer()
    private let art = UIImage(named: "LaunchRiver")?.cgImage

    private var hasStarted = false
    private var isFinishing = false
    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        accessibilityElementsHidden = true

        sky.contents = UIImage(named: "WelcomeStars")?.cgImage
        sky.contentsGravity = .resizeAspectFill
        layer.addSublayer(sky)
        layer.addSublayer(stars)

        bloom.type = .radial
        bloom.colors = [UIColor(red: 0.42, green: 0.36, blue: 0.95, alpha: 0.30).cgColor,
                        UIColor(red: 0.30, green: 0.45, blue: 0.95, alpha: 0.10).cgColor,
                        UIColor(red: 0.30, green: 0.45, blue: 0.95, alpha: 0).cgColor]
        bloom.locations = [0, 0.45, 1]
        bloom.startPoint = CGPoint(x: 0.5, y: 0.5)
        bloom.endPoint = CGPoint(x: 1, y: 1)
        logo.addSublayer(bloom)

        river.contents = art
        river.contentsGravity = .resizeAspect
        // Opaque above the pour line, clear below it; the pour moves the line down the R.
        reveal.colors = [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0).cgColor]
        reveal.startPoint = CGPoint(x: 0.5 - Layout.flowLean / 2, y: 0)
        reveal.endPoint = CGPoint(x: 0.5 + Layout.flowLean / 2, y: 1)
        reveal.locations = [1, NSNumber(value: Double(1 + Layout.revealFeather))]
        river.mask = reveal
        logo.addSublayer(river)

        // The light is a soft band clipped to the R's own shape, screened over it.
        sheenMask.contents = art
        sheenMask.contentsGravity = .resizeAspect
        sheen.mask = sheenMask
        sheen.compositingFilter = "screenBlendMode"
        sheen.opacity = 0
        let peak = UIColor(red: 1, green: 0.97, blue: 0.92, alpha: Layout.sheenPeak)
        sheenBand.colors = [peak.withAlphaComponent(0).cgColor, peak.cgColor, peak.withAlphaComponent(0).cgColor]
        sheenBand.startPoint = CGPoint(x: 0.5, y: 0)
        sheenBand.endPoint = CGPoint(x: 0.5, y: 1)
        sheen.addSublayer(sheenBand)
        logo.addSublayer(sheen)
        layer.addSublayer(logo)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sky.frame = bounds
        stars.frame = bounds
        logo.frame = bounds

        let artSize = art.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: 772, height: 658)
        let height = bounds.height * Layout.riverHeight
        let size = CGSize(width: height * artSize.width / artSize.height, height: height)
        let frame = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                           width: size.width, height: size.height)
        river.frame = frame
        reveal.frame = river.bounds
        sheen.frame = frame
        sheenMask.frame = sheen.bounds
        let bloomSize = CGSize(width: size.width * Layout.bloomSize, height: size.height * Layout.bloomSize)
        bloom.frame = CGRect(x: bounds.midX - bloomSize.width / 2, y: bounds.midY - bloomSize.height / 2,
                             width: bloomSize.width, height: bloomSize.height)
        CATransaction.commit()

        if stars.sublayers == nil { scatterStars() }
        if !hasStarted { start() }
    }

    // MARK: - Entrance and loop

    /// Every animation here is timed from the commit that first puts the splash on
    /// screen, not from this layout. Launch can hold the main thread between the two
    /// (0.75 s on a cold simulator launch), and a clock started at layout had spent
    /// the sky's fade and half the pour before the first frame showed.
    private func start() {
        hasStarted = true
        sky.add(after(0, fade(from: 0, to: 1, duration: Timing.skyFade)), forKey: "fade")
        stars.add(after(Timing.revealDelay, fade(from: 0, to: 1, duration: Timing.skyFade * 1.5)), forKey: "fade")

        if reduceMotion {
            river.add(after(Timing.revealDelay, fade(from: 0, to: 1, duration: Timing.reveal)), forKey: "fade")
            bloom.add(after(Timing.revealDelay, fade(from: 0, to: 1, duration: Timing.reveal)), forKey: "fade")
            return
        }

        let pour = CABasicAnimation(keyPath: "locations")
        pour.fromValue = [NSNumber(value: Double(-Layout.revealFeather)), 0]
        pour.toValue = reveal.locations
        pour.duration = Timing.reveal
        pour.fillMode = .backwards
        pour.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        reveal.add(after(Timing.revealDelay, pour), forKey: "pour")

        let settle = CABasicAnimation(keyPath: "transform.scale")
        settle.fromValue = 0.95
        settle.toValue = 1
        settle.duration = Timing.reveal + 0.4
        settle.fillMode = .backwards
        settle.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        river.add(after(Timing.revealDelay, settle), forKey: "settle")

        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = 1
        breath.toValue = 0.6
        breath.duration = Timing.bloomBreath
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bloom.add(after(Timing.revealDelay, fade(from: 0, to: 1, duration: Timing.reveal)), forKey: "fade")
        bloom.add(after(Timing.revealDelay + Timing.reveal, breath), forKey: "breath")

        let drift = CABasicAnimation(keyPath: "transform.scale")
        drift.fromValue = 1
        drift.toValue = Layout.skyDriftScale
        drift.duration = Timing.skyDrift
        drift.fillMode = .forwards
        drift.isRemovedOnCompletion = false
        sky.add(after(0, drift), forKey: "drift")

        startSheen(after: Timing.revealDelay + Timing.reveal * 0.8)
        for star in stars.sublayers ?? [] { WelcomeGlowView.addTwinkle(to: star) }
    }

    /// `animation`, starting `delay` seconds after the commit that carries it: a group
    /// with no begin time is stamped with its commit's time, and its child is offset in it.
    private func after(_ delay: CFTimeInterval, _ animation: CAAnimation) -> CAAnimation {
        animation.beginTime = delay
        let group = CAAnimationGroup()
        group.animations = [animation]
        group.duration = animation.repeatCount == .infinity ? .infinity : delay + animation.duration
        group.fillMode = animation.fillMode
        group.isRemovedOnCompletion = animation.isRemovedOnCompletion
        return group
    }

    /// The light that runs down the R, again and again, while Home loads.
    private func startSheen(after delay: CFTimeInterval) {
        let size = sheen.bounds.size
        // Down the R and leaning right, the way it flows; the band lies across that line.
        let lean = CGVector(dx: size.width * Layout.flowLean, dy: size.height)
        let length = (lean.dx * lean.dx + lean.dy * lean.dy).squareRoot()
        let along = CGVector(dx: lean.dx / length, dy: lean.dy / length)
        let band = size.height * Layout.sheenBand
        let span = abs(size.width * along.dx) + abs(size.height * along.dy)
        sheenBand.bounds = CGRect(x: 0, y: 0, width: size.width * 2, height: band)
        sheenBand.setAffineTransform(CGAffineTransform(rotationAngle: -atan2(along.dx, along.dy)))

        let reach = (span + band) / 2
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let from = CGPoint(x: center.x - along.dx * reach, y: center.y - along.dy * reach)
        let to = CGPoint(x: center.x + along.dx * reach, y: center.y + along.dy * reach)
        sheenBand.position = from
        sheen.opacity = 1

        let run = CABasicAnimation(keyPath: "position")
        run.fromValue = NSValue(cgPoint: from)
        run.toValue = NSValue(cgPoint: to)
        run.duration = Timing.sheenTrip
        run.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let loop = CAAnimationGroup()
        loop.animations = [run]
        loop.duration = Timing.sheenTrip + Timing.sheenRest
        loop.repeatCount = .infinity
        sheenBand.add(after(delay, loop), forKey: "run")
    }

    private func scatterStars() {
        let image = WelcomeGlowView.starImage
        for _ in 0..<Layout.starCount {
            // Two samples averaged: gathered around the R, thinning toward the edges.
            let x = (CGFloat.random(in: 0...1) + CGFloat.random(in: 0...1)) / 2
            let y = (CGFloat.random(in: 0...1) + CGFloat.random(in: 0...1)) / 2
            let size = CGFloat.random(in: 0...1) < 0.15 ? CGFloat.random(in: 12...17) : CGFloat.random(in: 5...10)
            let star = CALayer()
            star.contents = image
            star.compositingFilter = "screenBlendMode"
            star.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            star.position = CGPoint(x: bounds.width * (0.05 + x * 0.9), y: bounds.height * (0.05 + y * 0.9))
            star.opacity = 0.6
            stars.addSublayer(star)
        }
    }

    // MARK: - Exit

    /// Plays the exit, then calls `completion`. Home is ready by now, so the exit
    /// never waits on the entrance: a pour still running just zooms away with the rest.
    func finish(completion: @escaping () -> Void) {
        guard !isFinishing else { return }
        isFinishing = true
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        if !reduceMotion {
            let zoom = CABasicAnimation(keyPath: "transform.scale")
            zoom.fromValue = 1
            zoom.toValue = Layout.exitScale
            zoom.duration = Timing.exit
            zoom.fillMode = .forwards
            zoom.isRemovedOnCompletion = false
            zoom.timingFunction = CAMediaTimingFunction(name: .easeIn)
            logo.add(zoom, forKey: "exit")
        }
        layer.add(fade(from: 1, to: 0, duration: Timing.exit), forKey: "exit")
        layer.opacity = 0
        CATransaction.commit()
    }

    private func fade(from: Float, to: Float, duration: CFTimeInterval) -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = duration
        fade.fillMode = .backwards
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return fade
    }
}
