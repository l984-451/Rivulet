// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

#if DEBUG
import UIKit

/// DEBUG-only: presents `PauseScreenView` full screen over a generated still with sample
/// content, for screenshots without a media server. State lands in
/// Library/Caches/pauseprobe-state.txt ("ready" once the screen has settled).
/// - RIVULET_PAUSEPROBE=frame | frame-late | glass | glass-late: the style, at 10 s or at 2 min.
/// - RIVULET_PAUSEPROBE_NOLOGO=1: no logo, so the title shows as text.
/// - RIVULET_PAUSEPROBE_PARKED=1: no frame (engine torn down after sleep), the art stands in.
/// - RIVULET_PAUSEPROBE_STILL=<path>: the picture under the pause screen, instead of the generated still.
/// - RIVULET_PAUSEPROBE_LOGO=<png path>: the logo.
/// - RIVULET_PAUSEPROBE_TITLE, _DETAIL (the line under the logo, verbatim), _SYNOPSIS: the text.
/// - RIVULET_PAUSEPROBE_PROGRESS=<positionSeconds>,<durationSeconds>: the time line.
@MainActor
enum PauseScreenProbe {
    private static var keep: [AnyObject] = []

    static func run(env: [String: String]) async {
        let mode = env["RIVULET_PAUSEPROBE"] ?? "frame"
        let style: PauseScreenStyle = mode.hasPrefix("glass") ? .glass : .frame
        let late = mode.hasSuffix("late")
        let parked = env["RIVULET_PAUSEPROBE_PARKED"] == "1"
        let fileImage: (String) -> UIImage? = { key in env[key].flatMap { UIImage(contentsOfFile: $0) } }
        let progress = env["RIVULET_PAUSEPROBE_PROGRESS"].map { $0.split(separator: ",").compactMap { Double($0) } }

        let vc = UIViewController()
        vc.modalPresentationStyle = .fullScreen
        vc.view.backgroundColor = .black
        let picture = UIImageView()
        picture.contentMode = .scaleAspectFill
        picture.frame = vc.view.bounds
        picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        vc.view.addSubview(picture)

        let screen = PauseScreenView(frame: vc.view.bounds)
        screen.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if let progress, progress.count == 2 {
            screen.progress = { (progress[0], progress[1]) }
        } else {
            screen.progress = { (31 * 60 + 42, 70 * 60) }
        }
        vc.view.addSubview(screen)
        keep = [vc]
        await present(vc)
        let size = vc.view.bounds.size
        if !parked { picture.image = fileImage("RIVULET_PAUSEPROBE_STILL") ?? still(size: size) }
        setState("presented")

        let content = PauseScreenView.Content(
            title: env["RIVULET_PAUSEPROBE_TITLE"] ?? "Saltglass",
            logo: env["RIVULET_PAUSEPROBE_NOLOGO"] == "1" ? nil : (fileImage("RIVULET_PAUSEPROBE_LOGO") ?? logo()),
            detailLine: env["RIVULET_PAUSEPROBE_DETAIL"]
                ?? PauseScreenText.episodeLine(season: 2, episode: 5, name: "The Long Tide"),
            synopsis: env["RIVULET_PAUSEPROBE_SYNOPSIS"]
                ?? "With the harbour shut by the storm, Mara takes the keeper's boat out alone to find the ship that never made port, and Elias finally opens his father's letters.",
            artURL: nil
        )
        screen.show(style: style, content: content, tier: .ambient, parked: parked)
        screen.layoutIfNeeded()
        screen.debugSetArt(art(size: size))
        // The picture's push-in, as the container drives it.
        if style == .frame, !parked, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 60, delay: 0, options: [.curveEaseInOut]) {
                picture.transform = CGAffineTransform(scaleX: 1.04, y: 1.04)
            }
        }
        try? await Task.sleep(for: .seconds(3))
        if late {
            screen.update(tier: .dimmed, parked: parked)
            try? await Task.sleep(for: .seconds(2))
        }
        setState("ready")
    }

    // MARK: - Generated pictures

    /// A dusk shoreline: warm horizon, a low sun, a dark headland.
    private static func still(size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            let cg = ctx.cgContext
            let horizon = size.height * 0.6
            gradient(cg, colors: [0x0A141D, 0x1F3240, 0x5B4D4C, 0xC27D52, 0xF0B779], locations: [0, 0.38, 0.66, 0.86, 1],
                     from: .zero, to: CGPoint(x: 0, y: horizon))
            gradient(cg, colors: [0x8A6A5A, 0x22313A, 0x0B151B], locations: [0, 0.35, 1],
                     from: CGPoint(x: 0, y: horizon), to: CGPoint(x: 0, y: size.height))
            let sun = CGPoint(x: size.width * 0.62, y: horizon - 12)
            let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [UIColor(rgb: 0xFFE6B2).cgColor, UIColor(rgb: 0xF0965A, alpha: 0).cgColor] as CFArray,
                                  locations: [0, 1])!
            cg.drawRadialGradient(glow, startCenter: sun, startRadius: 0, endCenter: sun, endRadius: size.width * 0.3, options: [])
            UIColor(rgb: 0x1E2228).setFill()
            let headland = UIBezierPath()
            headland.move(to: CGPoint(x: size.width * 0.7, y: horizon))
            headland.addCurve(to: CGPoint(x: size.width, y: horizon - 200),
                              controlPoint1: CGPoint(x: size.width * 0.8, y: horizon - 10),
                              controlPoint2: CGPoint(x: size.width * 0.82, y: horizon - 200))
            headland.addLine(to: CGPoint(x: size.width, y: horizon))
            headland.fill()
        }
    }

    /// Night over the sea: the show's backdrop art.
    private static func art(size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            let cg = ctx.cgContext
            gradient(cg, colors: [0x02060C, 0x0A1828, 0x163049, 0x21415B], locations: [0, 0.5, 0.85, 1],
                     from: .zero, to: CGPoint(x: 0, y: size.height * 0.65))
            gradient(cg, colors: [0x17293A, 0x08121C, 0x03070B], locations: [0, 0.4, 1],
                     from: CGPoint(x: 0, y: size.height * 0.65), to: CGPoint(x: 0, y: size.height))
            UIColor(rgb: 0xE8EDF0).setFill()
            UIBezierPath(ovalIn: CGRect(x: size.width * 0.22, y: size.height * 0.2, width: 88, height: 88)).fill()
        }
    }

    /// A serif wordmark standing in for a title logo.
    private static func logo() -> UIImage {
        let descriptor = UIFont.systemFont(ofSize: 110, weight: .semibold).fontDescriptor.withDesign(.serif)
        let font = descriptor.map { UIFont(descriptor: $0, size: 110) } ?? .systemFont(ofSize: 110)
        let text = NSAttributedString(string: "SALTGLASS", attributes: [
            .font: font, .kern: 110 * 0.14, .foregroundColor: UIColor(rgb: 0xF6E6CC),
        ])
        let size = text.size()
        return UIGraphicsImageRenderer(size: size).image { _ in text.draw(at: .zero) }
    }

    private static func gradient(_ cg: CGContext, colors: [Int], locations: [CGFloat], from: CGPoint, to: CGPoint) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors.map { UIColor(rgb: $0).cgColor } as CFArray,
                                        locations: locations) else { return }
        cg.saveGState()
        cg.clip(to: CGRect(x: 0, y: from.y, width: 10_000, height: to.y - from.y))
        cg.drawLinearGradient(gradient, start: from, end: to, options: [])
        cg.restoreGState()
    }

    private static func present(_ vc: UIViewController) async {
        var root: UIViewController?
        for _ in 0..<40 where root == nil {
            root = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.windows.first(where: \.isKeyWindow)?.rootViewController }).first
            if root == nil { try? await Task.sleep(for: .milliseconds(250)) }
        }
        guard var top = root else { return }
        while let presented = top.presentedViewController { top = presented }
        await withCheckedContinuation { done in top.present(vc, animated: false) { done.resume() } }
    }

    private static func setState(_ name: String) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? name.write(to: caches.appendingPathComponent("pauseprobe-state.txt"), atomically: true, encoding: .utf8)
    }
}

private extension UIColor {
    convenience init(rgb: Int, alpha: CGFloat = 1) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }
}
#endif
