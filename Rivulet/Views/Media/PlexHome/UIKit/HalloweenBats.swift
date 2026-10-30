import UIKit

/// Settings > Appearance > Easter Eggs. Every seasonal surprise checks this first.
enum EasterEggs {
    static let key = "easterEggsEnabled"
    static var enabled: Bool { SettingsStore.bool(key, default: true) }
}

/// Halloween easter egg: a few seconds of bats and ghosts across Home on Oct 31, once per launch.
/// Sublayers, not views, so the focus engine's occlusion test never sees them.
@MainActor
enum HalloweenBats {
    private static var hasShown = false

    static func showIfHalloween(in view: UIView) {
        let today = Calendar.current.dateComponents([.month, .day], from: Date())
        guard EasterEggs.enabled, today.month == 10, today.day == 31, !hasShown,
              !UIAccessibility.isReduceMotionEnabled else { return }
        hasShown = true

        // Give launch popups (What's New, the profile picker) a moment to present,
        // then wait them out, so the bats never play hidden behind one.
        Task { [weak view] in
            try? await Task.sleep(for: .seconds(1))
            while let view, view.window?.rootViewController?.presentedViewController != nil {
                try? await Task.sleep(for: .seconds(0.5))
            }
            guard let view, view.window != nil else { hasShown = false; return }
            play(in: view)
        }
    }

    private static func play(in view: UIView) {
        let emitter = CAEmitterLayer()
        emitter.emitterShape = .rectangle
        emitter.emitterPosition = CGPoint(x: -80, y: view.bounds.midY)
        emitter.emitterSize = CGSize(width: 1, height: view.bounds.height * 0.8)
        emitter.beginTime = CACurrentMediaTime()
        emitter.emitterCells = [
            cell("🦇", birthRate: 16, velocity: 1200, size: 90),
            cell("👻", birthRate: 4, velocity: 700, size: 110),
        ]
        view.layer.addSublayer(emitter)

        Task { @MainActor [weak view] in
            try? await Task.sleep(for: .seconds(2.5))
            emitter.birthRate = 0
            try? await Task.sleep(for: .seconds(0.5))
            if let view { crashGhost(in: view) }
            try? await Task.sleep(for: .seconds(4.5))
            emitter.removeFromSuperlayer()
        }
    }

    /// One last ghost flies into the right edge, squashes against it, then tips over and falls off.
    private static func crashGhost(in view: UIView) {
        let image = emojiImage("👻", size: 130)
        let ghost = CALayer()
        ghost.contents = image.cgImage
        ghost.bounds = CGRect(origin: .zero, size: image.size)
        // Anchored on its right edge so the squash presses against the wall.
        ghost.anchorPoint = CGPoint(x: 1, y: 0.5)
        ghost.position = CGPoint(x: 0, y: view.bounds.height * 0.4)
        view.layer.addSublayer(ghost)

        let duration: CFTimeInterval = 3.2
        let hit = 1.8 / duration, recovered = 2.3 / duration
        let wall = view.bounds.width, y = ghost.position.y

        let path = CAKeyframeAnimation(keyPath: "position")
        path.values = [
            CGPoint(x: 0, y: y), CGPoint(x: wall, y: y), CGPoint(x: wall, y: y),
            CGPoint(x: wall - 60, y: view.bounds.height + image.size.height),
        ]
        path.keyTimes = [0, hit, recovered, 1].map { NSNumber(value: $0) }
        path.timingFunctions = [.init(name: .easeIn), .init(name: .linear), .init(name: .easeIn)]

        let squash = CAKeyframeAnimation(keyPath: "transform")
        squash.values = [
            CATransform3DIdentity, CATransform3DIdentity,
            CATransform3DMakeScale(0.55, 1.2, 1), CATransform3DMakeScale(1.1, 0.95, 1),
            CATransform3DIdentity, CATransform3DMakeRotation(-.pi * 0.9, 0, 0, 1),
        ].map { NSValue(caTransform3D: $0) }
        squash.keyTimes = [0, hit, 1.88 / duration, 2.05 / duration, recovered, 1].map { NSNumber(value: $0) }

        for animation in [path, squash] {
            animation.duration = duration
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            ghost.add(animation, forKey: animation.keyPath)
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            ghost.removeFromSuperlayer()
        }
    }

    private static func cell(_ emoji: String, birthRate: Float, velocity: CGFloat, size: CGFloat) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = emojiImage(emoji, size: size).cgImage
        cell.birthRate = birthRate
        cell.lifetime = 5
        cell.velocity = velocity
        cell.velocityRange = velocity * 0.3
        cell.emissionLongitude = 0
        cell.emissionRange = .pi / 10
        cell.yAcceleration = -10
        cell.scale = 0.8
        cell.scaleRange = 0.35
        return cell
    }

    private static func emojiImage(_ emoji: String, size: CGFloat) -> UIImage {
        let font = UIFont.systemFont(ofSize: size)
        let text = emoji as NSString
        return UIGraphicsImageRenderer(size: text.size(withAttributes: [.font: font])).image { _ in
            text.draw(at: .zero, withAttributes: [.font: font])
        }
    }
}
