// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// `os_signpost` Points of Interest for the Home perf traces (subsystem `com.rivulet.perf`).
// Names: AppLaunch, HomeFirstFrameOnScreen (events); HomeDataFetch, HomeFirstRender,
// CellPrepare, ImageDecode, FocusUpdate (intervals).

import Foundation
import os.log
import os.signpost

/// Subsystem-scoped logger for perf signposts. Custom subsystem keeps perf
/// events isolated from the app's normal logging firehose so Instruments
/// templates can subscribe to just `com.rivulet.perf`.
@MainActor
enum PerfLog {
    static let log = OSLog(subsystem: "com.rivulet.perf", category: .pointsOfInterest)
}

/// Type-safe signpost names. Matches the reference table above.
enum PerfSignpost: String {
    case appLaunch = "AppLaunch"
    case homeDataFetch = "HomeDataFetch"
    case homeFirstRender = "HomeFirstRender"
    case homeFirstFrameOnScreen = "HomeFirstFrameOnScreen"
    case cellPrepare = "CellPrepare"
    case imageDecode = "ImageDecode"
    case focusUpdate = "FocusUpdate"
}

/// Lightweight wrapper around `os_signpost` so callers don't have to deal
/// with `OSSignpostID` plumbing. For per-instance intervals (e.g. per-cell),
/// pass a stable `key` (the cell's reuse identity is fine) so the begin/end
/// pair can be matched in Instruments.
@MainActor
enum Perf {
    /// Mark a one-shot event.
    static func event(_ signpost: PerfSignpost, message: String = "") {
        os_signpost(
            .event,
            log: PerfLog.log,
            name: signpost.rawValue.staticString,
            "msg=%{public}s",
            message
        )
    }

    /// Begin an interval keyed by `key` (defaults to the signpost name itself
    /// for singleton intervals like AppLaunch). Returns the `OSSignpostID` so
    /// the caller can hand it to `end(...)`.
    @discardableResult
    static func begin(_ signpost: PerfSignpost, key: AnyHashable? = nil, message: String = "") -> OSSignpostID {
        let id = signpostID(for: signpost, key: key)
        os_signpost(
            .begin,
            log: PerfLog.log,
            name: signpost.rawValue.staticString,
            signpostID: id,
            "msg=%{public}s",
            message
        )
        return id
    }

    /// End an interval started with `begin(_:key:)`. Same `key` must be passed.
    static func end(_ signpost: PerfSignpost, key: AnyHashable? = nil, id: OSSignpostID? = nil, message: String = "") {
        let id = id ?? signpostID(for: signpost, key: key)
        os_signpost(
            .end,
            log: PerfLog.log,
            name: signpost.rawValue.staticString,
            signpostID: id,
            "msg=%{public}s",
            message
        )
    }

    /// Convenience: time the closure and emit a begin/end pair.
    static func interval<T>(_ signpost: PerfSignpost, key: AnyHashable? = nil, _ work: () throws -> T) rethrows -> T {
        let id = begin(signpost, key: key)
        defer { end(signpost, key: key, id: id) }
        return try work()
    }

    /// Async variant.
    static func interval<T>(_ signpost: PerfSignpost, key: AnyHashable? = nil, _ work: () async throws -> T) async rethrows -> T {
        let id = begin(signpost, key: key)
        defer { end(signpost, key: key, id: id) }
        return try await work()
    }

    private static func signpostID(for signpost: PerfSignpost, key: AnyHashable?) -> OSSignpostID {
        // Stable hashing across call sites so begin/end with the same key
        // produce the same OSSignpostID. AnyHashable's hashValue is stable
        // within a process run.
        let hashSeed = (key?.hashValue ?? 0) ^ signpost.rawValue.hashValue
        return OSSignpostID(UInt64(bitPattern: Int64(hashSeed)))
    }
}

// MARK: - StaticString bridging

private extension String {
    /// `os_signpost` requires `StaticString`. We can't synthesize one from
    /// arbitrary input at runtime, so this helper hand-maps known PerfSignpost
    /// names. Keeps the rest of the API ergonomic (callers pass the enum).
    var staticString: StaticString {
        switch self {
        case "AppLaunch": return "AppLaunch"
        case "HomeDataFetch": return "HomeDataFetch"
        case "HomeFirstRender": return "HomeFirstRender"
        case "HomeFirstFrameOnScreen": return "HomeFirstFrameOnScreen"
        case "HomeScroll": return "HomeScroll"
        case "CellPrepare": return "CellPrepare"
        case "ImageDecode": return "ImageDecode"
        case "FocusUpdate": return "FocusUpdate"
        default: return "Unknown"
        }
    }
}
