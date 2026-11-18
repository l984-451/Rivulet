// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import CoreGraphics
import Foundation
import QuartzCore

/// The launch splash: the app icon, assembled. It opens on the icon's starry sky (the launch screen
/// shows the same sky, so the hand-over is invisible), a line of light comes in from the left and draws
/// the icon's river R along its ribbon, a light runs down it while Home loads, and it zooms away into
/// Home once Home is ready.
///
/// One layer tree for every app. The host view (tvOS `LaunchSplashView`, iOS `IOSLaunchSplashView`,
/// Mac `MacLaunchSplashView`) loads the two images from `Launch.xcassets`, supplies its platform's
/// screen blend, adds `layer` and calls `layout(in:)` from its own layout pass. The tree assumes a
/// top-left origin.
///
/// Core Animation only, no display link and no SwiftUI animation: the splash is up while launch keeps
/// the main thread busiest, and these animations run in the render server, so they hold their pace
/// through it.
@MainActor
final class LaunchSplashAnimation {

    #if DEBUG
    /// `RIVULET_SPLASH=1` shows the launch splash in a debug build; `RIVULET_SPLASH=hold` keeps it up.
    /// A home-screen launch has no environment, so a debug build on a device reads the same key from
    /// its Info.plist.
    nonisolated static let isWanted = debugSetting != nil
    nonisolated static let holdsForDebug = debugSetting == "hold"
    private nonisolated static var debugSetting: String? {
        ProcessInfo.processInfo.environment["RIVULET_SPLASH"]
            ?? Bundle.main.object(forInfoDictionaryKey: "RIVULET_SPLASH") as? String
    }
    #else
    nonisolated static let isWanted = true
    nonisolated static let holdsForDebug = false
    #endif

    private enum Timing {
        /// The stars come out over the sky the launch screen showed.
        static let starsFade: CFTimeInterval = 0.6
        /// The R is whole 0.75 s after the first frame: `drawDelay + draw`.
        static let drawDelay: CFTimeInterval = 0.05
        /// The line streaks in from the left, slowing to the pace it writes the R at, then writes it,
        /// easing off along the tail. The writing curve starts at slope 1, so the two meet at one speed.
        static let entry: CFTimeInterval = 0.15
        static let write: CFTimeInterval = 0.55
        static let draw = entry + write
        static let writeCurve = (x1: 0.3, y1: 0.3, x2: 0.6, y2: 0.95)
        /// The sparkle around the ribbon, which no slice holds, fades in as the line finishes.
        static let rest: CFTimeInterval = 0.25
        /// The line fades in over this as it comes in from the edge.
        static let penIn: CFTimeInterval = 0.05
        /// The light starts once the R is whole and its sparkle has come in.
        static let sheenDelay = drawDelay + draw + rest
        static let sheenTrip: CFTimeInterval = 1.7
        static let sheenRest: CFTimeInterval = 0.8
        static let skyDrift: CFTimeInterval = 20
        static let bloomBreath: CFTimeInterval = 2.6
        /// Home is ready when the exit starts, so it is short.
        static let exit: CFTimeInterval = 0.25
        /// Key frames sampled along the draw.
        static let samples = 120
    }

    private enum Layout {
        /// The R's height in screen heights.
        static let riverHeight: CGFloat = 0.5
        /// The R's widest, in screen widths: a portrait phone is narrower than the R is wide.
        static let riverMaxWidth: CGFloat = 0.7
        /// The light follows the R down and slightly right, as it flows.
        static let flowLean: CGFloat = 0.3
        /// The light's band, in R heights.
        static let sheenBand: CGFloat = 0.42
        static let sheenPeak: CGFloat = 0.55
        static let bloomSize: CGFloat = 1.7
        static let skyDriftScale: CGFloat = 1.06
        static let exitScale: CGFloat = 1.12
        static let starCount = 16
        /// The drawing line, in R heights: a short bright trail over a longer faint one, and its head
        /// (a hot core in a soft warm halo, which also covers the reveal's front).
        static let penTrail: CGFloat = 0.14
        static let penTail: CGFloat = 0.34
        static let penWidth: CGFloat = 0.006
        /// A wide faint stroke under the bright trail gives it its glow. A layer shadow would too, but
        /// costs an offscreen pass every frame the line moves, the busiest frames of the launch.
        static let penGlow: CGFloat = 0.03
        static let penCore: CGFloat = 0.06
        static let penHalo: CGFloat = 0.24
        /// The R is uncovered in this many slices of the arrival map, each fading in over `feather` of
        /// the line's length once the head has passed it.
        static let slices = 64
        static let feather: CGFloat = 0.05
        /// The line dissolves over the last stretch of the R, this share of its length, so it thins out
        /// with the tail's strands rather than stopping in empty sky past them.
        static let penDissolve: CGFloat = 0.25
    }

    /// The root of the splash; black, so fading it out shows what is behind.
    let layer = CALayer()
    private let sky = CALayer()
    private let stars = CALayer()
    /// The R and everything drawn with it, so the exit zooms them as one.
    private let logo = CALayer()
    private let bloom = CAGradientLayer()
    private let river = CALayer()
    /// Uncovers the R behind the line: slices of the arrival map, then the sparkle around it.
    private let drawMask = CALayer()
    private let restOfArt = CALayer()
    private var slices: [(layer: CALayer, box: CGRect, arrival: CGFloat)] = []
    private var mapSize: CGSize = .zero
    /// The line of light that draws the R: a bright trail over a faint one, and its head.
    private let pen = CAShapeLayer()
    private let penTail = CAShapeLayer()
    private let penGlow = CAShapeLayer()
    private let penHead = CALayer()
    private let penHalo = CAGradientLayer()
    private let penCore = CALayer()
    private let sheen = CALayer()
    private let sheenMask = CALayer()
    private let sheenBand = CAGradientLayer()
    private let art: CGImage?
    private let screenBlend: Any?
    private let reduceMotion: Bool

    /// Each star's place in unit coordinates, so a resize keeps the sky.
    private var starPlaces: [CGPoint] = []
    private var laidOutSize: CGSize = .zero
    private var hasStarted = false
    private var isFinishing = false

    /// - Parameters:
    ///   - river: `LaunchRiver`, the icon's R on clear.
    ///   - sky: `WelcomeStars`, the icon's sky: its back layer.
    ///   - screenBlend: the platform's screen compositing filter: `"screenBlendMode"` on UIKit,
    ///     a `CIScreenBlendMode` filter on AppKit.
    ///   - reduceMotion: fades the R in instead of drawing it, and holds the sky and stars still.
    ///   - arrivals: the arrival map's bytes; nil reads `LaunchRiverArrivals.bin` from the app bundle.
    init(river riverImage: CGImage?, sky skyImage: CGImage?, screenBlend: Any?, reduceMotion: Bool,
         arrivals: Data? = nil) {
        art = riverImage
        self.screenBlend = screenBlend
        self.reduceMotion = reduceMotion
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer.masksToBounds = true

        sky.contents = skyImage
        sky.contentsGravity = .resizeAspectFill
        layer.addSublayer(sky)
        layer.addSublayer(stars)

        bloom.type = .radial
        bloom.colors = [CGColor(srgbRed: 0.42, green: 0.36, blue: 0.95, alpha: 0.30),
                        CGColor(srgbRed: 0.30, green: 0.45, blue: 0.95, alpha: 0.10),
                        CGColor(srgbRed: 0.30, green: 0.45, blue: 0.95, alpha: 0)]
        bloom.locations = [0, 0.45, 1]
        bloom.startPoint = CGPoint(x: 0.5, y: 0.5)
        bloom.endPoint = CGPoint(x: 1, y: 1)
        logo.addSublayer(bloom)

        river.contents = art
        river.contentsGravity = .resizeAspect
        if !reduceMotion, let map = arrivals ?? Self.bundledArrivals, let sliced = Self.slices(of: map, count: Layout.slices) {
            mapSize = sliced.size
            for slice in sliced.slices {
                let layer = CALayer()
                layer.contents = slice.image
                layer.opacity = 0
                drawMask.addSublayer(layer)
                slices.append((layer, slice.box, slice.arrival))
            }
            restOfArt.backgroundColor = CGColor(gray: 1, alpha: 1)
            restOfArt.opacity = 0
            drawMask.addSublayer(restOfArt)
            river.mask = drawMask
        }
        logo.addSublayer(river)

        // The light is a soft band clipped to the R's own shape, screened over it.
        sheenMask.contents = art
        sheenMask.contentsGravity = .resizeAspect
        sheen.mask = sheenMask
        sheen.compositingFilter = screenBlend
        sheen.opacity = 0
        let peak = { (alpha: CGFloat) in CGColor(srgbRed: 1, green: 0.97, blue: 0.92, alpha: alpha) }
        sheenBand.colors = [peak(0), peak(Layout.sheenPeak), peak(0)]
        sheenBand.startPoint = CGPoint(x: 0.5, y: 0)
        sheenBand.endPoint = CGPoint(x: 0.5, y: 1)
        sheen.addSublayer(sheenBand)
        logo.addSublayer(sheen)

        // The drawing line: a glowing trail with a bright head, screened over the sky and the R.
        let warm = { (alpha: CGFloat) in CGColor(srgbRed: 1, green: 0.95, blue: 0.86, alpha: alpha) }
        for (trail, color) in [(penGlow, CGColor(srgbRed: 1, green: 0.8, blue: 0.6, alpha: 0.2)),
                               (penTail, warm(0.35)), (pen, warm(0.95))] {
            trail.fillColor = nil
            trail.strokeColor = color
            trail.lineCap = .round
            trail.lineJoin = .round
            trail.strokeStart = 0
            trail.strokeEnd = 0
            trail.compositingFilter = screenBlend
            trail.opacity = 0
            logo.addSublayer(trail)
        }
        penHalo.type = .radial
        penHalo.colors = [CGColor(srgbRed: 1, green: 0.88, blue: 0.7, alpha: 0.55),
                          CGColor(srgbRed: 1, green: 0.8, blue: 0.6, alpha: 0.18),
                          CGColor(srgbRed: 1, green: 0.8, blue: 0.6, alpha: 0)]
        penHalo.locations = [0, 0.35, 1]
        penHalo.startPoint = CGPoint(x: 0.5, y: 0.5)
        penHalo.endPoint = CGPoint(x: 1, y: 1)
        penHead.addSublayer(penHalo)
        penCore.contents = SplashStar.image
        penHead.addSublayer(penCore)
        penHead.compositingFilter = screenBlend
        penHead.opacity = 0
        logo.addSublayer(penHead)
        layer.addSublayer(logo)
    }

    /// Fits the splash to `bounds` (the host's own bounds) and, the first time, starts it.
    /// Call from every layout pass: a rotation or a window resize re-fits it in place.
    func layout(in bounds: CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        let local = CGRect(origin: .zero, size: bounds.size)
        sky.frame = local
        stars.frame = local
        logo.frame = local

        let artSize = art.map { CGSize(width: $0.width, height: $0.height) } ?? LaunchSplashStroke.artSize
        let height = min(local.height * Layout.riverHeight,
                         local.width * Layout.riverMaxWidth * artSize.height / artSize.width)
        let size = CGSize(width: height * artSize.width / artSize.height, height: height)
        let frame = CGRect(x: local.midX - size.width / 2, y: local.midY - size.height / 2,
                           width: size.width, height: size.height)
        river.frame = frame
        drawMask.frame = river.bounds
        restOfArt.frame = river.bounds
        if mapSize.width > 0 {
            let sx = size.width / mapSize.width, sy = size.height / mapSize.height
            for slice in slices {
                slice.layer.frame = CGRect(x: slice.box.minX * sx, y: slice.box.minY * sy,
                                           width: slice.box.width * sx, height: slice.box.height * sy)
            }
        }
        sheen.frame = frame
        sheenMask.frame = sheen.bounds
        let bloomSize = CGSize(width: size.width * Layout.bloomSize, height: size.height * Layout.bloomSize)
        bloom.frame = CGRect(x: local.midX - bloomSize.width / 2, y: local.midY - bloomSize.height / 2,
                             width: bloomSize.width, height: bloomSize.height)
        pen.frame = local
        penTail.frame = local
        let halo = height * Layout.penHalo, core = height * Layout.penCore
        penHead.bounds = CGRect(x: 0, y: 0, width: halo, height: halo)
        penHalo.frame = penHead.bounds
        penCore.frame = CGRect(x: (halo - core) / 2, y: (halo - core) / 2, width: core, height: core)
        if starPlaces.isEmpty { scatterStars() }
        for (star, place) in zip(stars.sublayers ?? [], starPlaces) {
            star.position = CGPoint(x: local.width * place.x, y: local.height * place.y)
        }
        CATransaction.commit()

        let resized = laidOutSize != .zero && laidOutSize != local.size
        laidOutSize = local.size
        guard !isFinishing else { return }
        if !hasStarted {
            start()
        } else if resized, !reduceMotion {
            // The line's path and the light's are in the old size: lay them out again on the new
            // one, keeping their clocks. A window laid out once at a provisional size and again at
            // its own (the Mac's, a SwiftUI host's) resizes before the line has started.
            startDrawing()
            startSheen()
        }
    }

    // MARK: - Entrance and loop

    /// Every animation here is timed from the commit that first puts the splash on
    /// screen, not from this layout. Launch can hold the main thread between the two
    /// (0.75 s on a cold simulator launch), and a clock started at layout had spent
    /// half the draw before the first frame showed. The sky needs no entrance: the
    /// launch screen already shows it, framed the same way.
    private func start() {
        hasStarted = true
        stars.add(after(0, fade(from: 0, to: 1, duration: Timing.starsFade)), forKey: "fade")

        if reduceMotion {
            river.add(after(Timing.drawDelay, fade(from: 0, to: 1, duration: Timing.draw / 2)), forKey: "fade")
            bloom.add(after(Timing.drawDelay, fade(from: 0, to: 1, duration: Timing.draw / 2)), forKey: "fade")
            return
        }

        startDrawing()

        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = 1
        breath.toValue = 0.6
        breath.duration = Timing.bloomBreath
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bloom.add(after(Timing.drawDelay, fade(from: 0, to: 1, duration: Timing.draw)), forKey: "fade")
        bloom.add(after(Timing.drawDelay + Timing.draw, breath), forKey: "breath")

        let drift = CABasicAnimation(keyPath: "transform.scale")
        drift.fromValue = 1
        drift.toValue = Layout.skyDriftScale
        drift.duration = Timing.skyDrift
        drift.fillMode = .forwards
        drift.isRemovedOnCompletion = false
        sky.add(after(0, drift), forKey: "drift")

        startSheen()
        for star in stars.sublayers ?? [] { SplashStar.addTwinkle(to: star) }
    }

    /// The line comes in from beyond the left edge, level with the R's top stroke, meets its tip and
    /// draws the R along its ribbon, uncovering the art just behind its head.
    ///
    /// Called again after a resize: everything is laid out for the new size and keeps the clock the
    /// first commit stamped on it, so a line part way through carries on from where it is.
    private func startDrawing() {
        let stamped = penHead.animation(forKey: "move")?.beginTime ?? 0
        func timed(_ delay: CFTimeInterval, _ animation: CAAnimation) -> CAAnimation {
            let group = after(delay, animation)
            if stamped > 0 { group.beginTime = stamped }
            return group
        }
        let size = river.bounds.size
        let origin = river.frame.origin
        let (line, _) = LaunchSplashStroke.polyline(LaunchSplashStroke.line, in: size)
        let feather = line.length * Layout.feather

        // The pen's path, on screen: in from beyond the left edge, then the line.
        var penLine = LaunchSplashStroke.Polyline()
        let tip = CGPoint(x: origin.x + line.points[0].x, y: origin.y + line.points[0].y)
        penLine.append(CGPoint(x: -size.height * Layout.penTail, y: tip.y))
        for point in line.points { penLine.append(CGPoint(x: origin.x + point.x, y: origin.y + point.y)) }
        let entry = penLine.lengths[1]
        // No implicit animation: after a resize the line takes its new size at once, under the clock.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for trail in [penGlow, pen, penTail] {
            trail.path = penLine.path()
            trail.lineWidth = size.height * (trail === penGlow ? Layout.penGlow : Layout.penWidth)
        }
        CATransaction.commit()
        let trail = size.height * Layout.penTrail
        let tail = size.height * Layout.penTail

        // One clock for all of it: the distance the head has travelled at each sample. The entry slows
        // evenly from its own speed to the writing speed; the writing follows its curve from there. On a
        // narrow screen the way in is short for its time, so it starts later rather than ever run back.
        let writing = line.length / CGFloat(Timing.write)
        let entryTime = min(CGFloat(Timing.entry), 2 * entry / writing)
        let entryStart = CGFloat(Timing.entry) - entryTime
        let streak = 2 * entry / entryTime - writing
        func distance(at time: CFTimeInterval) -> CGFloat {
            guard time >= Timing.entry else {
                let t = max(0, CGFloat(time) - entryStart)
                return streak * t - (streak - writing) / (2 * entryTime) * t * t
            }
            return entry + CGFloat(Self.bezier((time - Timing.entry) / Timing.write, Timing.writeCurve)) * line.length
        }
        let count = Timing.samples
        var times: [NSNumber] = []
        var shown = Array(repeating: [NSNumber](), count: slices.count)
        var penStarts: [NSNumber] = [], tailStarts: [NSNumber] = [], penEnds: [NSNumber] = []
        var heads: [CGPoint] = [], penAlphas: [NSNumber] = []
        for sample in 0...count {
            let t = Double(sample) / Double(count)
            times.append(NSNumber(value: t))
            let travelled = distance(at: t * Timing.draw)
            let alongR = travelled - entry
            for (index, slice) in slices.enumerated() {
                shown[index].append(NSNumber(value: Double(Self.unit((alongR - slice.arrival * line.length) / feather))))
            }
            penEnds.append(NSNumber(value: Double(travelled / penLine.length)))
            penStarts.append(NSNumber(value: Double(max(0, travelled - trail) / penLine.length)))
            tailStarts.append(NSNumber(value: Double(max(0, travelled - tail) / penLine.length)))
            heads.append(penLine.point(at: travelled))
            let comingIn = t * Timing.draw / Timing.penIn
            let goingOut = (line.length - alongR) / (line.length * Layout.penDissolve)
            penAlphas.append(NSNumber(value: Double(Self.unit(min(CGFloat(comingIn), goingOut)))))
        }

        func keyed(_ keyPath: String, _ values: [Any]) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.keyTimes = times
            animation.duration = Timing.draw
            animation.fillMode = .both
            animation.isRemovedOnCompletion = false
            return animation
        }
        for (slice, values) in zip(slices, shown) {
            slice.layer.add(timed(Timing.drawDelay, keyed("opacity", values)), forKey: "draw")
        }
        for (trail, starts) in [(penGlow, penStarts), (pen, penStarts), (penTail, tailStarts)] {
            trail.add(timed(Timing.drawDelay, keyed("strokeEnd", penEnds)), forKey: "end")
            trail.add(timed(Timing.drawDelay, keyed("strokeStart", starts)), forKey: "start")
        }
        penHead.add(timed(Timing.drawDelay, keyed("position", heads)), forKey: "move")

        // The line shows as it comes in and dissolves into the tail as the rest of the art arrives.
        for layer in [penGlow, pen, penTail, penHead] {
            layer.add(timed(Timing.drawDelay, keyed("opacity", penAlphas)), forKey: "shown")
        }
        let rest = fade(from: 0, to: 1, duration: Timing.rest)
        rest.fillMode = .both
        rest.isRemovedOnCompletion = false
        restOfArt.add(timed(Timing.drawDelay + Timing.draw * 0.8, rest), forKey: "rest")
    }

    /// `animation`, starting `delay` seconds after the commit that carries it: a group
    /// with no begin time is stamped with its commit's time, and its child is offset in it.
    ///
    /// A looping child gets a long finite group, never `.infinity`: a group of infinite
    /// duration holds its child on its first frame, so the light never ran and the bloom
    /// never breathed (measured from presentation values on macOS 26).
    private func after(_ delay: CFTimeInterval, _ animation: CAAnimation) -> CAAnimation {
        animation.beginTime = delay
        let group = CAAnimationGroup()
        group.animations = [animation]
        group.duration = animation.repeatCount == .infinity ? 86_400 : delay + animation.duration
        group.fillMode = animation.fillMode
        group.isRemovedOnCompletion = animation.isRemovedOnCompletion
        return group
    }

    /// The light that runs down the R, again and again, while Home loads. Called again after a resize:
    /// its path is laid out for the new size and keeps the clock the first commit stamped on it.
    private func startSheen() {
        let stamped = sheenBand.animation(forKey: "run")?.beginTime ?? 0
        let size = sheen.bounds.size
        guard size.height > 0 else { return }
        // Down the R and leaning right, the way it flows; the band lies across that line.
        let lean = CGVector(dx: size.width * Layout.flowLean, dy: size.height)
        let length = (lean.dx * lean.dx + lean.dy * lean.dy).squareRoot()
        let along = CGVector(dx: lean.dx / length, dy: lean.dy / length)
        let band = size.height * Layout.sheenBand
        let span = abs(size.width * along.dx) + abs(size.height * along.dy)
        let reach = (span + band) / 2
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let from = CGPoint(x: center.x - along.dx * reach, y: center.y - along.dy * reach)
        let to = CGPoint(x: center.x + along.dx * reach, y: center.y + along.dy * reach)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sheenBand.bounds = CGRect(x: 0, y: 0, width: size.width * 2, height: band)
        sheenBand.setAffineTransform(CGAffineTransform(rotationAngle: -atan2(along.dx, along.dy)))
        sheenBand.position = from
        sheen.opacity = 1
        CATransaction.commit()

        let run = CABasicAnimation(keyPath: "position")
        run.fromValue = from
        run.toValue = to
        run.duration = Timing.sheenTrip
        run.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let loop = CAAnimationGroup()
        loop.animations = [run]
        loop.duration = Timing.sheenTrip + Timing.sheenRest
        loop.repeatCount = .infinity
        let group = after(Timing.sheenDelay, loop)
        if stamped > 0 { group.beginTime = stamped }
        sheenBand.add(group, forKey: "run")
    }

    private func scatterStars() {
        let image = SplashStar.image
        for _ in 0..<Layout.starCount {
            // Two samples averaged: gathered around the R, thinning toward the edges.
            let x = (CGFloat.random(in: 0...1) + CGFloat.random(in: 0...1)) / 2
            let y = (CGFloat.random(in: 0...1) + CGFloat.random(in: 0...1)) / 2
            let size = CGFloat.random(in: 0...1) < 0.15 ? CGFloat.random(in: 12...17) : CGFloat.random(in: 5...10)
            let star = CALayer()
            star.contents = image
            star.compositingFilter = screenBlend
            star.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            star.opacity = 0.6
            stars.addSublayer(star)
            starPlaces.append(CGPoint(x: 0.05 + x * 0.9, y: 0.05 + y * 0.9))
        }
    }

    // MARK: - Arrival map

    /// `LaunchRiverArrivals.bin` from the app bundle (written by `tools/launch-splash`).
    static var bundledArrivals: Data? {
        Bundle.main.url(forResource: "LaunchRiverArrivals", withExtension: "bin").flatMap { try? Data(contentsOf: $0) }
    }

    /// Cuts the arrival map into `count` slices by when the line reaches them, in one pass over the map.
    /// Slice k fades from opaque to clear across its own range (so its edge follows the ribbon, smooth
    /// rather than stepped in map pixels) and is opaque over the range before it, which the next slice in
    /// turn covers fully once the line reaches it: neighbours overlap and no seam shows. 255 (reached by
    /// nothing) is left to `restOfArt`. Boxes are in map pixels, top-left origin.
    static func slices(of map: Data, count: Int)
        -> (size: CGSize, slices: [(image: CGImage, box: CGRect, arrival: CGFloat)])? {
        let bytes = [UInt8](map)
        guard bytes.count > 4, count > 0 else { return nil }
        let width = Int(bytes[0]) | Int(bytes[1]) << 8, height = Int(bytes[2]) | Int(bytes[3]) << 8
        guard width > 0, height > 0, bytes.count == 4 + width * height,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let values = bytes[4...]
        let span = 255 / Double(count)
        func owner(_ value: UInt8) -> Int { min(Int(Double(value) / span), count - 1) }

        var boxes = Array(repeating: (minX: Int.max, minY: Int.max, maxX: -1, maxY: -1), count: count)
        for y in 0..<height {
            for x in 0..<width {
                let value = values[4 + y * width + x]
                guard value < 255 else { continue }
                let k = owner(value)
                for slice in k...min(k + 1, count - 1) {
                    boxes[slice].minX = min(boxes[slice].minX, x); boxes[slice].maxX = max(boxes[slice].maxX, x)
                    boxes[slice].minY = min(boxes[slice].minY, y); boxes[slice].maxY = max(boxes[slice].maxY, y)
                }
            }
        }
        // One pixel of margin, so the scaled-up edge fades out inside the box.
        let frames = boxes.map { box -> (x: Int, y: Int, w: Int, h: Int)? in
            guard box.maxX >= box.minX else { return nil }
            let x = max(box.minX - 1, 0), y = max(box.minY - 1, 0)
            return (x, y, min(box.maxX + 1, width - 1) - x + 1, min(box.maxY + 1, height - 1) - y + 1)
        }
        // White, premultiplied: a mask reads only the alpha.
        var pixels = frames.map { frame in [UInt8](repeating: 0, count: frame.map { $0.w * $0.h * 4 } ?? 0) }
        for y in 0..<height {
            for x in 0..<width {
                let value = values[4 + y * width + x]
                guard value < 255 else { continue }
                let k = owner(value)
                // Opaque at the start of its own range, clear at its end; opaque in its successor's image.
                func paint(_ slice: Int, _ alpha: Double) {
                    guard slice < count, let frame = frames[slice] else { return }
                    let at = ((y - frame.y) * frame.w + (x - frame.x)) * 4
                    let level = UInt8(max(0, min(255, (alpha * 255).rounded())))
                    if level > pixels[slice][at + 3] {
                        pixels[slice][at] = level; pixels[slice][at + 1] = level
                        pixels[slice][at + 2] = level; pixels[slice][at + 3] = level
                    }
                }
                paint(k, 1 - (Double(value) - Double(k) * span) / span)
                paint(k + 1, 1)
            }
        }
        var result: [(image: CGImage, box: CGRect, arrival: CGFloat)] = []
        for slice in 0..<count {
            guard let frame = frames[slice] else { continue }
            let image = pixels[slice].withUnsafeMutableBytes { buffer -> CGImage? in
                CGContext(data: buffer.baseAddress, width: frame.w, height: frame.h, bitsPerComponent: 8,
                          bytesPerRow: frame.w * 4, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
            }
            guard let image else { continue }
            result.append((image, CGRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h),
                           CGFloat(slice) / CGFloat(count)))
        }
        return (CGSize(width: width, height: height), result)
    }

    /// The point on a cubic timing curve from (0,0) to (1,1) through `c` at time `t`.
    private static func bezier(_ t: Double, _ c: (x1: Double, y1: Double, x2: Double, y2: Double)) -> Double {
        func coordinate(_ s: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - s
            return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
        }
        var low = 0.0, high = 1.0
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if coordinate(mid, c.x1, c.x2) < t { low = mid } else { high = mid }
        }
        return coordinate((low + high) / 2, c.y1, c.y2)
    }

    private static func unit(_ value: CGFloat) -> CGFloat { min(max(value, 0), 1) }

    // MARK: - Exit

    /// Plays the exit, then calls `completion`. A line still drawing finishes first, so the R is
    /// whole when it zooms away; that is at most the draw's own length, and only on a launch that was
    /// ready that fast. A finish before the line has come in (signed out, a profile to choose) leaves
    /// at once: there is nothing on screen yet but the launch screen's sky.
    func finish(completion: @escaping () -> Void) {
        guard !isFinishing else { return }
        isFinishing = true
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        var begin = now
        if !reduceMotion, let stamped = penHead.animation(forKey: "move")?.beginTime, stamped > 0,
           now >= stamped + Timing.drawDelay {
            begin = max(now, stamped + Timing.drawDelay + Timing.draw)
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        if !reduceMotion {
            let zoom = CABasicAnimation(keyPath: "transform.scale")
            zoom.fromValue = 1
            zoom.toValue = Layout.exitScale
            zoom.duration = Timing.exit
            zoom.beginTime = begin
            zoom.fillMode = .both
            zoom.isRemovedOnCompletion = false
            zoom.timingFunction = CAMediaTimingFunction(name: .easeIn)
            logo.add(zoom, forKey: "exit")
        }
        let fadeOut = fade(from: 1, to: 0, duration: Timing.exit)
        fadeOut.beginTime = begin
        fadeOut.fillMode = .both
        layer.add(fadeOut, forKey: "exit")
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

/// The splash's stars, shared with the tvOS setup landing's sky (`WelcomeGlowView`).
@MainActor
enum SplashStar {
    /// A hot core that falls off quickly, with no wide halo. Drawn at 48 px for any star up to 24 pt.
    static let image: CGImage? = {
        let side = 48
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let colors = [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                      CGColor(srgbRed: 1, green: 0.98, blue: 0.92, alpha: 0.55),
                      CGColor(srgbRed: 1, green: 0.98, blue: 0.92, alpha: 0)] as CFArray
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.45, 1]) else { return nil }
        let center = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: CGFloat(side) / 2, options: [])
        return context.makeImage()
    }()

    /// A star's slow, endless twinkle, out of step with the others.
    static func addTwinkle(to star: CALayer) {
        let twinkle = CABasicAnimation(keyPath: "opacity")
        twinkle.fromValue = Float.random(in: 0.1...0.3)
        twinkle.toValue = 1
        twinkle.duration = .random(in: 1.4...4)
        twinkle.autoreverses = true
        twinkle.repeatCount = .infinity
        twinkle.beginTime = CACurrentMediaTime() + .random(in: 0...4)
        twinkle.fillMode = .backwards
        twinkle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        twinkle.isRemovedOnCompletion = false
        star.add(twinkle, forKey: "twinkle")
    }
}
