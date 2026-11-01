// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

#if DEBUG
import AVKit
import MediaAccessibility
import UIKit

/// DEBUG-only: draws one caption cue through AVKit or through `CaptionOverlayView`, resting
/// then with the chrome up, for screenshot comparison. State lands in Library/Caches/captionprobe-state.txt.
/// - RIVULET_SCRUBPROBE=captions: AVPlayerViewController on RIVULET_CAPTIONPROBE_URL (black HLS + WebVTT).
/// - RIVULET_SCRUBPROBE=rivulet-captions: CaptionOverlayView over black, picture RIVULET_CAPTIONPROBE_VIDEO ("1920x800").
/// - RIVULET_CAPTIONPROBE_PROFILE: caption profile id to activate first.
@MainActor
enum CaptionLayoutProbe {
    private static var keep: [AnyObject] = []
    static let cueText = "Eg(0 hold yp\nEg(0 hold yp"

    static func runAVKit(env: [String: String]) async {
        activateProfile(env)
        guard let url = env["RIVULET_CAPTIONPROBE_URL"].flatMap(URL.init(string:)) else { return }
        let item = AVPlayerItem(url: url)
        // RIVULET_CAPTIONPROBE_TITLE=1: a title block, which raises AVKit's caption lift.
        if env["RIVULET_CAPTIONPROBE_TITLE"] == "1" {
            item.externalMetadata = [(AVMetadataIdentifier.commonIdentifierTitle, "Caption Probe"),
                                     (.iTunesMetadataTrackSubTitle, "S1, E1")].map { id, value in
                let m = AVMutableMetadataItem()
                m.identifier = id
                m.value = value as NSString
                m.extendedLanguageTag = "und"
                return m
            }
        }
        let player = AVPlayer(playerItem: item)
        player.appliesMediaSelectionCriteriaAutomatically = false
        let vc = AVPlayerViewController()
        vc.player = player
        keep = [vc]
        await present(vc)
        for _ in 0..<100 where item.status != .readyToPlay { try? await Task.sleep(for: .milliseconds(100)) }
        if let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
           let option = group.options.first(where: { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }) {
            item.select(option, in: group)
        }
        player.play()
        try? await Task.sleep(for: .seconds(6))
        setState("rest")
        try? await Task.sleep(for: .seconds(4))
        vc.perform(NSSelectorFromString("_showPlaybackControlsViewIfNeededForUserInteraction"))
        try? await Task.sleep(for: .seconds(1.5))
        setState("chrome")
        try? await Task.sleep(for: .seconds(4))
        setState("done")
    }

    static func runRivulet(env: [String: String]) async {
        activateProfile(env)
        let dims = (env["RIVULET_CAPTIONPROBE_VIDEO"] ?? "1920x1080").split(separator: "x").compactMap { Double($0) }
        let vc = UIViewController()
        vc.view.backgroundColor = .black
        vc.modalPresentationStyle = .fullScreen
        let model = SubtitleModel()
        let overlay = CaptionOverlayView(model: model, style: CaptionAppearance.current(),
                                         videoSize: dims.count == 2 ? CGSize(width: dims[0], height: dims[1]) : .zero)
        overlay.frame = vc.view.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        vc.view.addSubview(overlay)
        keep = [vc, model]
        await present(vc)
        model.update(cues: [AetherSubtitleCue(id: 1, startTime: 0, endTime: 1000, body: .text(cueText))])
        model.sourceTime = 1
        try? await Task.sleep(for: .seconds(2))
        setState("rest")
        try? await Task.sleep(for: .seconds(4))
        overlay.controlsVisible = true
        overlay.layoutIfNeeded()
        try? await Task.sleep(for: .seconds(1.5))
        setState("chrome")
        try? await Task.sleep(for: .seconds(4))
        setState("done")
    }

    private static func activateProfile(_ env: [String: String]) {
        if let profile = env["RIVULET_CAPTIONPROBE_PROFILE"] {
            MACaptionAppearanceSetActiveProfileID(profile as CFString)
        }
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
        try? name.write(to: caches.appendingPathComponent("captionprobe-state.txt"), atomically: true, encoding: .utf8)
    }
}
#endif
