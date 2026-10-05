// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

#if DEBUG
import AVKit
import GameController
import UIKit

/// DEBUG-only measurement harness for copying AVKit's scrubber. Output lands in Library/Caches.
/// - RIVULET_SCRUBPROBE=1: stock AVPlayerViewController, logs the clickpad touch against
///   AVKit's private ring-scrub state (device only; optional RIVULET_SCRUBPROBE_KEY).
/// - RIVULET_SCRUBPROBE=states: scripts AVKit through each scrubber state and dumps it.
/// - RIVULET_SCRUBPROBE=rivulet: renders PlayerProgressBarView in the same states.
/// - RIVULET_SCRUBPROBE=barstates (optional RIVULET_SCRUBPROBE_STRIPES=1): AVKit's bar
///   focus dim, scans and skips via its private selectors; `rivulet-bar` renders ours.
final class AVKitScrubProbe: NSObject {
    private static var current: AVKitScrubProbe?

    private let playerVC = AVPlayerViewController()
    private var displayLink: CADisplayLink?
    private var csv: FileHandle?
    private var lastRow = ""
    private var dumpedRing = false
    private var retries = 0
    /// Builds a fresh item; a failed AVURLAsset keeps its failure.
    private static var makeItem: (() -> AVPlayerItem)?
    private weak var controls: NSObject?
    private weak var rotary: UIGestureRecognizer?
    private weak var transportBar: UIView?
    private weak var needle: UIView?

    static func run(env: [String: String]) async {
        switch env["RIVULET_SCRUBPROBE"] {
        case "states":
            await ScrubStatesProbe.runAVKit()
            return
        case "rivulet":
            await ScrubStatesProbe.runRivulet()
            return
        case "menus":
            await ScrubStatesProbe.runAVKitMenus()
            return
        case "menus-bright":
            await ScrubStatesProbe.runAVKitMenus(brightOverlay: true)
            return
        case "popup":
            await ScrubStatesProbe.runRivuletPopup()
            return
        case "glass":
            await ScrubStatesProbe.runGlassVariants()
            return
        case "rail":
            await ScrubStatesProbe.runRailPopups()
            return
        case "chrome":
            await ScrubStatesProbe.runAVKitFullChrome()
            return
        case "focus":
            await ScrubStatesProbe.runAVKitFocus()
            return
        case "methods":
            await ScrubStatesProbe.runAVKitMethods()
            return
        case "skiptiming":
            await ScrubStatesProbe.runAVKitSkipTiming()
            return
        case "rivulet-bar":
            await ScrubStatesProbe.runRivuletBarStates()
            return
        case "summary":
            await ScrubStatesProbe.runAVKitSummary()
            return
        case "chromewatch":
            await ScrubStatesProbe.runAVKitChromeWatch()
            return
        case "panemenu":
            await ScrubStatesProbe.runAVKitPaneMenu()
            return
        case "barstates":
            await ScrubStatesProbe.runAVKitBarStates()
            return
        case "cardglass":
            await ScrubStatesProbe.runCardGlass(env: env)
            return
        case "infocard-bright":
            await ScrubStatesProbe.runAVKitInfoCardOverPattern()
            return
        default:
            break
        }
        let item: AVPlayerItem
        if let key = env["RIVULET_SCRUBPROBE_KEY"] {
            guard let plexItem = await plexItem(ratingKey: key) else { return }
            item = plexItem
        } else {
            let url = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_adv_example_hevc/master.m3u8")!
            item = AVPlayerItem(url: url)
        }
        let probe = AVKitScrubProbe()
        current = probe
        probe.start(item: item)
    }

    private static func plexItem(ratingKey: String) async -> AVPlayerItem? {
        let auth = PlexAuthManager.shared
        for _ in 0..<60 where auth.selectedServerURL == nil || auth.selectedServerToken == nil {
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard let serverURL = auth.selectedServerURL, let token = auth.selectedServerToken else { return nil }
        let ratingKey = await resolveRatingKey(ratingKey, serverURL: serverURL, token: token)
        guard let metadata = try? await PlexNetworkManager.shared.getFullMetadata(
                serverURL: serverURL, authToken: token, ratingKey: ratingKey),
              let hls = PlexNetworkManager.shared.buildHLSDirectPlayURL(
                serverURL: serverURL, authToken: token, ratingKey: ratingKey,
                hasHDR: metadata.hasHDR, useDolbyVision: metadata.hasDolbyVision,
                forceVideoTranscode: ContentRouter.requiresVideoTranscode(metadata: metadata))
        else {
            print("[ScrubProbe] could not build a Plex URL for \(ratingKey)")
            return nil
        }
        print("[ScrubProbe] playing \(metadata.title ?? ratingKey)")
        makeItem = { AVPlayerItem(asset: AVURLAsset(url: hls.url, options: ["AVURLAssetHTTPHeaderFieldsKey": hls.headers])) }
        return makeItem?()
    }

    /// "movie" / "episode" resolve to the first such item in the library, so a
    /// test launch needs no known key. Anything else passes through.
    static func resolveRatingKey(_ key: String, serverURL: String, token: String) async -> String {
        let network = PlexNetworkManager.shared
        // "search:<title>": the first movie or episode the server finds for it.
        if key.hasPrefix("search:") {
            let hits = (try? await network.search(serverURL: serverURL, authToken: token,
                                                  query: String(key.dropFirst(7)))) ?? []
            return hits.first(where: { $0.type == "movie" || $0.type == "episode" })?.ratingKey ?? key
        }
        let kinds: [String: (section: String, type: Int)] = ["movie": ("movie", 1), "episode": ("show", 4)]
        guard let kind = kinds[key] else { return key }
        guard let section = (try? await network.getLibraries(serverURL: serverURL, authToken: token))?
                .first(where: { $0.type == kind.section }),
              let first = try? await network.getLibraryItems(
                serverURL: serverURL, authToken: token, sectionId: section.key, size: 1, type: kind.type).first,
              let resolved = first.ratingKey
        else { return key }
        return resolved
    }

    private func start(item: AVPlayerItem) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("scrubprobe.csv")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        csv = try? FileHandle(forWritingTo: url)
        write("t,x,y,btn,playerTime,rate,barTime,barScrubbing,rState,rPos,rDelta,rVel,rAccum,rClass,digX,digY,needleAlpha,needlePresAlpha,needleAngle")

        for controller in GCController.controllers() { controller.microGamepad?.reportsAbsoluteDpadValues = true }

        playerVC.player = AVPlayer(playerItem: item)
        playerVC.modalPresentationStyle = .fullScreen
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(playerVC, animated: false) { [weak self] in self?.playerVC.player?.play() }

        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.add(to: .main, forMode: .common)
        print("[ScrubProbe] recording to \(url.path)")
    }

    @objc private func tick() {
        guard playerVC.presentingViewController != nil else { return stop() }
        findAVKitObjects()
        if let item = playerVC.player?.currentItem, item.status == .failed, retries < 8, let makeItem = Self.makeItem {
            // A Plex transcode 404s until its first segments exist; retry like the HLS route's preflight.
            retries += 1
            print("[ScrubProbe] item failed (retry \(retries)): \(String(describing: item.error))")
            let fresh = makeItem()
            playerVC.player?.replaceCurrentItem(with: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.playerVC.player?.replaceCurrentItem(with: fresh)
                self?.playerVC.player?.play()
            }
        }

        let pad = (GCController.current ?? GCController.controllers().first { $0.microGamepad != nil })?.microGamepad
        let x = pad?.dpad.xAxis.value ?? 0
        let y = pad?.dpad.yAxis.value ?? 0
        let btn = pad?.buttonA.isPressed == true ? 1 : 0
        let player = playerVC.player
        let digitizer = (Self.value(rotary, "digitizerLocation") as? NSValue)?.cgPointValue ?? .zero
        let transform = (Self.value(needle, "fingerPositionRotationTransform") as? NSValue)?.cgAffineTransformValue ?? .identity

        let fields: [String] = [
            f(x), f(y), "\(btn)",
            f(player?.currentTime().seconds ?? -1), f(player?.rate ?? 0),
            f(Self.value(transportBar, "currentTimeInterval")), "\(Self.value(transportBar, "isScrubbing") as? Bool == true ? 1 : 0)",
            "\(rotary?.state.rawValue ?? -1)",
            f(Self.value(rotary, "position")), f(Self.value(rotary, "delta")), f(Self.value(rotary, "velocity")),
            f(Self.value(rotary, "accumulatedDistance")), "\(Self.value(rotary, "movementClassification") ?? "-")",
            f(digitizer.x), f(digitizer.y),
            f(needle?.alpha ?? -1), f(needle?.layer.presentation()?.opacity ?? -1), f(atan2(transform.b, transform.a)),
        ]
        let row = fields.joined(separator: ",")
        if row != lastRow {
            lastRow = row
            write(f(CACurrentMediaTime()) + "," + row)
        }

        if !dumpedRing, let needle, needle.alpha > 0.99, needle.layer.presentation()?.opacity ?? 0 > 0.99 {
            dumpedRing = true
            dumpRing()
        }
    }

    private func findAVKitObjects() {
        if controls == nil, let cls = NSClassFromString("AVNowPlayingPlaybackControlsViewController") {
            controls = Self.descendants(of: playerVC).first { $0.isKind(of: cls) }
        }
        if rotary == nil { rotary = Self.value(controls, "rotaryGestureRecognizer") as? UIGestureRecognizer }
        if transportBar == nil { transportBar = Self.value(controls, "transportBar") as? UIView }
        if needle == nil { needle = Self.value(transportBar, "rotaryScrubNeedle") as? UIView }
    }

    /// One-shot dump of AVKit's transport bar while the ring shows, plus a window snapshot.
    private func dumpRing() {
        guard let transportBar, let window = transportBar.window else { return }
        var lines = ["# ring dump t=\(f(CACurrentMediaTime()))"]
        func walk(_ view: UIView, _ depth: Int) {
            let l = view.layer
            let frame = view.convert(view.bounds, to: window)
            lines.append(String(repeating: "  ", count: depth)
                + "\(type(of: view)) win=\(frame) alpha=\(view.alpha) hidden=\(view.isHidden) r=\(l.cornerRadius)"
                + " bw=\(l.borderWidth) border=\(l.borderColor.map { UIColor(cgColor: $0).description } ?? "nil")"
                + " bg=\(view.backgroundColor?.description ?? "nil") filter=\(l.compositingFilter ?? "nil")"
                + " shadow=\(l.shadowOpacity)/\(l.shadowRadius)/\(l.shadowOffset)/\(l.shadowColor.map { UIColor(cgColor: $0).description } ?? "nil")")
            view.subviews.forEach { walk($0, depth + 1) }
        }
        walk(transportBar, 0)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? lines.joined(separator: "\n").write(to: caches.appendingPathComponent("scrubprobe-tree.txt"), atomically: true, encoding: .utf8)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        try? image.pngData()?.write(to: caches.appendingPathComponent("scrubprobe-ring.png"))
        print("[ScrubProbe] ring dumped")
    }

    private func stop() {
        displayLink?.invalidate()
        displayLink = nil
        try? csv?.close()
        csv = nil
        print("[ScrubProbe] stopped")
        Self.current = nil
    }

    private func write(_ line: String) {
        csv?.write(Data((line + "\n").utf8))
    }

    private func f(_ value: Any?) -> String {
        switch value {
        case let d as Double: return String(format: "%.4f", d)
        case let d as CGFloat: return String(format: "%.4f", Double(d))
        case let d as Float: return String(format: "%.4f", Double(d))
        case let n as NSNumber: return String(format: "%.4f", n.doubleValue)
        default: return "-"
        }
    }

    /// KVC that returns nil instead of raising when the private key is missing.
    private static func value(_ object: NSObject?, _ key: String) -> Any? {
        guard let object else { return nil }
        let hasIvar = class_getInstanceVariable(type(of: object), "_" + key) != nil
        guard object.responds(to: NSSelectorFromString(key)) || hasIvar else { return nil }
        return object.value(forKey: key)
    }

    private static func descendants(of vc: UIViewController) -> [UIViewController] {
        vc.children.flatMap { [$0] + descendants(of: $0) }
    }
}

/// Scripted state capture. Each state writes `scrubstate-<name>.txt` and names itself in
/// `scrubprobe-state.txt`, then holds so a host script can screenshot it.
@MainActor
enum ScrubStatesProbe {
    static let streamURL = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8")!
    static let hold: Duration = .seconds(4)
    private static var keep: [AnyObject] = []

    static var caches: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0] }

    static func runAVKit() async {
        print("[ScrubProbe] states: AVKit")
        let playerVC = AVPlayerViewController()
        let player = AVPlayer(url: streamURL)
        playerVC.player = player
        playerVC.modalPresentationStyle = .fullScreen
        keep = [playerVC]
        await present(playerVC)
        player.play()
        try? await Task.sleep(for: .seconds(12))

        let controls = playerVC.descendantsOfClass("AVNowPlayingPlaybackControlsViewController").first
        let bar = (controls?.value(forKey: "transportBar") as? UIView)

        playerVC.call("_showPlaybackControlsViewIfNeededForUserInteraction")
        await capture("avkit-playing", root: playerVC.view, animationsOf: bar)

        player.pause()
        playerVC.call("_showPlaybackControlsViewIfNeededForUserInteraction")
        await capture("avkit-paused", root: playerVC.view, animationsOf: bar)

        bar?.call("scrubBegan")
        bar?.scrubMoved(translation: 240)
        await capture("avkit-scrub-near", root: playerVC.view, animationsOf: bar)

        bar?.scrubMoved(translation: 900)
        await capture("avkit-scrub-far", root: playerVC.view, animationsOf: bar)

        controls?.call("_showRotaryIndicator")
        await capture("avkit-ring", root: playerVC.view, animationsOf: bar)

        bar?.scrubEnded(translation: 900)
        await capture("avkit-scrub-ended", root: playerVC.view, animationsOf: bar)

        setState("done")
        print("[ScrubProbe] states done")
    }

    /// AVKit's tool-button menus: subtitles, audio, and a custom transport-bar menu.
    static func runAVKitMenus(brightOverlay: Bool = false) async {
        let playerVC = AVPlayerViewController()
        let player = AVPlayer(url: streamURL)
        playerVC.player = player
        playerVC.modalPresentationStyle = .fullScreen
        let filter = UIMenu(title: "Content Filter", image: UIImage(systemName: "hand.raised"), children: [
            UIAction(title: "Filtering On", state: .on) { _ in },
            UIAction(title: "Pause for This Title") { _ in },
        ])
        let insights = UIAction(title: "Insights", image: UIImage(systemName: "sparkles")) { _ in }
        playerVC.transportBarCustomMenuItems = [filter, insights]
        keep = [playerVC]
        await present(playerVC)
        if brightOverlay, let overlay = playerVC.contentOverlayView {
            // Left half white, right half white too but with a black stripe, so the
            // glass is measured over both extremes under the same menu.
            let white = UIView(frame: overlay.bounds)
            white.backgroundColor = .white
            white.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            let stripe = UIView(frame: CGRect(x: 1500, y: 0, width: 120, height: 1080))
            stripe.backgroundColor = .black
            white.addSubview(stripe)
            overlay.addSubview(white)
        }
        player.play()
        try? await Task.sleep(for: .seconds(12))
        player.pause()
        guard let window = playerVC.view.window else { return }
        playerVC.call("_showPlaybackControlsViewIfNeededForUserInteraction")
        try? await Task.sleep(for: .milliseconds(700))
        let collection = Self.toolRow(in: window)
        let paths = (collection?.subviews ?? [])
            .filter { NSStringFromClass(type(of: $0)).contains("ToolCell") }
            .sorted { $0.frame.minX < $1.frame.minX }
            .compactMap { ($0 as? UICollectionViewCell).flatMap { collection?.indexPath(for: $0) } }
        let count = paths.count
        let note = "row=\(collection.map { String(describing: type(of: $0)) } ?? "nil") items=\(count) paths=\(paths) sections=\(collection?.numberOfSections ?? -1) delegate=\(collection?.delegate.map { String(describing: type(of: $0)) } ?? "nil") controlsVisible=\(String(describing: (playerVC.descendantsOfClass("AVNowPlayingPlaybackControlsViewController").first)?.value(forKey: "areControlsVisible")))"
        try? note.write(to: caches.appendingPathComponent("scrubprobe-debug.txt"), atomically: true, encoding: .utf8)
        for item in 0..<count {
            guard let collection, let delegate = collection.delegate else { break }
            delegate.collectionView?(collection, didSelectItemAt: paths[item])
            await capture("menus\(brightOverlay ? "-bright" : "")-open-\(item)", root: window, animationsOf: window)
            if let menu = Self.find("AVUnifiedPlayerContextMenuView", in: window) {
                var lines = ["anchor=\(menu.layer.anchorPoint) wrapAnchor=\(menu.superview?.layer.anchorPoint ?? .zero)"]
                if let wrap = menu.superview, let mm = wrap.layer.animation(forKey: "kAVUnifiedPlayerContextMenuPositionMatchMove") {
                    for key in ["sourceLayer", "sourcePoints", "targetsSuperlayer", "usesNormalizedCoordinates", "appliesX", "appliesY", "appliesScale", "appliesRotation"] {
                        lines.append("matchMove.\(key)=\(String(describing: (mm as NSObject).value(forKey: key)))")
                    }
                }
                func dumpLayer(_ l: CALayer, _ depth: Int) {
                    var d = String(repeating: "  ", count: depth) + "\(type(of: l)) \(l.frame) r=\(l.cornerRadius) curve=\(l.cornerCurve.rawValue)"
                    if let bg = l.backgroundColor { d += " bg=\(UIColor(cgColor: bg))" }
                    if let f = l.compositingFilter { d += " compositing=\(f)" }
                    if let fs = l.filters, !fs.isEmpty {
                        d += " filters=\(fs.map { String(describing: $0) })"
                    }
                    if l.shadowOpacity > 0 { d += " shadow=\(l.shadowOpacity)/\(l.shadowRadius)/\(l.shadowOffset)" }
                    if l.borderWidth > 0 { d += " border=\(l.borderWidth)/\(l.borderColor.map { UIColor(cgColor: $0) }?.description ?? "-")" }
                    if l.opacity < 1 { d += " opacity=\(l.opacity)" }
                    lines.append(d)
                    for sub in l.sublayers ?? [] where depth < 6 { dumpLayer(sub, depth + 1) }
                }
                dumpLayer(menu.layer, 0)
                try? lines.joined(separator: "\n").write(to: caches.appendingPathComponent("scrubstate-menulayers-\(item).txt"), atomically: true, encoding: .utf8)
            }
            var top: UIViewController = playerVC
            while let presented = top.presentedViewController { top = presented }
            if top !== playerVC {
                top.dismiss(animated: true)
                await capture("menus\(brightOverlay ? "-bright" : "")-closing-\(item)", root: window, animationsOf: window)
            }
            playerVC.call("_showPlaybackControlsViewIfNeededForUserInteraction")
            try? await Task.sleep(for: .milliseconds(700))
        }
        setState("done")
        print("[ScrubProbe] menus done")
    }

    static func find(_ className: String, in view: UIView) -> UIView? {
        if NSStringFromClass(type(of: view)) == className { return view }
        for sub in view.subviews { if let found = find(className, in: sub) { return found } }
        return nil
    }

    /// Rivulet's popup with AVKit's subtitle-menu rows, from a stand-in button at
    /// AVKit's subtitles tool frame, over the same stream.
    static func runRivuletPopup() async {
        let vc = UIViewController()
        vc.modalPresentationStyle = .fullScreen
        vc.view.backgroundColor = .black
        // AVKit's own paused-with-controls frame, so both glass renders sit on the same pixels.
        let backdrop = UIImageView(image: UIImage(contentsOfFile: caches.appendingPathComponent("probe-backdrop.png").path))
        backdrop.frame = UIScreen.main.bounds
        vc.view.addSubview(backdrop)
        let player = AVPlayer(url: streamURL)
        let rail = UIView(frame: CGRect(x: 80, y: 796, width: 1760, height: 70))
        let button = UIView(frame: CGRect(x: 1596, y: 0, width: 70, height: 70))
        rail.addSubview(button)
        vc.view.addSubview(rail)
        keep = [vc, player]
        await present(vc)
        try? await Task.sleep(for: .seconds(2))
        let list = CardTrackListView(header: "Subtitles", rows: [
            .init(title: "On", subtitle: nil, trackId: 1, isSelected: false),
            .init(title: "Off", subtitle: nil, trackId: nil, isSelected: true),
            .init(title: "Language", subtitle: "English CC", trackId: 2, isSelected: false),
            .init(title: "Style", subtitle: "Transparent Background", trackId: 3, isSelected: false),
        ], onSelect: { _ in })
        let panel = PlayerRailPanelView.present(content: list, width: 450, in: vc.view, aboveRail: rail, towards: button)
        await capture("popup-opening", root: vc.view, animationsOf: panel)
        panel.dismissPanel()
        await capture("popup-closing", root: vc.view, animationsOf: panel)
        setState("done")
    }

    /// AVKit with every feature Rivulet has a counterpart for: title/description,
    /// chapters, info tabs, contextual action, custom menu. Captures the controls,
    /// then each focusable control outside the tool row, opened.
    static func runAVKitFullChrome() async {
        let playerVC = makeChromePlayer()
        keep = [playerVC]
        await present(playerVC)
        playerVC.player?.play()
        try? await Task.sleep(for: .seconds(12))
        playerVC.player?.pause()
        guard let window = playerVC.view.window else { return }
        // Every collection view on screen and its cells, so the below-bar row shows up by name.
        var lines: [String] = []
        func listCollections(_ v: UIView) {
            if let cv = v as? UICollectionView {
                let cells = cv.subviews.compactMap { $0 as? UICollectionViewCell }.sorted { $0.frame.minX < $1.frame.minX }
                lines.append("CV \(type(of: cv)) win=\(cv.convert(cv.bounds, to: window)) delegate=\(cv.delegate.map { String(describing: type(of: $0)) } ?? "-") cells=\(cells.map { "\(type(of: $0))@\(cv.indexPath(for: $0).map { "\($0.section).\($0.item)" } ?? "-")" })")
            }
            v.subviews.forEach(listCollections)
        }
        playerVC.call("_showPlaybackControlsViewIfNeededForUserInteraction")
        try? await Task.sleep(for: .milliseconds(500))
        listCollections(window)
        try? lines.joined(separator: "\n").write(to: caches.appendingPathComponent("scrubstate-chrome-collections.txt"), atomically: true, encoding: .utf8)

        // Open each below-bar pill through its own collection delegate.
        let controls = playerVC.descendantsOfClass("AVNowPlayingPlaybackControlsViewController").first
        for item in 0..<4 {
            playerVC.call("_showPlaybackControlsViewIfNeededForUserInteraction")
            try? await Task.sleep(for: .milliseconds(600))
            guard openInfoPane(item, controls: controls, in: window) else { break }
            await capture("chrome-tab-\(item)", root: window, animationsOf: window)
            if let controls {
                typealias Hide = @convention(c) (AnyObject, Selector, Bool, (@convention(block) () -> Void)?) -> Void
                let sel = NSSelectorFromString("hideInfoPaneAnimated:completion:")
                if controls.responds(to: sel) {
                    unsafeBitCast(controls.method(for: sel), to: Hide.self)(controls, sel, true, nil)
                    await capture("chrome-tab-\(item)-closing", root: window, animationsOf: window)
                }
            }
        }
        setState("done")
    }

    /// Selects AVKit's info pill `index` and opens its pane.
    private static func openInfoPane(_ index: Int, controls: NSObject?, in window: UIWindow) -> Bool {
        guard let pills = collection(containing: "AVInfoMenuCell", in: window) else { return false }
        typealias Show = @convention(c) (AnyObject, Selector, Bool, (@convention(block) () -> Void)?) -> Void
        typealias SetIndex = @convention(c) (AnyObject, Selector, UInt) -> Void
        if let menu = pills.delegate as? NSObject {
            let sel = NSSelectorFromString("setSelectedIndex:")
            if menu.responds(to: sel) { unsafeBitCast(menu.method(for: sel), to: SetIndex.self)(menu, sel, UInt(index)) }
        }
        if let controls {
            let sel = NSSelectorFromString("showInfoPaneAnimated:completion:")
            if controls.responds(to: sel) { unsafeBitCast(controls.method(for: sel), to: Show.self)(controls, sel, true, nil) }
        }
        return true
    }

    /// Focus as the remote leaves it: bar, tool button, pill, then inside an open
    /// pane (the selected pill's look). Moves go through the real focus engine.
    static func runAVKitFocus() async {
        let playerVC = makeChromePlayer(focusableTabs: true, skipIntro: false)
        keep = [playerVC]
        await present(playerVC)
        playerVC.player?.play()
        try? await Task.sleep(for: .seconds(12))
        playerVC.player?.pause()
        guard let window = playerVC.view.window else { return }
        playerVC.call("_showPlaybackControlsViewIfNeededForUserInteraction")
        try? await Task.sleep(for: .seconds(1))
        await capture("focus-bar", root: window, animationsOf: window)
        // AVKit hides its controls after a few idle seconds; wake them before each move.
        var focusLog: [String] = []
        func step(_ target: UIView?, _ name: String) async {
            playerVC.call("_showPlaybackControlsViewIfNeededForUserInteraction")
            try? await Task.sleep(for: .milliseconds(400))
            if let target { UIFocusSystem.focusSystem(for: window)?.requestFocusUpdate(to: target) }
            UIFocusSystem.focusSystem(for: window)?.updateFocusIfNeeded()
            focusLog.append("\(name): \(DebugFocusDriver.describeFocus(in: window))")
            await capture(name, root: window, animationsOf: window)
        }
        // Remote-style moves, logging where focus lands after each.
        for (heading, name) in [(UIFocusHeading.down, "focus-m1"), (.up, "focus-m2"), (.down, "focus-m3"), (.down, "focus-m4"), (.right, "focus-m5")] {
            playerVC.call("_showPlaybackControlsViewIfNeededForUserInteraction")
            try? await Task.sleep(for: .milliseconds(300))
            let moved = DebugFocusDriver.move(heading, in: window)
            try? await Task.sleep(for: .milliseconds(300))
            focusLog.append("\(name) moved=\(moved): \(DebugFocusDriver.describeFocus(in: window))")
            await capture(name, root: window, animationsOf: window)
        }
        try? focusLog.joined(separator: "\n").write(to: caches.appendingPathComponent("scrubstate-focuslog.txt"), atomically: true, encoding: .utf8)

        let controls = playerVC.descendantsOfClass("AVNowPlayingPlaybackControlsViewController").first
        _ = openInfoPane(2, controls: controls, in: window)
        try? await Task.sleep(for: .seconds(1))
        if let dimming = window.firstDescendant(named: "AVNowPlayingDimmingView") {
            var lines = ["# dimming"]
            for key in ["dimsEntireBounds", "dimsReducedAmount", "flatBackdrop", "gradientBackdrop", "reducedGradientBackdrop"] {
                let value = dimming.value(forKey: key)
                var line = "\(key)=\(String(describing: value))"
                if let v = value as? UIView {
                    line += " super=\(v.superview.map { String(describing: type(of: $0)) } ?? "nil") win=\(fmt(v.convert(v.bounds, to: window))) a=\(fmt(v.alpha)) hidden=\(v.isHidden) bg=\(color(v.backgroundColor?.cgColor)) layerBG=\(color(v.layer.backgroundColor))"
                    if v.responds(to: NSSelectorFromString("colors")), let colors = v.value(forKey: "colors") as? [Any] { line += " colors=\(colors)" }
                }
                lines.append(line)
            }
            lines.append("dimming layerBG=\(color(dimming.layer.backgroundColor)) bg=\(color(dimming.backgroundColor?.cgColor)) sublayers=\(dimming.layer.sublayers?.map { "\(type(of: $0)) \($0.frame) op=\($0.opacity) bg=\(color($0.backgroundColor))" } ?? [])")
            try? lines.joined(separator: "\n").write(to: caches.appendingPathComponent("scrubstate-dimming.txt"), atomically: true, encoding: .utf8)
        }
        await capture("focus-pane-pill", root: window, animationsOf: window)
        DebugFocusDriver.move(.down, in: window)
        await capture("focus-pane-content", root: window, animationsOf: window)
        DebugFocusDriver.move(.up, in: window)
        await capture("focus-pane-back", root: window, animationsOf: window)
        setState("done")
    }

    /// Drives AVKit's bar through its focus appearance, scanning and skips
    /// with its own private selectors, dumping each state.
    static func runAVKitBarStates() async {
        let playerVC = makeChromePlayer(focusableTabs: true, skipIntro: false)
        keep = [playerVC]
        await present(playerVC)
        let stripes = ProcessInfo.processInfo.environment["RIVULET_SCRUBPROBE_STRIPES"] == "1"
        if stripes, let overlay = playerVC.contentOverlayView {
            for (index, white) in [1.0, 0.0, 0.5, 1.0, 0.0, 0.75, 0.25, 1.0].enumerated() {
                let stripe = UIView(frame: CGRect(x: CGFloat(index) * 240, y: 0, width: 240, height: 1080))
                stripe.backgroundColor = UIColor(white: white, alpha: 1)
                overlay.addSubview(stripe)
            }
        }
        playerVC.player?.play()
        try? await Task.sleep(for: .seconds(12))
        playerVC.player?.pause()
        guard let window = playerVC.view.window,
              let bar = window.firstDescendant(named: "AVNowPlayingTransportBar"),
              let controls = playerVC.descendantsOfClass("AVNowPlayingPlaybackControlsViewController").first
        else { return }
        typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
        typealias SetDouble = @convention(c) (AnyObject, Selector, Double) -> Void
        func send(_ target: NSObject, _ name: String, _ value: Bool) {
            let sel = NSSelectorFromString(name)
            guard target.responds(to: sel) else { return print("[BarStates] no \(name)") }
            unsafeBitCast(target.method(for: sel), to: SetBool.self)(target, sel, value)
        }
        func show() { playerVC.call("_showPlaybackControlsViewIfNeededForUserInteraction") }
        func quick(_ name: String, settle: Duration = .milliseconds(600)) async {
            var lines = ["# \(name)", "## animations (sampled 30ms after trigger)"]
            try? await Task.sleep(for: .milliseconds(30))
            lines += animationLines(in: window)
            try? await Task.sleep(for: settle)
            lines.append("## tree (settled) t=\(playerVC.player?.currentTime().seconds ?? -1) rate=\(playerVC.player?.rate ?? -1)")
            walk(window, window: window, depth: 0, into: &lines)
            lines.append("## images and bar layers")
            func images(_ v: UIView) {
                if let iv = v as? UIImageView, !iv.isHidden, iv.alpha > 0, let img = iv.image {
                    lines.append("img \(fmt(iv.convert(iv.bounds, to: window))) tint=\(color(iv.tintColor.cgColor)) \(img)")
                }
                v.subviews.forEach(images)
            }
            if let host = bar.superview { images(host) }
            func layers(_ l: CALayer, _ depth: Int) {
                let f = l.convert(l.bounds, to: window.layer)
                var d = String(repeating: "  ", count: depth) + "\(type(of: l)) \(fmt(f)) op=\(l.opacity) hidden=\(l.isHidden) bg=\(color(l.backgroundColor))"
                if let c = l.compositingFilter { d += " comp=\(c)" }
                if let fs = l.filters, !fs.isEmpty { d += " filters=\(fs)" }
                if l.contents != nil { d += " contents" }
                if l.mask != nil { d += " mask" }
                lines.append(d)
                l.sublayers?.forEach { layers($0, depth + 1) }
            }
            layers(bar.layer, 0)
            try? lines.joined(separator: "\n").write(to: caches.appendingPathComponent("scrubstate-\(name).txt"), atomically: true, encoding: .utf8)
            setState(name)
            try? await Task.sleep(for: .milliseconds(1500))
        }
        show()
        try? await Task.sleep(for: .seconds(1))
        await quick("bs-focused")
        show()
        send(bar, "_setBarFocusAppearance:", false)
        send(bar, "_setTimeLabelFocusAppearance:", false)
        await quick("bs-unfocused")
        show()
        send(bar, "_setBarFocusAppearance:", true)
        send(bar, "_setTimeLabelFocusAppearance:", true)
        await quick("bs-refocused")
        if stripes { return setState("done") }

        for i in 1...4 {
            show()
            controls.call("scanForwardNext")
            await quick("bs-scan\(i)")
        }
        controls.call("cancelScanning")
        playerVC.player?.pause()
        try? await Task.sleep(for: .seconds(1))
        for i in 1...2 {
            show()
            controls.call("scanBackwardNext")
            await quick("bs-rscan\(i)")
        }
        controls.call("cancelScanning")
        playerVC.player?.pause()
        try? await Task.sleep(for: .seconds(1))
        typealias Skip = @convention(c) (AnyObject, Selector, Double, Bool) -> Void
        func skip(_ by: Double, seeking: Bool) {
            let sel = NSSelectorFromString("_skipDisplayTimeByAdding:seeking:")
            guard controls.responds(to: sel) else { return print("[BarStates] no skip selector") }
            if let m = class_getInstanceMethod(type(of: controls), sel), let enc = method_getTypeEncoding(m) {
                print("[BarStates] skip encoding \(String(cString: enc))")
            }
            unsafeBitCast(controls.method(for: sel), to: Skip.self)(controls, sel, by, seeking)
        }
        show()
        skip(-10, seeking: false)
        await quick("bs-skip-paused-back", settle: .milliseconds(250))
        show()
        skip(10, seeking: false)
        await quick("bs-skip-paused-fwd", settle: .milliseconds(250))
        controls.call("cancelScanning")
        playerVC.player?.play()
        try? await Task.sleep(for: .seconds(2))
        show()
        skip(10, seeking: true)
        await quick("bs-skip-playing-fwd", settle: .milliseconds(250))
        show()
        skip(-10, seeking: true)
        await quick("bs-skip-playing-back", settle: .milliseconds(250))
        setState("done")
    }

    /// How long AVKit's skip glyph stays beside the time, and how it leaves.
    static func runAVKitSkipTiming() async {
        let playerVC = makeChromePlayer(focusableTabs: true, skipIntro: false)
        keep = [playerVC]
        await present(playerVC)
        playerVC.player?.play()
        try? await Task.sleep(for: .seconds(12))
        guard let window = playerVC.view.window,
              let controls = playerVC.descendantsOfClass("AVNowPlayingPlaybackControlsViewController").first
        else { return }
        typealias Skip = @convention(c) (AnyObject, Selector, Double, Bool) -> Void
        let sel = NSSelectorFromString("_skipDisplayTimeByAdding:seeking:")
        func glyph() -> UIImageView? {
            func find(_ v: UIView) -> UIImageView? {
                if let iv = v as? UIImageView, let img = iv.image, img.description.contains("goforward") || img.description.contains("gobackward") { return iv }
                for sub in v.subviews { if let f = find(sub) { return f } }
                return nil
            }
            return find(window)
        }
        // Glyph's own opacity (up to the bar's container) apart from the chrome's.
        let barHost = window.firstDescendant(named: "AVNowPlayingTransportBar")?.superview
        func opacity(_ v: UIView, until stop: UIView?) -> Float {
            var o: Float = 1
            var cur: UIView? = v
            while let c = cur, c !== stop { o *= (c.layer.presentation() ?? c.layer).opacity * (c.isHidden ? 0 : 1); cur = c.superview }
            return o
        }
        var lines: [String] = []
        for (label, paused, keepAlive) in [("playing", false, false), ("playing-kept", false, true), ("paused", true, false)] {
            if paused { playerVC.player?.pause() }
            playerVC.call("_showPlaybackControlsViewIfNeededForUserInteraction")
            try? await Task.sleep(for: .seconds(1))
            let start = Date()
            unsafeBitCast(controls.method(for: sel), to: Skip.self)(controls, sel, 10, !paused)
            var last = ""
            var lastPoke = start
            var lastTime = playerVC.player?.currentTime().seconds ?? 0
            while Date().timeIntervalSince(start) < 12 {
                let now = playerVC.player?.currentTime().seconds ?? 0
                if abs(now - lastTime) > 2 {
                    lines.append("\(label) +\(String(format: "%.2f", Date().timeIntervalSince(start)))s seek landed \(String(format: "%.1f", lastTime)) -> \(String(format: "%.1f", now))")
                }
                lastTime = now
                if keepAlive, Date().timeIntervalSince(lastPoke) > 1 {
                    playerVC.call("_showPlaybackControlsViewIfNeededForUserInteraction")
                    lastPoke = Date()
                }
                let chrome = window.firstDescendant(named: "AVNowPlayingTransportBar").map { opacity($0, until: nil) } ?? -1
                let state = (glyph().map { "glyph=\(String(format: "%.2f", opacity($0, until: barHost)))" } ?? "glyph=absent")
                    + " chrome=\(String(format: "%.2f", chrome))"
                if state != last {
                    lines.append("\(label) +\(String(format: "%.2f", Date().timeIntervalSince(start)))s \(state)")
                    last = state
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        try? lines.joined(separator: "\n").write(to: caches.appendingPathComponent("scrubstate-bs-skiptiming.txt"), atomically: true, encoding: .utf8)
        setState("done")
    }

    static var descriptionOverride: String?

    /// Select on the Info card's summary: what AVKit opens and how it animates.
    static func runAVKitSummary() async {
        if ProcessInfo.processInfo.environment["RIVULET_SCRUBPROBE_LONG"] == "1" {
            descriptionOverride = Array(repeating: "A test card wanders through ten minutes of tones and a pie chart, and learns something about itself along the way, as test cards do.", count: 9).joined(separator: " ")
        }
        let playerVC = makeChromePlayer()
        keep = [playerVC]
        await present(playerVC)
        playerVC.player?.play()
        try? await Task.sleep(for: .seconds(12))
        playerVC.player?.pause()
        guard let window = playerVC.view.window else { return }
        let controls = playerVC.descendantsOfClass("AVNowPlayingPlaybackControlsViewController").first
        playerVC.call("_showPlaybackControlsViewIfNeededForUserInteraction")
        try? await Task.sleep(for: .seconds(1))
        _ = openInfoPane(0, controls: controls, in: window)
        try? await Task.sleep(for: .seconds(2))
        // The summary: the focusable view whose frame starts at the card's text column.
        var summary: UIView?
        func find(_ v: UIView) {
            let f = v.convert(v.bounds, to: window)
            if summary == nil, v.canBecomeFocused, f.minX > 250, f.minX < 300, f.minY > 790, f.minY < 840 { summary = v }
            v.subviews.forEach(find)
        }
        find(window)
        var log = ["summary=\(summary.map { "\(type(of: $0)) \(fmt($0.convert($0.bounds, to: window)))" } ?? "nil")"]
        if let summary {
            UIFocusSystem.focusSystem(for: window)?.requestFocusUpdate(to: summary)
            UIFocusSystem.focusSystem(for: window)?.updateFocusIfNeeded()
            try? await Task.sleep(for: .milliseconds(600))
            log.append("focus=\(DebugFocusDriver.describeFocus(in: window))")
            await capture("sum-focused", root: window, animationsOf: window)
            var cur: UIView? = summary
            while let v = cur, v !== window {
                for g in v.gestureRecognizers ?? [] {
                    log.append("gesture on \(type(of: v)): \(g) presses=\(g.allowedPressTypes)")
                }
                cur = v.superview
            }
            if let control = summary as? UIControl {
                log.append("control actions=\(control.allTargets.map { "\($0)" }) events=\(control.allControlEvents.rawValue)")
                control.sendActions(for: .primaryActionTriggered)
                control.sendActions(for: .touchUpInside)
            } else {
                // Fire the select tap recognizer's own targets.
                var fired = false
                var cur: UIView? = summary
                while let v = cur, v !== window, !fired {
                    for g in v.gestureRecognizers ?? [] where g is UITapGestureRecognizer {
                        guard let targets = g.value(forKey: "_targets") as? [NSObject] else { continue }
                        for t in targets {
                            guard let target = t.value(forKey: "_target") as? NSObject else { continue }
                            let desc = String(describing: t)
                            log.append("target \(desc)")
                            if let range = desc.range(of: "action=") {
                                let name = desc[range.upperBound...].prefix { $0 != "," && $0 != ")" }
                                let sel = NSSelectorFromString(String(name))
                                if target.responds(to: sel) { _ = target.perform(sel, with: g); fired = true }
                            }
                        }
                    }
                    cur = v.superview
                }
                log.append("fired=\(fired)")
            }
            await capture("sum-opened", root: window, animationsOf: window)
            try? await Task.sleep(for: .seconds(1))
            await capture("sum-settled", root: window, animationsOf: window)
            // The platter's layers, for its material.
            var platter: UIView?
            func findPlatter(_ v: UIView) {
                if platter == nil, abs(v.layer.cornerRadius - 28) < 0.5, v.bounds.width > 700 { platter = v }
                v.subviews.forEach(findPlatter)
            }
            findPlatter(window)
            func layers(_ l: CALayer, _ depth: Int) {
                var d = String(repeating: "  ", count: depth) + "\(type(of: l)) \(fmt(l.convert(l.bounds, to: window.layer))) op=\(l.opacity) bg=\(color(l.backgroundColor)) r=\(l.cornerRadius)"
                if let c = l.compositingFilter { d += " comp=\(c)" }
                if let fs = l.filters, !fs.isEmpty { d += " filters=\(fs)" }
                if let delegate = l.delegate { d += " view=\(type(of: delegate))" }
                log.append(d)
                l.sublayers?.forEach { layers($0, depth + 1) }
            }
            if let platter, let presented = platter.superview {
                log.append("## platter layers (superview \(type(of: presented)) bg=\(color(presented.backgroundColor?.cgColor)))")
                layers(platter.layer, 0)
                if let effect = platter.subviews.compactMap({ $0 as? UIVisualEffectView }).first { log.append("effect \(String(describing: effect.effect))") }
            }
            // Menu: the presentation's own back gesture.
            var back: (NSObject, UIGestureRecognizer)?
            func findBack(_ v: UIView) {
                for g in v.gestureRecognizers ?? [] where String(describing: g).contains("_performBackGesture") {
                    if let t = (g.value(forKey: "_targets") as? [NSObject])?.first?.value(forKey: "_target") as? NSObject { back = (t, g) }
                }
                v.subviews.forEach(findBack)
            }
            findBack(window)
            log.append("back=\(back.map { "\(type(of: $0.0))" } ?? "nil")")
            if let back {
                _ = back.0.perform(NSSelectorFromString("_performBackGesture:"), with: back.1)
                await capture("sum-back", root: window, animationsOf: window)
                log.append("after back focus=\(DebugFocusDriver.describeFocus(in: window))")
            }
        }
        try? log.joined(separator: "\n").write(to: caches.appendingPathComponent("scrubstate-sum-log.txt"), atomically: true, encoding: .utf8)
        setState("done")
    }

    /// For a person with a remote: logs, with times, where focus is and
    /// whether the chrome is up, so auto-hide can be read per focus target.
    static func runAVKitChromeWatch() async {
        let playerVC = makeChromePlayer(focusableTabs: false, skipIntro: false)
        keep = [playerVC]
        await present(playerVC)
        playerVC.player?.play()
        try? await Task.sleep(for: .seconds(3))
        guard let window = playerVC.view.window else { return }
        playerVC.call("_showPlaybackControlsViewIfNeededForUserInteraction")
        let start = Date()
        var last = ""
        var lines: [String] = []
        var n = 0
        while Date().timeIntervalSince(start) < 300 {
            let bar = window.firstDescendant(named: "AVNowPlayingTransportBar")
            var chrome: Float = 0
            if let bar {
                chrome = 1
                var cur: UIView? = bar
                while let c = cur { chrome *= (c.layer.presentation() ?? c.layer).opacity * (c.isHidden ? 0 : 1); cur = c.superview }
            }
            var focusedCells: [String] = []
            func visit(_ v: UIView) {
                if v.isFocused { focusedCells.append("\(type(of: v)) \(fmt(v.convert(v.bounds, to: window)))") }
                v.subviews.forEach(visit)
            }
            visit(window)
            let state = "chrome=\(chrome > 0.5 ? "up" : "hidden") focus=\(focusedCells.joined(separator: ", "))"
            if state != last {
                last = state
                n += 1
                lines.append(String(format: "+%.1fs ", Date().timeIntervalSince(start)) + state)
                try? lines.joined(separator: "\n").write(to: caches.appendingPathComponent("scrubstate-chromewatch.txt"), atomically: true, encoding: .utf8)
                setState("c\(n)")
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        setState("done")
    }

    /// Menu with the Info pane open: fires the Menu tap recognizer nearest the
    /// focused pill, the way a press would reach it first, and records the result.
    static func runAVKitPaneMenu() async {
        let playerVC = makeChromePlayer()
        keep = [playerVC]
        await present(playerVC)
        playerVC.player?.play()
        try? await Task.sleep(for: .seconds(8))
        guard let window = playerVC.view.window else { return }
        let controls = playerVC.descendantsOfClass("AVNowPlayingPlaybackControlsViewController").first
        playerVC.call("_showPlaybackControlsViewIfNeededForUserInteraction")
        try? await Task.sleep(for: .seconds(1))
        _ = openInfoPane(0, controls: controls, in: window)
        try? await Task.sleep(for: .seconds(1.5))
        var log: [String] = []
        func snapshot(_ name: String) async {
            let bar = window.firstDescendant(named: "AVNowPlayingTransportBar")
            var chrome: Float = bar == nil ? 0 : 1
            var cur: UIView? = bar
            while let c = cur { chrome *= c.layer.opacity * (c.isHidden ? 0 : 1); cur = c.superview }
            log.append("\(name): focus=\(DebugFocusDriver.describeFocus(in: window)) bar=\(chrome) rate=\(playerVC.player?.rate ?? -1) presented=\(playerVC.presentingViewController != nil)")
            setState(name)
            try? await Task.sleep(for: .seconds(1.5))
        }
        await snapshot("pm-open")
        func fireMenu() {
            guard let focused = UIFocusSystem.focusSystem(for: window)?.focusedItem as? UIView else { return }
            var cur: UIView? = focused
            while let v = cur {
                for g in v.gestureRecognizers ?? [] where g.isEnabled && g.allowedPressTypes.contains(NSNumber(value: UIPress.PressType.menu.rawValue)) {
                    guard let t = (g.value(forKey: "_targets") as? [NSObject])?.first,
                          let target = t.value(forKey: "_target") as? NSObject else { continue }
                    let desc = String(describing: t)
                    guard let r = desc.range(of: "action=") else { continue }
                    let name = String(desc[r.upperBound...].prefix { $0 != "," && $0 != ")" })
                    log.append("menu -> \(type(of: v)) \(name)")
                    _ = target.perform(NSSelectorFromString(name), with: g)
                    return
                }
                cur = v.superview
            }
        }
        fireMenu()
        try? await Task.sleep(for: .seconds(1))
        await snapshot("pm-menu1")
        fireMenu()
        try? await Task.sleep(for: .seconds(1))
        await snapshot("pm-menu2")
        try? log.joined(separator: "\n").write(to: caches.appendingPathComponent("scrubstate-panemenu.txt"), atomically: true, encoding: .utf8)
        setState("done")
    }

    /// AVKit's selectors whose names suggest skip, scan or focus handling.
    static func runAVKitMethods() async {
        let playerVC = makeChromePlayer(focusableTabs: true, skipIntro: false)
        keep = [playerVC]
        await present(playerVC)
        playerVC.player?.play()
        try? await Task.sleep(for: .seconds(6))
        guard let window = playerVC.view.window else { return }
        var classes: [AnyClass] = []
        func collect(_ object: AnyObject) {
            var cls: AnyClass? = type(of: object)
            while let c = cls, NSStringFromClass(c).hasPrefix("AV") || NSStringFromClass(c).hasPrefix("_AV") {
                if !classes.contains(where: { $0 == c }) { classes.append(c) }
                cls = class_getSuperclass(c)
            }
        }
        func visit(_ view: UIView) {
            collect(view)
            if let next = view.next as? UIViewController { collect(next) }
            view.subviews.forEach(visit)
        }
        visit(window)
        for name in ["AVScrubbingController", "AVTransportBarScrubbingController", "AVPlaybackControlsController"] {
            if let c = NSClassFromString(name), !classes.contains(where: { $0 == c }) { classes.append(c) }
        }
        let keys = ["skip", "scan", "focus", "dim", "emphas", "seek", "jump", "highlight", "active", "scrub", "rate", "press", "hint", "glyph", "indicator", "direction"]
        var lines: [String] = []
        for c in classes {
            var count: UInt32 = 0
            guard let list = class_copyMethodList(c, &count) else { continue }
            var hits: [String] = []
            for i in 0..<Int(count) {
                let sel = NSStringFromSelector(method_getName(list[i]))
                if keys.contains(where: { sel.lowercased().contains($0) }) { hits.append(sel) }
            }
            free(list)
            if !hits.isEmpty { lines.append("# \(NSStringFromClass(c))"); lines.append(contentsOf: hits.sorted()) }
        }
        try? lines.joined(separator: "\n").write(to: caches.appendingPathComponent("scrubstate-methods.txt"), atomically: true, encoding: .utf8)
        setState("done")
    }

    /// AVKit's Info card over a white/black/gray stripe pattern in the content
    /// overlay: captures the card, then the same frame with the card hidden.
    static func runAVKitInfoCardOverPattern() async {
        let playerVC = makeChromePlayer()
        keep = [playerVC]
        await present(playerVC)
        if let overlay = playerVC.contentOverlayView {
            for (index, white) in [1.0, 0.0, 0.5, 1.0, 0.0, 0.75, 0.25, 1.0].enumerated() {
                let stripe = UIView(frame: CGRect(x: CGFloat(index) * 240, y: 0, width: 240, height: 1080))
                stripe.backgroundColor = UIColor(white: white, alpha: 1)
                overlay.addSubview(stripe)
            }
        }
        playerVC.player?.play()
        try? await Task.sleep(for: .seconds(12))
        playerVC.player?.pause()
        guard let window = playerVC.view.window else { return }
        let controls = playerVC.descendantsOfClass("AVNowPlayingPlaybackControlsViewController").first
        // The tool buttons and pills, then the same frame without them.
        playerVC.call("_showPlaybackControlsViewIfNeededForUserInteraction")
        try? await Task.sleep(for: .seconds(1))
        setState("controls-on")
        try? await Task.sleep(for: .seconds(1.5))
        let rows = [toolRow(in: window), collection(containing: "AVInfoMenuCell", in: window)].compactMap { $0 }
        playerVC.call("_showPlaybackControlsViewIfNeededForUserInteraction")
        rows.forEach { $0.isHidden = true }
        try? await Task.sleep(for: .milliseconds(500))
        setState("controls-off")
        try? await Task.sleep(for: .seconds(1.5))
        rows.forEach { $0.isHidden = false }
        playerVC.call("_showPlaybackControlsViewIfNeededForUserInteraction")
        try? await Task.sleep(for: .milliseconds(600))
        _ = openInfoPane(0, controls: controls, in: window)
        try? await Task.sleep(for: .seconds(2))
        setState("infocard-on")
        try? await Task.sleep(for: .seconds(2))
        var card: UIView?
        func find(_ v: UIView) {
            let f = v.convert(v.bounds, to: window)
            if card == nil, abs(f.minX - 80) < 1, abs(f.minY - 744) < 1, abs(f.width - 1760) < 1, abs(f.height - 250) < 1 { card = v }
            v.subviews.forEach(find)
        }
        find(window)
        card?.isHidden = true
        try? await Task.sleep(for: .milliseconds(500))
        setState("infocard-off")
        try? await Task.sleep(for: .seconds(2))
        setState("done")
    }

    /// Twelve facts in four categories and three lengths. The simulator can't
    /// fetch real trivia (the Worker requires App Attest).
    static var fixtureTrivia: TitleTrivia? {
        let sentence = "Walker did most of his own driving, and the crew rebuilt the hero car twice after the bridge jump. "
        let facts = (0..<12).map { i -> String in
            let category = ["production", "casting", "music", "goof"][i % 4]
            let text = String(repeating: sentence, count: 1 + i % 3)
            return "{ \"id\": \"f\(i)\", \"text\": \"\(text)\", \"category\": \"\(category)\", \"interest\": \(9 - i % 4), \"source\": { \"name\": \"Wikipedia\", \"url\": \"https://w\" } }"
        }
        let json = "{ \"id\": \"tmdb://1\", \"type\": \"movie\", \"generatedAt\": \"\", \"pipelineVersion\": 2, \"attribution\": [{ \"name\": \"Wikipedia\", \"url\": \"https://w\" }], \"facts\": [\(facts.joined(separator: ","))] }"
        return try? JSONDecoder().decode(TitleTrivia.self, from: Data(json.utf8))
    }

    /// Our Info card over AVKit's pane backdrop (probe-backdrop.png in Caches) at
    /// AVKit's card frame. RIVULET_SCRUBPROBE_WASH="white,alpha" overrides the wash.
    static func runCardGlass(env: [String: String]) async {
        let vc = UIViewController()
        vc.modalPresentationStyle = .fullScreen
        let backdrop = UIImageView(image: UIImage(contentsOfFile: caches.appendingPathComponent("probe-backdrop.png").path))
        backdrop.frame = UIScreen.main.bounds
        vc.view.addSubview(backdrop)
        let wash = env["RIVULET_SCRUBPROBE_WASH"]?.split(separator: ",").compactMap({ Double($0) })
        let washColor = wash.flatMap { $0.count == 2 ? UIColor(white: $0[0], alpha: $0[1]) : nil }
        if env["RIVULET_SCRUBPROBE_PART"] == "controls" {
            // AVKit's pill and tool frames in the controls state.
            for frame in [CGRect(x: 80, y: 970, width: 109, height: 64), CGRect(x: 213, y: 970, width: 179, height: 64),
                          CGRect(x: 416, y: 970, width: 162, height: 64), CGRect(x: 602, y: 970, width: 165, height: 64)] {
                let pill = PlayerInfoPillButton(title: "")
                pill.translatesAutoresizingMaskIntoConstraints = true
                pill.frame = frame
                vc.view.addSubview(pill)
                if let washColor { pill.subviews.first?.backgroundColor = washColor }
            }
            for x in [1582.0, 1676, 1770] {
                let tool = TransportControlButton(icon: nil, accessibilityLabel: "", diameter: 70)
                tool.translatesAutoresizingMaskIntoConstraints = true
                tool.frame = CGRect(x: x, y: 796, width: 70, height: 70)
                vc.view.addSubview(tool)
                if let washColor { tool.subviews.first?.backgroundColor = washColor }
            }
        } else {
            let card = PlayerInfoCardView(content: .init(posterURL: nil, title: "", summary: nil, genre: nil,
                                                         runtimeMinutes: nil, badges: []))
            card.frame = CGRect(x: 80, y: 744, width: 1760, height: 250)
            vc.view.addSubview(card)
            if let washColor, let glass = card.subviews.first(where: { $0 is UIVisualEffectView }) as? UIVisualEffectView {
                glass.contentView.subviews.first?.backgroundColor = washColor
            }
        }
        keep = [vc]
        await present(vc)
        try? await Task.sleep(for: .seconds(2))
        setState("cardglass")
        try? await Task.sleep(for: .seconds(3))
        setState("done")
    }

    /// AVKit with every feature Rivulet has a counterpart for. `focusableTabs`
    /// puts a focusable view in each custom tab.
    private static func makeChromePlayer(focusableTabs: Bool = false, skipIntro: Bool = true) -> AVPlayerViewController {
        let playerVC = AVPlayerViewController()
        let item = AVPlayerItem(url: streamURL)
        func meta(_ id: AVMetadataIdentifier, _ value: Any) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value as? NSCopying & NSObjectProtocol
            m.extendedLanguageTag = "und"
            return m
        }
        let artwork = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 900)).image { ctx in
            UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 900))
        }.pngData()!
        item.externalMetadata = [
            meta(.commonIdentifierTitle, "S1 E3 · The Bipbop Test"),
            meta(.iTunesMetadataTrackSubTitle, "Bipbop Show"),
            meta(.commonIdentifierDescription, descriptionOverride ?? "A test card wanders through ten minutes of tones and a pie chart, and learns something about itself."),
            meta(.quickTimeMetadataGenre, "Drama"),
            meta(.iTunesMetadataContentRating, "TV-PG"),
            meta(.commonIdentifierArtwork, artwork),
        ]
        let chapters: [AVTimedMetadataGroup] = (0..<5).map { i in
            AVTimedMetadataGroup(items: [meta(.commonIdentifierTitle, "Chapter \(i + 1)")],
                                 timeRange: CMTimeRange(start: CMTime(seconds: Double(i) * 120, preferredTimescale: 600),
                                                        duration: CMTime(seconds: 120, preferredTimescale: 600)))
        }
        item.navigationMarkerGroups = [AVNavigationMarkersGroup(title: nil, timedNavigationMarkers: chapters)]
        playerVC.player = AVPlayer(playerItem: item)
        playerVC.modalPresentationStyle = .fullScreen
        func infoTab(_ title: String, _ color: UIColor) -> UIViewController {
            let vc = UIViewController()
            vc.title = title
            vc.view.backgroundColor = color.withAlphaComponent(0.3)
            vc.preferredContentSize = CGSize(width: 0, height: 300)
            if focusableTabs {
                let button = UIButton(type: .system)
                button.setTitle("Focusable", for: .normal)
                button.frame = CGRect(x: 40, y: 40, width: 400, height: 120)
                vc.view.addSubview(button)
            }
            return vc
        }
        playerVC.customInfoViewControllers = [infoTab("Insights", .systemPurple), infoTab("Up Next", .systemBlue)]
        if skipIntro { playerVC.contextualActions = [UIAction(title: "Skip Intro") { _ in }] }
        playerVC.transportBarCustomMenuItems = [UIMenu(title: "Content Filter", image: UIImage(systemName: "hand.raised"), children: [
            UIAction(title: "Filtering On", state: .on) { _ in }, UIAction(title: "Pause for This Title") { _ in }])]
        return playerVC
    }

    static func collection(containing cellClass: String, in view: UIView) -> UICollectionView? {
        if let cv = view as? UICollectionView,
           cv.subviews.contains(where: { NSStringFromClass(type(of: $0)) == cellClass }) { return cv }
        for sub in view.subviews { if let found = collection(containing: cellClass, in: sub) { return found } }
        return nil
    }

    /// The real rail at the VOD player's constraints, opening each menu from its button.
    static func runRailPopups() async {
        let vc = UIViewController()
        vc.modalPresentationStyle = .fullScreen
        // AVKit's raw paused frame with no chrome, so our dimming and controls
        // composite over the same pixels AVKit's did.
        let backdrop = UIImageView(image: UIImage(contentsOfFile: caches.appendingPathComponent("probe-video.png").path))
        backdrop.frame = UIScreen.main.bounds
        vc.view.addSubview(backdrop)
        let scrim = ChromeScrimView()
        scrim.frame = UIScreen.main.bounds
        vc.view.addSubview(scrim)
        let rail = PlayerRailView()
        rail.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(rail)
        let bar = PlayerProgressBarView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(bar)
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            rail.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
            rail.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor),
            rail.heightAnchor.constraint(equalToConstant: PlayerRailView.railHeight),
            bar.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor, constant: PlayerRailView.sideInset),
            bar.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor, constant: -PlayerRailView.sideInset),
            bar.topAnchor.constraint(equalTo: rail.topAnchor, constant: PlayerRailView.barTop),
        ])
        rail.setTitle("S1 E3 · The Bipbop Test", eyebrow: "Bipbop Show")
        rail.setFilterAvailable(true)
        rail.setFilterActive(true)
        rail.setInsightsAvailable(true)
        rail.setUpNextAvailable(true)
        keep = [vc]
        await present(vc)
        bar.update(currentTime: 12.3, duration: 600, isScrubbing: false, scrubTime: 12.3,
                   scrubThumbnail: nil, markers: [], chapters: [])
        bar.setPausedDim(true)
        try? await Task.sleep(for: .seconds(1))
        await capture("rail-controls", root: vc.view, animationsOf: rail)
        let menus: [(String, UIView, CardTrackListView)] = [
            ("subtitles", rail.subtitlesButton, CardTrackListView(
                header: "Subtitles",
                tracks: [MediaTrack(id: 1, name: "English", language: "English", languageCode: "en", codec: "srt"),
                         MediaTrack(id: 2, name: "English (SDH)", language: "English", languageCode: "en", codec: "pgs")],
                selectedTrackId: 1, showsOffRow: true,
                steppers: [CardStepperConfig(title: "Delay", value: { "0.0s" }, onStep: { _ in }),
                           CardStepperConfig(title: "Height", value: { "0" }, onStep: { _ in })],
                onSelect: { _ in })),
            ("filter", rail.filterButton, CardTrackListView(header: "Content Filter", rows: [
                .init(title: "Filtering On", subtitle: nil, trackId: 0, isSelected: true),
                .init(title: "Pause for This Title", subtitle: nil, trackId: 1, isSelected: false),
            ], onSelect: { _ in })),
        ]
        for (name, button, list) in menus {
            let panel = PlayerRailPanelView.present(content: list, width: 450, in: vc.view, aboveRail: rail, towards: button)
            await capture("rail-\(name)", root: vc.view, animationsOf: panel)
            panel.dismissPanel()
            try? await Task.sleep(for: .seconds(1))
        }
        setState("done")
    }

    /// Public glass variants laid over AVKit's backdrop, to fit AVKit's private
    /// `.avplayer` glass by pixel response. Each platter's frame is AVKit's
    /// subtitle menu frame shifted left by a multiple of 470pt.
    static func runGlassVariants() async {
        let vc = UIViewController()
        vc.modalPresentationStyle = .fullScreen
        let backdrop = UIImageView(image: UIImage(contentsOfFile: caches.appendingPathComponent("probe-backdrop.png").path))
        backdrop.frame = UIScreen.main.bounds
        vc.view.addSubview(backdrop)
        if ProcessInfo.processInfo.environment["RIVULET_SCRUBPROBE_BRIGHT"] == "1" {
            let white = UIView(frame: UIScreen.main.bounds)
            white.backgroundColor = .white
            let stripe = UIView(frame: CGRect(x: 1500, y: 0, width: 120, height: 1080))
            stripe.backgroundColor = .black
            white.addSubview(stripe)
            for offset in [470, 940, 1410] {
                let s2 = UIView(frame: CGRect(x: 1500 - offset, y: 0, width: 120, height: 1080))
                s2.backgroundColor = .black
                white.addSubview(s2)
            }
            vc.view.addSubview(white)
        }
        let variants: [(String, UIVisualEffect)] = [
            ("regular", UIGlassEffect(style: .regular)),
            ("clear", UIGlassEffect(style: .clear)),
            ("clear-w15", { let g = UIGlassEffect(style: .clear); g.tintColor = UIColor.white.withAlphaComponent(0.15); return g }()),
            ("regular-w30", { let g = UIGlassEffect(style: .regular); g.tintColor = UIColor.white.withAlphaComponent(0.3); return g }()),
        ]
        for (index, variant) in variants.enumerated() {
            let view = UIVisualEffectView(effect: variant.1)
            view.frame = CGRect(x: 1296 - CGFloat(index) * 470, y: 364, width: 450, height: 411)
            view.layer.cornerRadius = 54
            view.layer.cornerCurve = .continuous
            view.clipsToBounds = true
            vc.view.addSubview(view)
        }
        keep = [vc]
        await present(vc)
        try? await Task.sleep(for: .seconds(2))
        setState("glass-" + variants.map(\.0).joined(separator: "_"))
        try? await Task.sleep(for: .seconds(4))
        setState("done")
    }

    /// The collection view holding AVKit's round tool buttons.
    private static func toolRow(in view: UIView) -> UICollectionView? {
        if let cv = view as? UICollectionView,
           cv.subviews.contains(where: { NSStringFromClass(type(of: $0)).contains("ToolCell") }) { return cv }
        for sub in view.subviews { if let found = toolRow(in: sub) { return found } }
        return nil
    }

    /// PlayerProgressBarView at AVKit's bar frame (x 80...1840, track center y 910) and
    /// AVKit's capture times (a 10:00 stream paused at 00:17, scrubbed to 00:18).
    static func runRivulet() async {
        let vc = UIViewController()
        vc.modalPresentationStyle = .fullScreen
        vc.view.backgroundColor = .black
        let player = AVPlayer(url: streamURL)
        let videoLayer = AVPlayerLayer(player: player)
        videoLayer.frame = UIScreen.main.bounds
        vc.view.layer.addSublayer(videoLayer)
        let bar = PlayerProgressBarView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor, constant: 80),
            bar.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor, constant: -80),
            bar.topAnchor.constraint(equalTo: vc.view.topAnchor, constant: 900),
        ])
        keep = [vc, player]
        await present(vc)
        player.play()
        try? await Task.sleep(for: .seconds(12))

        let duration: TimeInterval = 600
        let now: TimeInterval = 17.3
        let thumb = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 225)).image { ctx in
            UIColor.black.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 225))
        }
        func show(playhead: TimeInterval, scrubbing: Bool, scrubTime: TimeInterval, wheel: Bool = false) {
            bar.update(currentTime: playhead, duration: duration, isScrubbing: scrubbing, scrubTime: scrubTime,
                       scrubThumbnail: scrubbing ? thumb : nil,
                       markers: [], chapters: [], isWheelScrubbing: wheel)
        }
        show(playhead: 14.2, scrubbing: false, scrubTime: 14.2)
        await capture("rivulet-playing", root: vc.view, animationsOf: bar)
        player.pause()
        show(playhead: now, scrubbing: false, scrubTime: now)
        bar.setPausedDim(true)
        await capture("rivulet-paused", root: vc.view, animationsOf: bar)
        show(playhead: now, scrubbing: true, scrubTime: 18)
        await capture("rivulet-scrub-near", root: vc.view, animationsOf: bar)
        show(playhead: now, scrubbing: true, scrubTime: 18.2)
        await capture("rivulet-scrub-far", root: vc.view, animationsOf: bar)
        show(playhead: now, scrubbing: true, scrubTime: 18.2, wheel: true)
        await capture("rivulet-ring", root: vc.view, animationsOf: bar)
        show(playhead: 18.2, scrubbing: false, scrubTime: 18.2)
        await capture("rivulet-scrub-ended", root: vc.view, animationsOf: bar)
        bar.setPausedDim(false)
        let start = Date(timeIntervalSinceReferenceDate: 812_000_000)
        bar.updateLiveTimeline(startTime: start, currentTime: start.addingTimeInterval(1500),
                               endTime: start.addingTimeInterval(3600), liveEdgeTime: start.addingTimeInterval(1800))
        await capture("rivulet-live", root: vc.view, animationsOf: bar)
        bar.setSkeleton(true)
        await capture("rivulet-skeleton", root: vc.view, animationsOf: bar)
        setState("done")
        print("[ScrubProbe] states done")
    }

    /// PlayerProgressBarView over AVKit's stripe backdrop in the states
    /// `barstates` drove AVKit through: focus dimmed, scans, skips.
    static func runRivuletBarStates() async {
        let vc = UIViewController()
        vc.modalPresentationStyle = .fullScreen
        for (index, white) in [1.0, 0.0, 0.5, 1.0, 0.0, 0.75, 0.25, 1.0].enumerated() {
            let stripe = UIView(frame: CGRect(x: CGFloat(index) * 240, y: 0, width: 240, height: 1080))
            stripe.backgroundColor = UIColor(white: white, alpha: 1)
            vc.view.addSubview(stripe)
        }
        let bar = PlayerProgressBarView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor, constant: 80),
            bar.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor, constant: -80),
            bar.topAnchor.constraint(equalTo: vc.view.topAnchor, constant: 900),
        ])
        keep = [vc]
        await present(vc)
        try? await Task.sleep(for: .seconds(1))
        func show(_ t: TimeInterval, scrubbing: Bool = false, level: Int = 0) {
            bar.update(currentTime: scrubbing ? 11.7 : t, duration: 600, isScrubbing: scrubbing, scrubTime: t,
                       scanLevel: level, scrubThumbnail: nil, markers: [], chapters: [])
        }
        func state(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(700))
            var lines = ["# \(name)"]
            walk(bar, window: vc.view.window!, depth: 0, into: &lines)
            try? lines.joined(separator: "\n").write(to: caches.appendingPathComponent("scrubstate-bs-\(name).txt"), atomically: true, encoding: .utf8)
            setState(name)
            try? await Task.sleep(for: .milliseconds(1200))
        }
        show(11.65)
        bar.setPausedDim(true)
        await state("riv-focused")
        bar.setFocusDimmed(true)
        await state("riv-unfocused")
        bar.setFocusDimmed(false)
        bar.setPausedDim(false)
        for (i, (t, level)) in [(18.48, 1), (44.67, 2), (107.9, 3)].enumerated() {
            show(t, scrubbing: true, level: level)
            await state("riv-scan\(i + 1)")
        }
        show(11.65, scrubbing: true, level: -1)
        await state("riv-rscan1")
        show(11.65, scrubbing: true, level: -2)
        await state("riv-rscan2")
        show(25)
        bar.showSkipIndicator(.forward(10))
        await state("riv-skip-fwd")
        show(16)
        bar.showSkipIndicator(.backward(10))
        await state("riv-skip-back")
        setState("done")
    }

    private static func present(_ vc: UIViewController) async {
        var root: UIViewController?
        for _ in 0..<40 where root == nil {
            root = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.windows.first(where: \.isKeyWindow)?.rootViewController }).first
            if root == nil { try? await Task.sleep(for: .milliseconds(250)) }
        }
        guard var top = root else { return print("[ScrubProbe] no root view controller") }
        while let presented = top.presentedViewController { top = presented }
        print("[ScrubProbe] presenting over \(type(of: top))")
        await withCheckedContinuation { done in top.present(vc, animated: false) { done.resume() } }
    }

    /// Samples animations right after the trigger, dumps the settled tree, then holds for a screenshot.
    private static func capture(_ name: String, root: UIView, animationsOf animated: UIView?) async {
        var lines: [String] = ["# \(name)", "## animations (sampled 30ms after trigger)"]
        try? await Task.sleep(for: .milliseconds(30))
        if let animated { lines += animationLines(in: animated.window ?? animated) }
        // Presentation-layer frames of every view mid-transition, for transitions the
        // animation objects alone don't describe (presenting animation controllers).
        if let window = (animated?.window ?? animated) as? UIWindow ?? animated?.window {
            for ms in [60, 120, 200, 300] {
                try? await Task.sleep(for: .milliseconds(ms == 60 ? 30 : (ms == 120 ? 60 : (ms == 200 ? 80 : 100))))
                lines.append("## presentation @\(ms)ms")
                lines += presentationLines(in: window)
            }
        }
        try? await Task.sleep(for: .seconds(2))
        lines.append("## tree (settled)")
        if let window = (root as? UIWindow) ?? root.window { walk(root, window: window, depth: 0, into: &lines) }
        try? lines.joined(separator: "\n").write(to: caches.appendingPathComponent("scrubstate-\(name).txt"), atomically: true, encoding: .utf8)
        setState(name)
        print("[ScrubProbe] state \(name)")
        try? await Task.sleep(for: hold)
    }

    private static func setState(_ name: String) {
        try? name.write(to: caches.appendingPathComponent("scrubprobe-state.txt"), atomically: true, encoding: .utf8)
    }

    private static func animationLines(in view: UIView) -> [String] {
        var out: [String] = []
        func visit(_ v: UIView) {
            for key in v.layer.animationKeys() ?? [] {
                guard let anim = v.layer.animation(forKey: key) else { continue }
                var desc = "\(type(of: v)) key=\(key) \(type(of: anim)) dur=\(anim.duration)"
                if let basic = anim as? CABasicAnimation {
                    desc += " path=\(basic.keyPath ?? "-") from=\(String(describing: basic.fromValue)) to=\(String(describing: basic.toValue))"
                    desc += " timing=\(basic.timingFunction.map { String(describing: $0) } ?? "-")"
                }
                if let spring = anim as? CASpringAnimation {
                    desc += " mass=\(spring.mass) stiffness=\(spring.stiffness) damping=\(spring.damping) v0=\(spring.initialVelocity) settle=\(spring.settlingDuration)"
                }
                out.append(desc)
            }
            v.subviews.forEach(visit)
        }
        visit(view)
        return out
    }

    /// Views whose on-screen (presentation) frame or opacity differs from their model.
    private static func presentationLines(in window: UIWindow) -> [String] {
        var out: [String] = []
        func visit(_ v: UIView) {
            if let p = v.layer.presentation() {
                let model = v.layer.convert(v.layer.bounds, to: window.layer)
                let shown = p.convert(p.bounds, to: window.layer.presentation() ?? window.layer)
                if abs(model.minX - shown.minX) > 0.5 || abs(model.minY - shown.minY) > 0.5
                    || abs(model.width - shown.width) > 0.5 || abs(p.opacity - v.layer.opacity) > 0.01 {
                    out.append("\(type(of: v)) model=\(fmt(model)) shown=\(fmt(shown)) opacity=\(fmt(CGFloat(p.opacity)))/\(fmt(CGFloat(v.layer.opacity))) r=\(fmt(p.cornerRadius))")
                }
            }
            v.subviews.forEach(visit)
        }
        visit(window)
        return out
    }

    private static func walk(_ view: UIView, window: UIWindow, depth: Int, into lines: inout [String]) {
        guard !view.isHidden, view.alpha > 0.01 else { return }
        let l = view.layer
        let frame = view.convert(view.bounds, to: window)
        var desc = String(repeating: "  ", count: depth) + "\(type(of: view)) win=\(fmt(frame)) a=\(fmt(view.alpha)) r=\(fmt(l.cornerRadius))"
        if l.borderWidth > 0 { desc += " bw=\(fmt(l.borderWidth)) border=\(color(l.borderColor))" }
        if let bg = view.backgroundColor { desc += " bg=\(color(bg.cgColor))" }
        if l.shadowOpacity > 0 { desc += " shadow=\(fmt(CGFloat(l.shadowOpacity)))/\(fmt(l.shadowRadius))/\(l.shadowOffset)/\(color(l.shadowColor))" }
        if let filter = l.compositingFilter { desc += " filter=\(filter)" }
        if let label = view as? UILabel {
            let font = label.font!
            let weight = (font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any])?[.weight] ?? "-"
            desc += " text=\"\(label.text ?? "")\" font=\(font.fontName) \(fmt(font.pointSize))pt w=\(weight) color=\(color(label.textColor.cgColor))"
        }
        if let effect = view as? UIVisualEffectView { desc += " effect=\(String(describing: effect.effect))" }
        if let filters = l.filters, !filters.isEmpty { desc += " filters=\(filters.map { String(describing: $0) })" }
        if NSStringFromClass(type(of: l)).contains("Backdrop") {
            let keys = ["groupName", "scale", "zoom"]
            desc += " backdrop{" + keys.compactMap { k in (l.value(forKey: k)).map { "\(k)=\($0)" } }.joined(separator: ",") + "}"
        }
        if view.isFocused { desc += " FOCUSED" }
        if let image = view as? UIImageView, let img = image.image { desc += " image=\(fmt(img.size.width))x\(fmt(img.size.height))" }
        lines.append(desc)
        view.subviews.forEach { walk($0, window: window, depth: depth + 1, into: &lines) }
    }

    private static func fmt(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }
    private static func fmt(_ r: CGRect) -> String { "(\(fmt(r.minX)),\(fmt(r.minY)) \(fmt(r.width))x\(fmt(r.height)))" }
    private static func color(_ c: CGColor?) -> String {
        guard let c, let comps = c.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)?.components else { return "nil" }
        return comps.map { String(format: "%.2f", Double($0)) }.joined(separator: "/")
    }
}

private extension NSObject {
    /// Calls a private no-argument selector if the object answers it.
    func call(_ name: String) {
        let sel = NSSelectorFromString(name)
        guard responds(to: sel) else { return print("[ScrubProbe] \(type(of: self)) has no \(name)") }
        perform(sel)
    }
}

private extension UIView {
    func scrubMoved(translation: Double) {
        typealias Fn = @convention(c) (AnyObject, Selector, Double, Double, Bool, CGPoint) -> Void
        let sel = NSSelectorFromString("scrubMovedWithTranslation:velocity:enableSnapping:gestureInfo:")
        guard responds(to: sel) else { return print("[ScrubProbe] no scrubMoved") }
        unsafeBitCast(method(for: sel), to: Fn.self)(self, sel, translation, 0, false, .zero)
    }

    func scrubEnded(translation: Double) {
        typealias Fn = @convention(c) (AnyObject, Selector, Double, Double) -> Void
        let sel = NSSelectorFromString("scrubEndedWithTranslation:velocity:")
        guard responds(to: sel) else { return print("[ScrubProbe] no scrubEnded") }
        unsafeBitCast(method(for: sel), to: Fn.self)(self, sel, translation, 0)
    }
}

/// Moves focus one step through the window's own focus event recognizer, as a
/// remote swipe does, so focus behaviour can be checked without a remote.
enum DebugFocusDriver {
    @discardableResult
    static func move(_ heading: UIFocusHeading, in window: UIWindow) -> Bool {
        let getter = NSSelectorFromString("_focusEventRecognizer")
        guard window.responds(to: getter),
              let recognizer = window.perform(getter)?.takeUnretainedValue() as? NSObject else { return false }
        let sel = NSSelectorFromString("_moveInDirection:groupFilter:")
        guard recognizer.responds(to: sel) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, UInt, Int) -> Bool
        let moved = unsafeBitCast(recognizer.method(for: sel), to: Fn.self)(recognizer, sel, heading.rawValue, 0)
        UIFocusSystem.focusSystem(for: window)?.updateFocusIfNeeded()
        return moved
    }

    /// The focused view's class and window frame, for logs.
    static func describeFocus(in window: UIWindow) -> String {
        guard let view = UIFocusSystem.focusSystem(for: window)?.focusedItem as? UIView else { return "none" }
        let f = view.convert(view.bounds, to: window)
        return "\(type(of: view)) (\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)))"
    }

    /// Why each would-be focus target on screen can or can't take focus.
    static func logFocusability(in window: UIWindow) {
        func visit(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0.01 else { return }
            if view.canBecomeFocused, !view.isFocused {
                let f = view.convert(view.bounds, to: window)
                print("[Moves]   \(type(of: view)) (\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))): \(UIFocusDebugger.checkFocusability(for: view))")
            }
            view.subviews.forEach(visit)
        }
        visit(window)
    }

    /// RIVULET_AUTOPLAY_MOVES=down,up,...: one move per step, logged and signalled
    /// through scrubprobe-state.txt (move-N) so a host script can screenshot each.
    static func run(_ spec: String, in window: UIWindow) async {
        let headings: [String: UIFocusHeading] = ["up": .up, "down": .down, "left": .left, "right": .right]
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        func state(_ s: String) { try? s.write(to: caches.appendingPathComponent("scrubprobe-state.txt"), atomically: true, encoding: .utf8) }
        print("[Moves] start focus=\(describeFocus(in: window))")
        state("move-0")
        try? await Task.sleep(for: .seconds(2))
        for (index, word) in spec.split(separator: ",").enumerated() {
            if ["hide", "cup", "cdown"].contains(word) {
                let player = PlayerContainerViewController.debugCurrent
                if word == "hide" { player?.debugHideChrome() } else { player?.debugContentVertical(up: word == "cup") }
                try? await Task.sleep(for: .milliseconds(1500))
                print("[Moves] \(index + 1) \(word) focus=\(describeFocus(in: window))")
                state("move-\(index + 1)")
                try? await Task.sleep(for: .seconds(1.2))
                continue
            }
            if word == "menu" {
                PlayerContainerViewController.debugCurrent?.debugMenu()
                try? await Task.sleep(for: .milliseconds(800))
                print("[Moves] \(index + 1) menu focus=\(describeFocus(in: window))")
                state("move-\(index + 1)")
                try? await Task.sleep(for: .seconds(1.2))
                continue
            }
            if word == "select" {
                // Select on the cards and summaries that take it.
                let focused = UIFocusSystem.focusSystem(for: window)?.focusedItem
                (focused as? InsightsCastCardView)?.onPress?()
                (focused as? PlayerSummaryButton)?.onPress?()
                (focused as? TransportControlButton)?.onPress?()
                try? await Task.sleep(for: .milliseconds(800))
                print("[Moves] \(index + 1) select focus=\(describeFocus(in: window))")
                state("move-\(index + 1)")
                try? await Task.sleep(for: .seconds(1.2))
                continue
            }
            guard let heading = headings[String(word)] else { continue }
            let moved = move(heading, in: window)
            try? await Task.sleep(for: .milliseconds(500))
            print("[Moves] \(index + 1) \(word) moved=\(moved) focus=\(describeFocus(in: window))")
            if !moved { logFocusability(in: window) }
            state("move-\(index + 1)")
            try? await Task.sleep(for: .seconds(1.2))
        }
        state("done")
    }
}

private extension UIView {
    func firstDescendant(named name: String) -> UIView? {
        if NSStringFromClass(type(of: self)) == name { return self }
        for sub in subviews { if let found = sub.firstDescendant(named: name) { return found } }
        return nil
    }
}

private extension UIViewController {
    func descendantsOfClass(_ name: String) -> [NSObject] {
        guard let cls = NSClassFromString(name) else { return [] }
        func all(_ vc: UIViewController) -> [UIViewController] { vc.children.flatMap { [$0] + all($0) } }
        return all(self).filter { $0.isKind(of: cls) }
    }
}
#endif
