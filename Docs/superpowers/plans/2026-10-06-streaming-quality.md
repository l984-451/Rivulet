# Streaming Quality Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Home/Away streaming quality (Original, Auto, fixed steps) with an in-player Quality menu, shared in RivuletCore and wired into the tvOS player (Plex and Jellyfin) and the iOS/iPadOS player.

**Architecture:** Pure, dependency-free decision types in `RivuletCore/Streaming/` (ladder, setting, location classifier, path monitor, throughput probe, decision, stall tracker, version ranking core). Each app calls them at play time and builds either the direct-play URL (Original, the aether route) or the shared Plex transcode URL (`buildHLSDirectPlayURL` with a step). Step changes reload at the current position.

**Tech Stack:** Swift 6 (default MainActor isolation, so shared value types are `nonisolated`), SwiftUI (iOS), UIKit (tvOS), Network.framework (`NWPathMonitor`), URLSession, XCTest.

**Spec:** `Docs/superpowers/specs/2026-10-06-streaming-quality-design.md`


## Global Constraints

- No `#if os(...)` anywhere under `RivuletCore/` (lint rule `platform_conditional_in_shared_code`).
- Only `Rivulet/Services/Plex/Playback/AetherPlayer.swift` (tvOS) and `RivuletiOS/Player/AetherPlayer.swift` (iOS) may `import AetherEngine`.
- Never send stream URLs or tokens to Sentry or logs that ship; tag a category instead.
- No em dashes or en dashes in code, comments, copy or docs.
- Comments: one or two short lines; say what or why, never history.
- Setting keys: `homeStreamingQuality`, `awayStreamingQuality`. Raw values: `original`, `auto`, or the step kbps as a string (`"8000"`). Defaults: home `original`, away `auto`.
- Ladder (kbps, videoResolution): 20000 1920x1080, 12000 1920x1080, 8000 1920x1080, 4000 1280x720, 2000 1280x720, 1500 720x480, 720 576x320. Relay step = 1500 720x480.
- Auto headroom 0.75. Probe: at most 4 MB or 2 s after the first byte. Probe failure step: 4000. Stalls: 2 within 60 s, or one lasting 10 s, step down; 5 s grace after a seek or load.
- Relay output of `buildHLSDirectPlayURL` must stay byte-identical (existing tests in `RivuletTests/Unit/Services/PlexNetworkManagerURLTests.swift` pass unchanged).
- Existing `VersionRankingTests`, `PlayerVersionSelectionTests`, `ProviderPlaybackVersionTests` pass unchanged.
- Agents never commit. The coordinator makes one commit at the end.
- Builds: `xcodebuild -scheme Rivulet` on a tvOS Simulator and `-scheme "Rivulet iOS"` on `generic/platform=iOS Simulator`. Tests: `xcodebuild test -scheme Rivulet`; success is `** TEST SUCCEEDED **` and zero `✘`.

## Review Focus

1. A Plex server reached by a LAN plex.direct name (`192-168-1-140.<hash>.plex.direct:32400`) must classify Home; one on port 8443 is relay; a public IP is Away. (Task 2 tests.)
2. A user seek, scrub, or the load itself must never count as a stall, or Auto drops quality after two seeks. (Task 3 tests; Tasks 6 and 9 stamp seeks and loads.)
3. A quality reload must stop the outgoing Plex transcode session and keep position, rate and paused state; on iOS it must not reset PiP or Now Playing. (Tasks 6 and 9.)
4. Multi-version titles under a cap must not drop to an SD version when a step would give 720p or 1080p. (Task 4 tests.)
5. Changing audio or subtitles while on a transcode must change the heard/shown track, not only the label. (Tasks 6 and 9.)

---

### Task 1: Quality model (RivuletCore)

**Files:**
- Create: `RivuletCore/Streaming/StreamingQuality.swift`
- Test: `RivuletTests/Unit/Streaming/StreamingQualityTests.swift`

**Interfaces:**
- Produces: `QualityStep { kbps: Int; videoResolution: String; height: Int; tier: Int; label: String; static ladder: [QualityStep]; static relay: QualityStep; static func step(kbps:) -> QualityStep? }`; `StreamingQuality { .original, .auto, .step(QualityStep) }: RawRepresentable<String>` with `homeKey`, `awayKey`, `homeDefault`, `awayDefault`, `allChoices`, `label`, `static func setting(home: Bool, defaults: UserDefaults = .standard) -> StreamingQuality`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Rivulet

final class StreamingQualityTests: XCTestCase {
    func test_rawValues_roundTrip() {
        for choice in StreamingQuality.allChoices {
            XCTAssertEqual(StreamingQuality(rawValue: choice.rawValue), choice)
        }
        XCTAssertEqual(StreamingQuality.original.rawValue, "original")
        XCTAssertEqual(StreamingQuality.auto.rawValue, "auto")
        XCTAssertEqual(StreamingQuality.step(QualityStep.step(kbps: 8000)!).rawValue, "8000")
        XCTAssertNil(StreamingQuality(rawValue: "9999"))
        XCTAssertNil(StreamingQuality(rawValue: ""))
    }

    func test_labels() {
        XCTAssertEqual(QualityStep.step(kbps: 20000)?.label, "20 Mbps 1080p")
        XCTAssertEqual(QualityStep.step(kbps: 1500)?.label, "1.5 Mbps 480p")
        XCTAssertEqual(QualityStep.step(kbps: 720)?.label, "720 kbps")
        XCTAssertEqual(StreamingQuality.auto.label, "Auto")
        XCTAssertEqual(StreamingQuality.original.label, "Original")
    }

    func test_ladder_isDescendingAndRelayIsOnIt() {
        let kbps = QualityStep.ladder.map(\.kbps)
        XCTAssertEqual(kbps, [20000, 12000, 8000, 4000, 2000, 1500, 720])
        XCTAssertEqual(QualityStep.relay, QualityStep.step(kbps: 1500))
        XCTAssertEqual(QualityStep.step(kbps: 4000)?.tier, 720)
        XCTAssertEqual(QualityStep.step(kbps: 8000)?.tier, 1080)
    }

    func test_setting_defaultsAndStoredValues() {
        let defaults = UserDefaults(suiteName: "StreamingQualityTests")!
        defaults.removePersistentDomain(forName: "StreamingQualityTests")
        XCTAssertEqual(StreamingQuality.setting(home: true, defaults: defaults), .original)
        XCTAssertEqual(StreamingQuality.setting(home: false, defaults: defaults), .auto)
        defaults.set("4000", forKey: StreamingQuality.awayKey)
        XCTAssertEqual(StreamingQuality.setting(home: false, defaults: defaults), .step(QualityStep.step(kbps: 4000)!))
        defaults.set("garbage", forKey: StreamingQuality.homeKey)
        XCTAssertEqual(StreamingQuality.setting(home: true, defaults: defaults), .original)
    }
}
```

- [ ] **Step 2: Run, expect a compile failure** (`cannot find 'StreamingQuality' in scope`).

- [ ] **Step 3: Implement**

```swift
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// One rung of the transcode ladder; matches the steps PMS advertises.
nonisolated struct QualityStep: Hashable, Sendable {
    let kbps: Int
    /// Plex `videoResolution` query value.
    let videoResolution: String

    var height: Int { Int(videoResolution.split(separator: "x").last ?? "") ?? 0 }
    /// The `VersionRanking` tier a transcode at this step produces.
    var tier: Int { VersionRanking.tier(label: nil, height: height) }

    var label: String {
        guard kbps >= 1000 else { return "\(kbps) kbps" }
        let mbps = Double(kbps) / 1000
        let rate = mbps == mbps.rounded() ? "\(Int(mbps)) Mbps" : "\(mbps) Mbps"
        return kbps >= 1500 ? "\(rate) \(height)p" : rate
    }

    static let ladder: [QualityStep] = [
        QualityStep(kbps: 20000, videoResolution: "1920x1080"),
        QualityStep(kbps: 12000, videoResolution: "1920x1080"),
        QualityStep(kbps: 8000, videoResolution: "1920x1080"),
        QualityStep(kbps: 4000, videoResolution: "1280x720"),
        QualityStep(kbps: 2000, videoResolution: "1280x720"),
        QualityStep(kbps: 1500, videoResolution: "720x480"),
        QualityStep(kbps: 720, videoResolution: "576x320"),
    ]

    /// What a Plex Relay connection can sustain.
    static let relay = QualityStep(kbps: 1500, videoResolution: "720x480")

    static func step(kbps: Int) -> QualityStep? { ladder.first { $0.kbps == kbps } }
}

/// A Home or Away streaming quality setting, or a per-title choice in the player.
nonisolated enum StreamingQuality: Hashable, Sendable {
    case original
    case auto
    case step(QualityStep)

    static let homeKey = "homeStreamingQuality"
    static let awayKey = "awayStreamingQuality"
    static let homeDefault: StreamingQuality = .original
    static let awayDefault: StreamingQuality = .auto

    /// Every choice a picker offers, in display order.
    static let allChoices: [StreamingQuality] = [.original, .auto] + QualityStep.ladder.map { .step($0) }

    var label: String {
        switch self {
        case .original: "Original"
        case .auto: "Auto"
        case .step(let step): step.label
        }
    }

    /// The stored setting; a missing or unknown value falls back to the default.
    static func setting(home: Bool, defaults: UserDefaults = .standard) -> StreamingQuality {
        defaults.string(forKey: home ? homeKey : awayKey).flatMap(StreamingQuality.init(rawValue:))
            ?? (home ? homeDefault : awayDefault)
    }
}

extension StreamingQuality: RawRepresentable {
    init?(rawValue: String) {
        switch rawValue {
        case "original": self = .original
        case "auto": self = .auto
        default:
            guard let kbps = Int(rawValue), let step = QualityStep.step(kbps: kbps) else { return nil }
            self = .step(step)
        }
    }

    var rawValue: String {
        switch self {
        case .original: "original"
        case .auto: "auto"
        case .step(let step): "\(step.kbps)"
        }
    }
}
```

`VersionRanking.tier` must be reachable from RivuletCore: Task 4 moves it there. If Task 1 lands first, compile Task 1 and Task 4 together.

- [ ] **Step 4: Run the tests, expect PASS.**

### Task 2: Home or Away (RivuletCore)

**Files:**
- Create: `RivuletCore/Streaming/ServerLocation.swift`, `RivuletCore/Streaming/NetworkPathMonitor.swift`
- Modify: `RivuletCore/Plex/PlexNetworkManager.swift` (delete the dead private `isLocalServer`, about line 1919; confirm zero callers first)
- Test: `RivuletTests/Unit/Streaming/ServerLocationTests.swift`

**Interfaces:**
- Produces: `ServerLocation.classify(_ url: URL) -> ServerLocation` and `classify(_ serverURL: String)`; cases `.local`, `.remote`, `.relay`; `ServerLocation.plexDirectAddress(_ host: String) -> String?`; `ServerLocation.isPrivateAddress(_ host: String) -> Bool`; `NetworkPathMonitor.shared.isAwayPath: Bool`; `StreamingQuality.isHome(serverURL: String) -> Bool`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Rivulet

final class ServerLocationTests: XCTestCase {
    private func loc(_ s: String) -> ServerLocation { ServerLocation.classify(s) }

    func test_privateIPv4Literals_areLocal() {
        XCTAssertEqual(loc("http://192.168.1.140:32400"), .local)
        XCTAssertEqual(loc("http://10.0.0.5:32400"), .local)
        XCTAssertEqual(loc("http://172.16.0.1:32400"), .local)
        XCTAssertEqual(loc("http://172.31.255.1:32400"), .local)
        XCTAssertEqual(loc("http://100.64.1.2:32400"), .local)    // CGNAT / Tailscale
        XCTAssertEqual(loc("http://169.254.3.4:32400"), .local)
        XCTAssertEqual(loc("http://127.0.0.1:32400"), .local)
    }

    func test_publicAndEdgeIPv4_areRemote() {
        XCTAssertEqual(loc("http://172.15.0.1:32400"), .remote)
        XCTAssertEqual(loc("http://172.32.0.1:32400"), .remote)
        XCTAssertEqual(loc("http://172.200.1.1:32400"), .remote)
        XCTAssertEqual(loc("http://100.128.0.1:32400"), .remote)
        XCTAssertEqual(loc("https://73.12.44.5:32400"), .remote)
        XCTAssertEqual(loc("https://plex.example.com"), .remote)
    }

    func test_plexDirect_decodesEmbeddedAddress() {
        XCTAssertEqual(loc("https://192-168-1-140.abcdef0123456789.plex.direct:32400"), .local)
        XCTAssertEqual(loc("https://73-12-44-5.abcdef0123456789.plex.direct:32400"), .remote)
        XCTAssertEqual(loc("https://73-12-44-5.abcdef0123456789.plex.direct:8443"), .relay)
        XCTAssertEqual(ServerLocation.plexDirectAddress("fd00--1.abc.plex.direct"), "fd00::1")
    }

    func test_ipv6AndNames() {
        XCTAssertEqual(loc("http://[fd12:3456::1]:32400"), .local)
        XCTAssertEqual(loc("http://[fe80::1]:32400"), .local)
        XCTAssertEqual(loc("http://[::1]:32400"), .local)
        XCTAssertEqual(loc("http://[2001:db8::1]:32400"), .remote)
        XCTAssertEqual(loc("http://nas.local:32400"), .local)
        XCTAssertEqual(loc("http://localhost:32400"), .local)
        XCTAssertEqual(loc("not a url"), .remote)
    }
}
```

- [ ] **Step 2: Run, expect compile failure.**

- [ ] **Step 3: Implement**

`RivuletCore/Streaming/ServerLocation.swift`:

```swift
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import Network

/// Where a playback server sits relative to this device, judged from its URL alone.
nonisolated enum ServerLocation: Equatable, Sendable {
    case local
    case remote
    case relay

    static func classify(_ url: URL) -> ServerLocation {
        if PlexRelay.isRelayURL(url) { return .relay }
        guard let host = url.host?.lowercased() else { return .remote }
        if host == "localhost" || host.hasSuffix(".local") { return .local }
        return isPrivateAddress(plexDirectAddress(host) ?? host) ? .local : .remote
    }

    static func classify(_ serverURL: String) -> ServerLocation {
        URL(string: serverURL).map(classify) ?? .remote
    }

    /// `192-168-1-140.<hash>.plex.direct` embeds the server's address with dashes.
    static func plexDirectAddress(_ host: String) -> String? {
        guard host.hasSuffix(".plex.direct"), let label = host.split(separator: ".").first else { return nil }
        let v4 = label.replacingOccurrences(of: "-", with: ".")
        if IPv4Address(v4) != nil { return v4 }
        let v6 = label.replacingOccurrences(of: "-", with: ":")
        return IPv6Address(v6) != nil ? v6 : nil
    }

    /// RFC 1918, CGNAT, link-local, loopback, and IPv6 ULA / link-local / loopback.
    static func isPrivateAddress(_ host: String) -> Bool {
        let literal = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let v4 = IPv4Address(literal) {
            let b = [UInt8](v4.rawValue)
            switch (b[0], b[1]) {
            case (10, _), (127, _), (192, 168), (169, 254), (172, 16...31), (100, 64...127): return true
            default: return false
            }
        }
        if let v6 = IPv6Address(literal) {
            let b = [UInt8](v6.rawValue)
            return v6 == .loopback || (b[0] & 0xFE) == 0xFC || (b[0] == 0xFE && (b[1] & 0xC0) == 0x80)
        }
        return false
    }
}
```

`RivuletCore/Streaming/NetworkPathMonitor.swift`:

```swift
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import Network

/// The device's network path. Cellular, a personal hotspot and Low Data Mode count as Away.
nonisolated final class NetworkPathMonitor: Sendable {
    static let shared = NetworkPathMonitor()
    private let monitor = NWPathMonitor()

    private init() {
        monitor.start(queue: DispatchQueue(label: "rivulet.network-path"))
    }

    var isAwayPath: Bool {
        let path = monitor.currentPath
        return path.usesInterfaceType(.cellular) || path.isExpensive || path.isConstrained
    }
}

extension StreamingQuality {
    /// Home: a local server address on a path that is not cellular, expensive or constrained.
    static func isHome(serverURL: String) -> Bool {
        ServerLocation.classify(serverURL) == .local && !NetworkPathMonitor.shared.isAwayPath
    }
}
```

If `NWPathMonitor` is not `Sendable` in this SDK, mark the class `@unchecked Sendable` with a one-line comment (NWPathMonitor is thread-safe).

- [ ] **Step 4: Delete `PlexNetworkManager.isLocalServer`** after `grep -rn "isLocalServer" Rivulet RivuletCore RivuletiOS RivuletTests` shows only its definition.
- [ ] **Step 5: Run the tests, expect PASS.**

### Task 3: Decision, stall tracker, throughput probe (RivuletCore)

**Files:**
- Create: `RivuletCore/Streaming/QualityDecision.swift`, `RivuletCore/Streaming/StallTracker.swift`, `RivuletCore/Streaming/ThroughputProbe.swift`
- Test: `RivuletTests/Unit/Streaming/QualityDecisionTests.swift`, `RivuletTests/Unit/Streaming/StallTrackerTests.swift`

**Interfaces:**
- Consumes: Task 1 types.
- Produces: `StreamPlan { .original, .transcode(QualityStep); var step: QualityStep? }`; `QualityDecision.decide(setting:sourceKbps:measuredKbps:isRelay:) -> StreamPlan`; `QualityDecision.capKbps(setting:measuredKbps:isRelay:) -> Int?`; `QualityDecision.highestStep(atMost:) -> QualityStep`; `QualityDecision.stepDown(from:sourceKbps:) -> QualityStep?`; `QualityDecision.needsProbe(setting:isRelay:) -> Bool`; `StallTracker` with `noteSeekOrLoad(at:)`, `bufferingStarted(at:) -> StallVerdict`, `isLongStall(startedAt:now:)`; `StallVerdict { .ignored, .counted, .stepDown }`; `ThroughputProbe.measure(url:headers:session:) async -> Int?`, `ThroughputProbe.kbps(bytes:seconds:) -> Int?`; `PlexMedia.sourceKbps: Int?`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Rivulet

final class QualityDecisionTests: XCTestCase {
    private let s8 = QualityStep.step(kbps: 8000)!
    private let s4 = QualityStep.step(kbps: 4000)!

    func test_original_playsOriginal_unlessRelay() {
        XCTAssertEqual(QualityDecision.decide(setting: .original, sourceKbps: 60000, measuredKbps: nil, isRelay: false), .original)
        XCTAssertEqual(QualityDecision.decide(setting: .original, sourceKbps: 60000, measuredKbps: nil, isRelay: true), .transcode(.relay))
    }

    func test_fixedStep_playsOriginalWhenSourceAlreadyFits() {
        XCTAssertEqual(QualityDecision.decide(setting: .step(s8), sourceKbps: 6000, measuredKbps: nil, isRelay: false), .original)
        XCTAssertEqual(QualityDecision.decide(setting: .step(s8), sourceKbps: 9000, measuredKbps: nil, isRelay: false), .transcode(s8))
        XCTAssertEqual(QualityDecision.decide(setting: .step(s8), sourceKbps: nil, measuredKbps: nil, isRelay: false), .transcode(s8))
    }

    func test_fixedStep_onRelay_isClamped() {
        let s720 = QualityStep.step(kbps: 720)!
        XCTAssertEqual(QualityDecision.decide(setting: .step(s8), sourceKbps: 9000, measuredKbps: nil, isRelay: true), .transcode(.relay))
        XCTAssertEqual(QualityDecision.decide(setting: .step(s720), sourceKbps: 9000, measuredKbps: nil, isRelay: true), .transcode(s720))
    }

    func test_auto() {
        // 75% of 20 Mbps = 15 Mbps budget.
        XCTAssertEqual(QualityDecision.decide(setting: .auto, sourceKbps: 14000, measuredKbps: 20000, isRelay: false), .original)
        XCTAssertEqual(QualityDecision.decide(setting: .auto, sourceKbps: 40000, measuredKbps: 20000, isRelay: false), .transcode(QualityStep.step(kbps: 12000)!))
        // Budget below the lowest step still transcodes at the lowest step.
        XCTAssertEqual(QualityDecision.decide(setting: .auto, sourceKbps: 40000, measuredKbps: 300, isRelay: false), .transcode(QualityStep.ladder.last!))
        // Unknown source plays the original; a failed probe uses 4 Mbps when the source is above it.
        XCTAssertEqual(QualityDecision.decide(setting: .auto, sourceKbps: nil, measuredKbps: 1000, isRelay: false), .original)
        XCTAssertEqual(QualityDecision.decide(setting: .auto, sourceKbps: 9000, measuredKbps: nil, isRelay: false), .transcode(s4))
        XCTAssertEqual(QualityDecision.decide(setting: .auto, sourceKbps: 3000, measuredKbps: nil, isRelay: false), .original)
    }

    func test_capAndProbeNeed() {
        XCTAssertNil(QualityDecision.capKbps(setting: .original, measuredKbps: nil, isRelay: false))
        XCTAssertEqual(QualityDecision.capKbps(setting: .original, measuredKbps: nil, isRelay: true), 1500)
        XCTAssertEqual(QualityDecision.capKbps(setting: .step(s8), measuredKbps: nil, isRelay: false), 8000)
        XCTAssertEqual(QualityDecision.capKbps(setting: .auto, measuredKbps: 20000, isRelay: false), 15000)
        XCTAssertEqual(QualityDecision.capKbps(setting: .auto, measuredKbps: nil, isRelay: false), 4000)
        XCTAssertTrue(QualityDecision.needsProbe(setting: .auto, isRelay: false))
        XCTAssertFalse(QualityDecision.needsProbe(setting: .auto, isRelay: true))
        XCTAssertFalse(QualityDecision.needsProbe(setting: .original, isRelay: false))
    }

    func test_stepDown() {
        XCTAssertEqual(QualityDecision.stepDown(from: .original, sourceKbps: 15000), QualityStep.step(kbps: 12000))
        XCTAssertEqual(QualityDecision.stepDown(from: .original, sourceKbps: nil), QualityStep.step(kbps: 20000))
        XCTAssertEqual(QualityDecision.stepDown(from: .transcode(s8), sourceKbps: 40000), s4)
        XCTAssertNil(QualityDecision.stepDown(from: .transcode(QualityStep.ladder.last!), sourceKbps: 40000))
    }

    func test_probeRateMath() {
        XCTAssertEqual(ThroughputProbe.kbps(bytes: 2_500_000, seconds: 1), 20000)
        XCTAssertNil(ThroughputProbe.kbps(bytes: 1000, seconds: 1))     // too little to judge
        XCTAssertNil(ThroughputProbe.kbps(bytes: 2_500_000, seconds: 0))
    }

    func test_sourceKbps_fallsBackToSizeOverDuration() {
        let json = #"{"id":1,"duration":7200000,"bitrate":null,"Part":[{"id":2,"key":"/k","duration":7200000,"size":9000000000}]}"#
        let media = try! JSONDecoder().decode(PlexMedia.self, from: Data(json.utf8))
        XCTAssertEqual(media.sourceKbps, 10000)   // 9 GB over 2 h = 10 Mbps
    }
}

final class StallTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func test_secondStallWithinWindow_stepsDown() {
        var tracker = StallTracker()
        XCTAssertEqual(tracker.bufferingStarted(at: t0), .counted)
        XCTAssertEqual(tracker.bufferingStarted(at: t0 + 30), .stepDown)
        XCTAssertEqual(tracker.bufferingStarted(at: t0 + 40), .counted)   // reset after a step
    }

    func test_stallsOutsideWindow_doNotStepDown() {
        var tracker = StallTracker()
        _ = tracker.bufferingStarted(at: t0)
        XCTAssertEqual(tracker.bufferingStarted(at: t0 + 61), .counted)
    }

    func test_seekAndLoadGrace_ignored() {
        var tracker = StallTracker()
        tracker.noteSeekOrLoad(at: t0)
        XCTAssertEqual(tracker.bufferingStarted(at: t0 + 1), .ignored)
        XCTAssertEqual(tracker.bufferingStarted(at: t0 + 4.9), .ignored)
        XCTAssertEqual(tracker.bufferingStarted(at: t0 + 6), .counted)
        tracker.noteSeekOrLoad(at: t0 + 10)
        XCTAssertEqual(tracker.bufferingStarted(at: t0 + 11), .ignored)   // two seeks never step down
    }

    func test_longStall() {
        let tracker = StallTracker()
        XCTAssertFalse(tracker.isLongStall(startedAt: t0, now: t0 + 9))
        XCTAssertTrue(tracker.isLongStall(startedAt: t0, now: t0 + 10))
    }
}
```

- [ ] **Step 2: Run, expect compile failure.**

- [ ] **Step 3: Implement**

`QualityDecision.swift`:

```swift
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// What a title plays as: the untouched file, or a server transcode at a step.
nonisolated enum StreamPlan: Equatable, Sendable {
    case original
    case transcode(QualityStep)

    var step: QualityStep? {
        if case .transcode(let step) = self { step } else { nil }
    }
}

/// Original vs transcode for one title. Pure; callers supply the measurements.
nonisolated enum QualityDecision {
    /// Auto plays a file whose bitrate fits in this share of the measured throughput.
    static let headroom = 0.75
    /// Auto's step when the throughput probe fails.
    static let probeFailureStep = QualityStep(kbps: 4000, videoResolution: "1280x720")

    static func needsProbe(setting: StreamingQuality, isRelay: Bool) -> Bool {
        setting == .auto && !isRelay
    }

    /// The bitrate ceiling a version should fit under, or nil for no ceiling.
    static func capKbps(setting: StreamingQuality, measuredKbps: Int?, isRelay: Bool) -> Int? {
        let cap: Int? = switch setting {
        case .original: nil
        case .step(let step): step.kbps
        case .auto: measuredKbps.map { Int(Double($0) * headroom) } ?? probeFailureStep.kbps
        }
        guard isRelay else { return cap }
        return min(cap ?? QualityStep.relay.kbps, QualityStep.relay.kbps)
    }

    static func decide(setting: StreamingQuality, sourceKbps: Int?, measuredKbps: Int?, isRelay: Bool) -> StreamPlan {
        let plan: StreamPlan = switch setting {
        case .original: .original
        case .step(let step): sourceKbps.map { $0 <= step.kbps } == true ? .original : .transcode(step)
        case .auto: autoPlan(sourceKbps: sourceKbps, measuredKbps: measuredKbps)
        }
        guard isRelay else { return plan }
        if let step = plan.step, step.kbps <= QualityStep.relay.kbps { return plan }
        return .transcode(.relay)
    }

    /// The best step at or under `kbps`; the lowest step when none is.
    static func highestStep(atMost kbps: Int) -> QualityStep {
        QualityStep.ladder.first { $0.kbps <= kbps } ?? QualityStep.ladder[QualityStep.ladder.count - 1]
    }

    /// One step below what is playing, or nil at the bottom.
    static func stepDown(from plan: StreamPlan, sourceKbps: Int?) -> QualityStep? {
        let ceiling = plan.step?.kbps ?? sourceKbps ?? Int.max
        return QualityStep.ladder.first { $0.kbps < ceiling }
    }

    private static func autoPlan(sourceKbps: Int?, measuredKbps: Int?) -> StreamPlan {
        guard let sourceKbps else { return .original }
        guard let measuredKbps else {
            return sourceKbps <= probeFailureStep.kbps ? .original : .transcode(probeFailureStep)
        }
        let budget = Int(Double(measuredKbps) * headroom)
        return sourceKbps <= budget ? .original : .transcode(highestStep(atMost: budget))
    }
}

extension PlexMedia {
    /// Container bitrate in kbps, or size over duration when Plex omits it.
    var sourceKbps: Int? {
        if let bitrate, bitrate > 0 { return bitrate }
        guard let part = Part?.first, let size = part.size, let ms = part.duration ?? duration, ms > 0 else { return nil }
        return Int(Int64(size) * 8 / Int64(ms))
    }
}
```

`StallTracker.swift`:

```swift
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

nonisolated enum StallVerdict: Equatable, Sendable {
    case ignored
    case counted
    case stepDown
}

/// Auto's step-down rule: two stalls within a minute. Seeks and loads buffer by design.
nonisolated struct StallTracker: Sendable {
    static let window: TimeInterval = 60
    static let longStall: TimeInterval = 10
    static let grace: TimeInterval = 5

    private var stalls: [Date] = []
    private var quietUntil: Date = .distantPast

    mutating func noteSeekOrLoad(at date: Date) {
        quietUntil = date.addingTimeInterval(Self.grace)
    }

    mutating func bufferingStarted(at date: Date) -> StallVerdict {
        guard date >= quietUntil else { return .ignored }
        stalls = stalls.filter { date.timeIntervalSince($0) < Self.window } + [date]
        guard stalls.count >= 2 else { return .counted }
        stalls.removeAll()
        return .stepDown
    }

    /// A counted stall still going after this long steps down on its own.
    func isLongStall(startedAt start: Date, now: Date) -> Bool {
        now.timeIntervalSince(start) >= Self.longStall
    }
}
```

`ThroughputProbe.swift`:

```swift
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Measures the link to a server by timing a ranged read of the file Auto would play.
nonisolated enum ThroughputProbe {
    static let byteLimit = 4 << 20
    static let timeLimit: TimeInterval = 2

    /// Rate from bytes received after the first byte; nil when too little arrived to judge.
    static func kbps(bytes: Int, seconds: TimeInterval) -> Int? {
        guard bytes >= 64 * 1024, seconds > 0.05 else { return nil }
        return Int(Double(bytes) * 8 / seconds / 1000)
    }

    static func measure(url: URL, headers: [String: String] = [:], session: URLSession = .shared) async -> Int? {
        var request = URLRequest(url: url, timeoutInterval: 5)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=0-\(byteLimit - 1)", forHTTPHeaderField: "Range")
        guard let (bytes, response) = try? await session.bytes(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            return nil
        }
        let start = Date()
        var count = 0
        do {
            for try await _ in bytes {
                count += 1
                if count >= byteLimit { break }
                if count & 0xFFFF == 0, Date().timeIntervalSince(start) >= timeLimit { break }
            }
        } catch {}
        bytes.task.cancel()
        return kbps(bytes: count, seconds: Date().timeIntervalSince(start))
    }
}
```

- [ ] **Step 4: Run the tests, expect PASS.**

### Task 4: Version ranking core with a cap (RivuletCore)

**Files:**
- Create: `RivuletCore/Streaming/VersionRanking.swift` (moved pure core)
- Modify: `Rivulet/Models/Media/VersionRanking.swift` (keep only the `MediaSource` adapter: `rangeRank(VideoTrack.VideoRange)`, `key(MediaSource)`, `ordered`, `choose`, `distinct`, `primarySource`), rename it `VersionRanking+MediaSource.swift` with `git mv`
- Test: `RivuletTests/Unit/Streaming/VersionCapTests.swift`

**Interfaces:**
- Produces (RivuletCore): `VersionChoice` (unchanged cases), `VersionRanking.Key`, `VersionRanking.tier(label:height:)`, `VersionRanking.key(_ media: PlexMedia) -> Key` (range from `PlexStream`: DOVIPresent = 4, `colorTrc == "smpte2084" && colorPrimaries == "bt2020"` = 2, `colorTrc == "arib-std-b67"` = 1, else 0, exactly matching `PlexMediaMapper.videoTrack`), `VersionRanking.rankedIndices(_:)`, `VersionRanking.pick(_:ids:keys:capKbps:) -> Int?`, `VersionRanking.select(_:in:capKbps:) -> (media: [PlexMedia], serverIndex: Int)`.
- Produces (Rivulet): `VersionRanking.choose(_:from:capKbps:)` with `capKbps` defaulting to nil.
- Cap rule in `pick` for `.best` and `.matchingTier(t)` (pool = versions of tier t, or all when none): with `capKbps`, let `minTier = QualityDecision.highestStep(atMost: capKbps).tier`; return the best-ranked pool member with known bitrate `> 0`, `bitrate <= capKbps * 1000` and `tier >= minTier`; else the lowest-bitrate pool member with `tier >= minTier` and known bitrate; else the pool's best. `.source(id)` ignores the cap. Without a cap, behavior is unchanged.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Rivulet

final class VersionCapTests: XCTestCase {
    private func media(_ id: Int, _ res: String, kbps: Int?) -> PlexMedia {
        PlexMedia(id: id, duration: nil, bitrate: kbps, width: nil, height: nil, aspectRatio: nil,
                  audioChannels: nil, audioCodec: nil, videoCodec: nil, videoResolution: res,
                  container: nil, videoFrameRate: nil, Part: nil)
    }

    private lazy var versions = [media(1, "4k", kbps: 60000), media(2, "1080", kbps: 10000), media(3, "sd", kbps: 1500)]

    func test_noCap_isUnchanged() {
        XCTAssertEqual(VersionRanking.select(.best, in: versions).serverIndex, 0)
    }

    func test_cap_prefersFittingVersionAtOrAboveStepTier() {
        XCTAssertEqual(VersionRanking.select(.best, in: versions, capKbps: 15000).serverIndex, 1)
    }

    func test_cap_neverDropsToSDWhenStepGivesHD() {
        // 6 Mbps cap -> 4 Mbps 720p step: the SD file fits but is below 720, so transcode the 1080p one.
        XCTAssertEqual(VersionRanking.select(.best, in: versions, capKbps: 6000).serverIndex, 1)
    }

    func test_cap_lowStep_allowsSD() {
        XCTAssertEqual(VersionRanking.select(.best, in: versions, capKbps: 1500).serverIndex, 2)
    }

    func test_explicitSource_ignoresCap() {
        XCTAssertEqual(VersionRanking.select(.source("1"), in: versions, capKbps: 1500).serverIndex, 0)
    }
}
```

If `PlexMedia` has no memberwise init visible to tests (it is a Codable struct with lets, so it does), decode from JSON instead.

- [ ] **Step 2: Run, expect failure** (`extra argument 'capKbps'`).
- [ ] **Step 3: Move the core and add the cap.** Keep `Key`, `tier`, `rankedIndices`, `pick`, `select` and `key(PlexMedia)` in RivuletCore (`nonisolated enum VersionRanking`, internal visibility so the tvOS extension can call `pick` and `rankedIndices`). The tvOS file becomes `extension VersionRanking { ... }` holding only the MediaSource adapter; its `choose` passes `capKbps` to `pick`. Do not reference `PlexMediaMapper` from RivuletCore.
- [ ] **Step 4: Run** `VersionRankingTests`, `PlayerVersionSelectionTests`, `ProviderPlaybackVersionTests`, `VersionCapTests`. Expect PASS with the old three unmodified.

### Task 5: Capped Plex transcode URL (RivuletCore)

**Files:**
- Modify: `RivuletCore/Plex/PlexNetworkManager.swift` (`buildHLSDirectPlayURL`, about lines 1648-1795)
- Test: `RivuletTests/Unit/Services/PlexNetworkManagerURLTests.swift` (add cases; do not edit the relay ones)

**Interfaces:**
- Produces: `buildHLSDirectPlayURL(serverURL:authToken:ratingKey:mediaIndex:offsetMs:hasHDR:useDolbyVision:forceVideoTranscode:allowAudioDirectStream:step: QualityStep? = nil)`.
- Rule: `let cap: QualityStep? = relayCapped ? min-by-kbps(step ?? .relay, .relay) : step`. A cap forces transcode and disables DV (as relay does today), sets `videoResolution = cap.videoResolution`, appends `maxVideoBitrate = cap.kbps` and the profile clause `add-limitation(scope=videoCodec&scopeName=*&type=upperBound&name=video.bitrate&value=<cap.kbps>&replace=true)`. Audio is transcoded (directStreamAudio 0, audioCodec "eac3,ac3,aac", audioBitrate 320) only when `cap.kbps < 4000`; otherwise audio follows `allowAudioDirectStream` with audioBitrate 1024. Keep the log line free of the URL.

- [ ] **Step 1: Write failing tests** in the existing test file, following its helpers: step 8000 on a LAN URL yields `maxVideoBitrate=8000`, `videoResolution=1920x1080`, `directPlay=0`, `directStream=0`, `videoCodec=h264`, `directStreamAudio=1`, `audioBitrate=1024`, the `video.bitrate&value=8000` clause in `X-Plex-Client-Profile-Extra`, and `X-Plex-Client-Profile-Name=Generic`; step 2000 yields `directStreamAudio=0`, `audioBitrate=320`; step 8000 on a relay URL yields exactly the relay output (1500, 720x480); step 720 on a relay URL yields `maxVideoBitrate=720`; no step on LAN has no `maxVideoBitrate` (existing test).
- [ ] **Step 2: Run, expect failure.**
- [ ] **Step 3: Implement** by replacing every `relayCapped` use that shapes the request with the `cap` rule above. Keep `relayCapped` only to compute `cap`.
- [ ] **Step 4: Run the whole `PlexNetworkManagerURLTests`, expect PASS** with the relay assertions untouched.

### Task 6: tvOS Plex player integration

**Files:**
- Modify: `Rivulet/Services/Plex/Playback/Pipeline/ContentRouter.swift` (`ContentRoutingContext` ~111, `plan` ~151)
- Modify: `Rivulet/Views/Player/UniversalPlayerViewModel.swift` (anchors from recon: `prepareStreamURL` ~959, plan at ~987 and ~1558, `buildRivuletHLSURL` ~1634, `recordStallTransition` ~1422, `updatePlaybackState` ~1381, aether stall watchdog ~3198, `attemptRivuletHLSFallback` ~2737, `seek(to:)` ~3255, `stopPlayback` ~3115, audio/subtitle selection ~3705 and ~3957, `updateTrackLists` ~3765, next-episode preload ~5416 and swap ~5580-5656, diagnostics `setMedia` ~1011)
- Modify: `Rivulet/Services/Diagnostics/PlaybackDiagnostics.swift` (tags)
- Test: `RivuletTests/Unit/Playback/ContentRouterQualityTests.swift` (or the existing ContentRouter test file)

**Interfaces:**
- Consumes: Tasks 1-5.
- Produces on the view model (MainActor): `@Published private(set) var qualityChoice: StreamingQuality` (session choice; starts as the Home/Away setting), `@Published private(set) var activeStreamPlan: StreamPlan`, `var qualityMenuLabel: String` ("Auto · 8 Mbps", "Auto · Original", "Original", "4 Mbps 720p"), `var isQualityMenuAvailable: Bool` (Plex or provider VOD; false for Live TV), `func selectQuality(_ quality: StreamingQuality)`.

Steps:

- [ ] **Step 1: Router test first.** `ContentRoutingContext` gains `transcodeStep: QualityStep?` (default nil). Test: with a LAN serverURL, a direct-play-capable metadata and `transcodeStep = 8000 step`, `plan.primary` is `.hls` and `fallbacks` is empty; with nil it is unchanged (aether primary, hls fallback). Implement in `plan()` beside the relay branch.
- [ ] **Step 2: Decide at prepare.** In `prepareStreamURL`, before `ContentRouter.plan`: `isRelay = PlexRelay.isRelayURL(serverURL)`; `home = StreamingQuality.isHome(serverURL:)`; `setting = sessionQuality ?? StreamingQuality.setting(home:)`; if `QualityDecision.needsProbe`, measure with `ThroughputProbe.measure` against the best-ranked version's direct-play URL (reuse a measurement younger than 10 minutes stored on the VM, so Up Next does not probe again); `cap = QualityDecision.capKbps(...)`; re-run `VersionRanking.select(currentVersionChoice-or-best, in: metadata.Media, capKbps: cap)` so `playingMediaID` / `playingMediaServerIndex` reflect the capped pick WITHOUT touching `pickedVersion` or `preferredMediaID`; `activeStreamPlan = QualityDecision.decide(setting:sourceKbps: chosenMedia.sourceKbps, measuredKbps:isRelay:)`; pass `activeStreamPlan.step` into the context and into `buildRivuletHLSURL` -> `buildHLSDirectPlayURL(step:)`. Also at the re-plan site (~1558).
- [ ] **Step 3: One reload helper.** Extract from `attemptRivuletHLSFallback` the body that builds the HLS URL at an offset, sets `streamURL`/`streamHeaders`/`plexSessionId`/`activeRoute`, preflights, calls `loadAVPlayer` and seeks. The helper first calls `networkManager.stopTranscodeSession` for the OUTGOING `plexSessionId` when one exists, cancels the aether stall watchdog, tears down the aether player when leaving the aether route, preserves rate and paused state, and stamps `stallTracker.noteSeekOrLoad(at: .now)`. The fallback keeps its one-shot guards, `recordPrimaryFailure` and Sentry tags around the helper. Switching to `.original` re-runs the normal aether start at the current position (the same path initial start uses, with `startTime = currentTime`), also stopping the outgoing transcode session.
- [ ] **Step 4: `selectQuality(_:)`.** Sets `qualityChoice`, re-decides with the current version (`currentVersionChoice`, no re-rank), and reloads only when the resulting plan differs from `activeStreamPlan`. Persist for the session: Up Next and the next-episode swap read `qualityChoice`; a new player session starts from the setting.
- [ ] **Step 5: Stall step-down (Auto only).** In the single buffering funnel (`updatePlaybackState(.buffering)` entry, which both routes reach), call `stallTracker.bufferingStarted(at:)` when `qualityChoice == .auto`. On `.stepDown`, or when a `.counted` stall is still buffering after `StallTracker.longStall` seconds (one cancellable Task), compute `QualityDecision.stepDown(from: activeStreamPlan, sourceKbps:)`; if non-nil, reload at that step through the helper and log a breadcrumb (no URL). Stamp `noteSeekOrLoad` in `seek(to:)`, in scrub commits, at every load and on resume from background. Never step up.
- [ ] **Step 6: Tracks on a transcode.** Before building any Plex transcode URL (initial or reload), PUT the chosen audio and subtitle streams with `setSelectedAudioStream` / `setSelectedSubtitleStream` (Plex stream ids; translate an engine index through the merged `MediaTrack`'s Plex stream id). While on the HLS route, `selectAudioTrack*` and `selectSubtitleTrack*` PUT the choice and reload at the current position through the helper. After any route switch reset `hasAppliedAudioPreference` / `hasAppliedSubtitlePreference` and re-seed `currentAudioTrackId` / `currentSubtitleTrackId` in the new id space so the checkmark matches what plays.
- [ ] **Step 7: Up Next.** The next-episode preload prewarms a direct-play URL only when `activeStreamPlan == .original`; otherwise skip the prewarm. `playNextEpisode` re-decides with `qualityChoice` (Auto resets steps, reuses a measurement younger than 10 minutes).
- [ ] **Step 8: Diagnostics.** Add tags `stream_quality` (`original`, `auto`, or step kbps) and `stream_location` (`home`/`away`) where `is_relay` is set. No URLs.
- [ ] **Step 9: Build tvOS and run the full test suite.**

### Task 7: tvOS UI (rail Quality menu and Settings)

**Files:**
- Modify: `Rivulet/Views/Player/UIKit/PlayerRailView.swift` (tool row ~119, wiring ~159-177), `Rivulet/Views/Player/PlayerContainerViewController.swift` (beside `rail.onFilter` ~1493-1512)
- Modify: `Rivulet/Views/Settings/SettingsModels.swift` (SettingsPage ~47-83), `Rivulet/Views/Settings/UIKit/SettingsPageModels.swift` (playback ~302-328, pickers beside ~208-222, `rows(for:)` ~170-196), `Rivulet/Views/Settings/SettingsDescriptors.swift` (Playback block ~140-159, prefix fallbacks ~23-32, pageInfo ~402-426)

**Interfaces:**
- Consumes: Task 6 view-model API.

Steps:

- [ ] **Step 1: Rail.** Add `qualityButton` (a `TransportControlButton` with an SF Symbol such as `dial.medium` or `slider.horizontal.3`, hidden by default like `filterButton`), `var onQuality`, `setQualityAvailable(_:)`; insert it left of `subtitlesButton`. Live TV never calls `setQualityAvailable(true)`.
- [ ] **Step 2: Menu.** In `PlayerContainerViewController`, `rail.onQuality` presents `CardTrackListView(header: "Quality", rows:onSelect:)` exactly like the Content Filter menu: rows for `StreamingQuality.allChoices` (Auto's subtitle shows the active step, for example "Playing 8 Mbps 1080p" or "Playing Original"), `trackId` = index into `allChoices`, `isSelected` = `qualityChoice`. Selecting calls `viewModel.selectQuality` and dismisses. Bind visibility to `isQualityMenuAvailable` with a Combine sink.
- [ ] **Step 3: Settings.** Add `SettingsPage.homeQualityPicker` and `.awayQualityPicker` (titles "Home Streaming", "Away Streaming"), two `.navigationValue` rows on the Playback page ("Home Streaming Quality", "Away Streaming Quality") showing the current label, and picker pages of `.option` rows over `StreamingQuality.allChoices` writing `rawValue` to `StreamingQuality.homeKey` / `awayKey` (pattern: `skipIntervalPicker`). Descriptors: Home: "Quality when the server is on your home network. Original plays the file untouched, with HDR, Dolby Vision and Atmos." Away: "Quality on cellular, a hotspot, Low Data Mode or a remote connection. Auto measures your connection and converts only when the file will not fit." Add pageInfo cases and prefix fallbacks for option rows.
- [ ] **Step 4: Grep both keys**: each must have a reader outside `SettingsPageModels.swift` (`StreamingQuality.setting`). Build tvOS.

### Task 8: tvOS Jellyfin

**Files:**
- Modify: `Rivulet/Services/MediaProvider/MediaProvider.swift` (~78, ~83, default impls ~125), `Rivulet/Services/MediaProvider/Jellyfin/JellyfinModels.swift` (`JFPlaybackInfoRequest.playback` ~236-264), `Rivulet/Services/MediaProvider/Jellyfin/JellyfinProvider.swift` (~324-366), `Rivulet/Services/MediaProvider/Plex/PlexProvider.swift` (signature only), `Rivulet/Views/Player/ProviderPlayback+Prepare.swift` (~20), `Rivulet/Views/Player/UniversalPlayerViewModel.swift` (`prepareProviderStream` ~1052, `switchToProviderTranscode` ~2814)
- Test: `RivuletTests/Unit/...` Jellyfin request test (follow the existing Jellyfin test file's helpers)

**Interfaces:**
- Produces: `resolveStream(for:sourceID:maxBitrate: Int?)` and `transcodeStream(for:sourceID:startTime:maxBitrate: Int?)` (bps, nil = uncapped) with protocol-extension overloads keeping old call sites compiling; `JFPlaybackInfoRequest.playback(..., maxStreamingBitrate: Int?)` sending the cap in both the body and the device profile when non-nil, else the existing 400_000_000.

Steps:

- [ ] **Step 1: Failing test:** a playback request built with `maxStreamingBitrate: 8_000_000` encodes `MaxStreamingBitrate` 8000000 in the body and the device profile; nil encodes 400000000.
- [ ] **Step 2: Implement** the threading. `JellyfinProvider` passes the cap to `VersionRanking.choose(_:from:capKbps:)` as well, so a fitting version is chosen before the server decides.
- [ ] **Step 3: Decide in `ProviderPlayback.prepare`:** location from the provider's stream URL (never the VM's empty `serverURL`); setting = session choice or Home/Away setting; probe the direct stream URL when Auto needs it; cap = `QualityDecision.capKbps`; request the stream with `maxBitrate = cap * 1000` when the plan is a transcode.
- [ ] **Step 4: Step-down and the menu on Jellyfin** go through `switchToProviderTranscode` with the new bitrate (it already rolls the play session and reporter); `.original` re-resolves with nil. Diagnostics tags as in Task 6.
- [ ] **Step 5: Build tvOS and run the full test suite.**

### Task 9: iOS / iPadOS

**Files:**
- Modify: `RivuletiOS/Plex/IOSPlexSession.swift` (`playback(for:)` ~342, `IOSPlexPlaybackRequest` ~449), `RivuletiOS/Plex/IOSPlexPlayerView.swift` (`IOSPlexPlayback` load ~66, end ~47, playNext ~230, screen wiring ~259-291), `RivuletiOS/Player/AetherPlayer.swift` (stall publisher; `beginLoad` ~545 autoplay/rate options), `RivuletiOS/Player/IOSPlayerChrome.swift` (bottom row ~307-313, inits ~88 and ~608, actions ~34-50), `RivuletiOS/Plex/Components/IOSPlexActions.swift` (play ~58-71), `RivuletiOS/Settings/IOSSettingsPages.swift` (Playback form ~24-67)

**Interfaces:**
- Consumes: Tasks 1-5.
- Produces: `IOSPlexSession.playback(for: PlexMetadata, quality: StreamingQuality? = nil) async throws -> IOSPlexPlaybackRequest`; `IOSPlexPlaybackRequest` gains `plan: StreamPlan`, `quality: StreamingQuality` (the choice that produced it), `sourceKbps: Int?`, `transcodeSessionID: String?`, `measuredKbps: Int?`, `measuredAt: Date?`; `IOSPlexPlayback.switchQuality(_ quality: StreamingQuality)`; `AetherPlayer.stallStarts: AnyPublisher<Date, Never>` (or a `@Published` counterpart) driven by `engine.playbackPhase` `.rebuffering` / `.stalled`, excluding `isStarting` and pending seeks.

Steps:

- [ ] **Step 1: Resolver.** In `playback(for:quality:)`: `isRelay`, `home = StreamingQuality.isHome(serverURL:)`, `setting = quality ?? StreamingQuality.setting(home:)`; probe when needed (best-ranked version's direct URL; reuse a request's measurement younger than 10 minutes when given); `cap`; `VersionRanking.select(.best, in: full.Media ?? [], capKbps: cap)` so the chosen media and `mediaIndex` drive both the direct URL (its first part key) and the transcode; `plan = QualityDecision.decide(...)`; `.original` -> today's direct URL; `.transcode(step)` -> PUT the item's default/selected audio and subtitle stream ids is NOT needed at first play, then `network.buildHLSDirectPlayURL(serverURL:authToken:ratingKey:mediaIndex:offsetMs:hasHDR:useDolbyVision: false, forceVideoTranscode: true, allowAudioDirectStream: true, step: step)`, keep its headers and parse `session` out of the URL into `transcodeSessionID`. Sidecar subtitles: attach only for `.original` (a transcode carries the server's subtitle rendition).
- [ ] **Step 2: Stop sessions.** `IOSPlexPlayback.end` and every reload call `network.stopTranscodeSession` for the outgoing `transcodeSessionID`.
- [ ] **Step 3: `switchQuality(_:)`.** Rebuild the request with `playback(for: request.item, quality:)` (reusing the measurement) and the current version; if the plan is unchanged, keep playing. Otherwise stop the old session, set `request`, and load at `player.currentTime` through a `load(startTime:autoplay:)` overload that does not fire `onItemChange`, keeps the playback rate and the paused state, and holds `evaluateAutoSkip` until `player.isStarting` clears. The session's `quality` persists for `playNext`.
- [ ] **Step 4: Stall step-down.** `IOSPlexPlayback` keeps a `StallTracker`; stamps `noteSeekOrLoad` on loads and user seeks; on `.stepDown` or a 10 s counted stall while `quality == .auto`, reload one step down (`QualityDecision.stepDown`).
- [ ] **Step 5: Fallback.** On a direct-play startup failure (`.failed` before first frame on `.original`), retry once as a transcode at `QualityDecision.capKbps`'s step (Auto) or 8000, then show Retry if that fails too.
- [ ] **Step 6: Tracks on a transcode.** When `plan` is a transcode, choosing audio or subtitles PUTs the Plex stream id (`setSelectedAudioStream` / `setSelectedSubtitleStream`, part id from the chosen media) and reloads at the current position with the same quality.
- [ ] **Step 7: Chrome.** Optional `quality: (choices: [StreamingQuality], selected: StreamingQuality, label: String)?` input (nil hides it), a glass capsule `Menu` with an inline `Picker` beside `speedMenu`, and `IOSPlayerChromeActions.selectQuality` with a default no-op; extend both inits; Plex passes it, Live TV passes nil. Menu label: the effective quality ("Auto · 8 Mbps").
- [ ] **Step 8: Settings.** In `IOSPlaybackSettingsView` add `Section("Streaming Quality")` with `Picker("Home", selection: $home)` and `Picker("Away", selection: $away)` over `StreamingQuality.allChoices`, `@AppStorage(StreamingQuality.homeKey) private var home = StreamingQuality.homeDefault` (same for away), footer: "Away covers cellular, a personal hotspot, Low Data Mode and connections outside your home network. Auto converts only when the file will not fit your connection."
- [ ] **Step 9: Build iOS.**

### Task 10: Verification (coordinator)

- [ ] Full tvOS test suite: `** TEST SUCCEEDED **`, zero `✘`.
- [ ] iOS build; tvOS build.
- [ ] SwiftLint 0.65.0 `--strict`: zero violations.
- [ ] No em/en dashes in added lines.
- [ ] Simulator, with a temporary uncommitted debug override forcing Away and a chosen step: iOS plays a Plex transcode (check the PMS session list shows a transcode at the step), the Quality menu switches Original <-> 4 Mbps at the same position, ending playback stops the PMS transcode session; tvOS the same through the rail menu.
- [ ] Remove the debug override; one commit.
