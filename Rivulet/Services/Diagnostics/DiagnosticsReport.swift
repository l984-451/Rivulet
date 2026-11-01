// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Settings > About > Send Diagnostics: a snapshot of app state plus recent log lines,
// sent as one Sentry event. The user quotes the short code; search `diag_code:<code>`.
// Counts, kinds and flags only: no titles, server names or addresses.

import AVFoundation
import AVKit
import Foundation
import OSLog
import Sentry
import UIKit

@MainActor
enum DiagnosticsReport {
    private(set) static var isSending = false

    /// Sends the report and returns its code, or nil when Sentry is not running.
    static func send(window: UIWindow?, onStart: () -> Void) async -> String? {
        isSending = true
        defer { isSending = false }
        onStart()
        // Let the row's spinner draw before the snapshot's main-thread work.
        try? await Task.sleep(for: .milliseconds(50))

        let sections = collect(window: window)
        let logLines = await Task.detached(priority: .userInitiated) { recentLogLines() }.value

        let event = Event(level: .info)
        event.message = SentryMessage(formatted: "User diagnostics")
        event.fingerprint = ["rivulet-diagnostics"]
        let code = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
        let shown = "\(code.prefix(4))-\(code.suffix(4))"
        event.tags = ["diag_code": shown]
        event.context = sections.compactMapValues { $0 as? [String: Any] }

        var full = sections
        full["log"] = logLines
        full["settings"] = settingsSnapshot()
        let redacted = SentryEventRedaction.redactAny(full)
        var attachments: [Attachment] = []
        if JSONSerialization.isValidJSONObject(redacted),
           let data = try? JSONSerialization.data(withJSONObject: redacted, options: [.prettyPrinted, .sortedKeys]) {
            attachments.append(Attachment(data: data, filename: "diagnostics.json", contentType: "application/json"))
        }
        return SentryBridge.capture(event: event, attachments: attachments) == nil ? nil : shown
    }

    // MARK: - Sections

    /// Every section, keyed by name. Values are JSON-safe (strings, numbers, bools, arrays, dictionaries).
    static func collect(window: UIWindow?) -> [String: Any] {
        [
            "rivulet_app": app(),
            "rivulet_device": device(window: window),
            "plex": plex(),
            "plex_profile": profile(),
            "home": home(),
            "other_servers": otherServers(),
            "live_tv": liveTV(),
            "top_shelf": topShelf(),
        ]
    }

    private static func app() -> [String: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        return [
            "version": info["CFBundleShortVersionString"] as? String ?? "?",
            "build": info["CFBundleVersion"] as? String ?? "?",
            "locale": Locale.current.identifier,
            "languages": Array(Locale.preferredLanguages.prefix(4)),
            "time_zone": TimeZone.current.identifier,
            // Unset means the shell's default: complete when any source exists.
            "setup_complete": UserDefaults.standard.object(forKey: "setupComplete") as? Bool ?? "unset",
        ]
    }

    private static func device(window: UIWindow?) -> [String: Any] {
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let process = ProcessInfo.processInfo
        let screen = window?.screen ?? UIScreen.main
        let audio = AVAudioSession.sharedInstance()
        let freeDisk = (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity) ?? -1
        return [
            "model": model,
            "os": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "memory_mb": Int(process.physicalMemory / 1_048_576),
            "app_available_memory_mb": Int(os_proc_available_memory() / 1_048_576),
            "free_disk_mb": freeDisk / 1_048_576,
            "thermal_state": process.thermalState.rawValue,
            "system_uptime_min": Int(process.systemUptime / 60),
            "screen": "\(Int(screen.nativeBounds.width))x\(Int(screen.nativeBounds.height)) @\(screen.maximumFramesPerSecond)Hz",
            "hdr_eligible": AVPlayer.eligibleForHDRPlayback,
            "hdr_modes": AVPlayer.availableHDRModes.rawValue,
            "match_content": window?.avDisplayManager.isDisplayCriteriaMatchingEnabled ?? false,
            "audio_outputs": audio.currentRoute.outputs.map(\.portType.rawValue),
            "audio_max_channels": audio.maximumOutputNumberOfChannels,
            "audio_channels": audio.outputNumberOfChannels,
            "audio_sample_rate": audio.sampleRate,
            "audio_latency_ms": Int(audio.outputLatency * 1000),
        ]
    }

    private static func plex() -> [String: Any] {
        let auth = PlexAuthManager.shared
        var result: [String: Any] = [
            "signed_in": auth.isAuthenticated,
            "server_chosen": auth.selectedServerURL != nil,
            "has_server_token": auth.selectedServerToken != nil,
            "connected": auth.isConnected,
            "connection_error": auth.connectionError ?? "none",
        ]
        if let server = auth.selectedServer {
            result["server_version"] = server.productVersion
            result["server_platform"] = server.platform ?? "?"
            result["owned"] = server.owned ?? false
            result["https_required"] = server.httpsRequired ?? false
            result["connection_count"] = server.connections?.count ?? 0
        }
        if let url = auth.selectedServerURL {
            result["connection"] = connectionKind(url, server: auth.selectedServer)
        }
        return result
    }

    /// Which of the server's connections is in use, described without the address.
    private static func connectionKind(_ url: String, server: PlexDevice?) -> String {
        let scheme = URL(string: url)?.scheme ?? "?"
        let host = URL(string: url)?.host ?? ""
        let hostKind = host.hasSuffix(".plex.direct") ? "plex.direct"
            : host.allSatisfy({ $0.isNumber || $0 == "." }) ? "ipv4" : host.contains(":") ? "ipv6" : "hostname"
        guard let server else { return "\(scheme) \(hostKind), server details not loaded" }
        guard let match = server.connections?.first(where: { url.hasPrefix($0.uri) }) else {
            return "\(scheme) \(hostKind), not in the server's connection list"
        }
        return "\(scheme) \(hostKind) \(match.relay ? "relay" : match.local ? "local" : "remote")"
    }

    private static func profile() -> [String: Any] {
        let auth = PlexAuthManager.shared
        let profiles = PlexUserProfileManager.shared
        var result: [String: Any] = [
            "home_users": profiles.homeUsers.count,
            "profiles_loaded": profiles.hasLoadedProfiles,
            "picker_on_launch": profiles.showProfilePickerOnLaunch,
            "relocks_on_launch": auth.relocksOnLaunch,
            "content_withheld": auth.isContentWithheld,
            "content_owner_is_account": auth.contentOwnerID == 0,
            "remembered_pins": profiles.usersWithRememberedPins.count,
            "users_error": profiles.usersError ?? "none",
        ]
        if let user = profiles.selectedUser {
            result["selected"] = [
                "is_account": auth.isAccount(user),
                "admin": user.admin,
                "managed": user.isManagedUser,
                "restricted": user.restricted,
                "requires_pin": user.requiresPin,
                "pin_remembered": profiles.hasRememberedPin(for: user),
            ]
        } else {
            result["selected"] = "none"
        }
        return result
    }

    private static func home() -> [String: Any] {
        let store = PlexDataStore.shared
        return [
            "hubs": store.hubs.count,
            "continue_watching": store.continueWatchingHub?.Metadata?.count ?? -1,
            // Visibility 1/2 (excluded from home) also drops the library from Continue Watching.
            "libraries": store.libraries.map { "\($0.type) visibility=\($0.hidden ?? 0)" },
            "rows": store.homeItems.count,
            "row_items": store.homeItems.map(\.items.count),
            "hubs_error": store.hubsError ?? "none",
            "libraries_error": store.librariesError ?? "none",
        ]
    }

    private static func otherServers() -> [String: Any] {
        let store = ServerDataStore.shared
        return [
            "sources": store.sources.map { String($0.providerID.prefix { $0 != ":" }) },
            "libraries": store.libraries.count,
            "home_rows": store.homeRows.count,
        ]
    }

    private static func liveTV() -> [String: Any] {
        let store = LiveTVDataStore.shared
        return [
            "sources": store.sources.map { source -> [String: Any] in
                [
                    "type": source.sourceType.rawValue,
                    "channels": source.channelCount,
                    "connected": source.isConnected,
                    "synced_min_ago": source.lastSync.map { Int(-$0.timeIntervalSinceNow / 60) } ?? -1,
                    "channel_profile": source.channelProfile != nil,
                ]
            },
            "channels": store.channels.count,
            "guide_channels": store.epg.count,
            "guide_hours_ahead": store.epgLoadedThrough.map { Int($0.timeIntervalSinceNow / 3600) } ?? -1,
            "guide_issues": store.epgIssues.map(\.reason),
            "channels_error": store.channelsError ?? "none",
        ]
    }

    private static func topShelf() -> [String: Any] {
        var result = TopShelfCache.shared.diagnostics()
        let auth = PlexAuthManager.shared
        let profiles = PlexUserProfileManager.shared
        // TopShelfFeed's PIN rule, evaluated now.
        result["pin_gate_blocks"] = auth.relocksOnLaunch
            && !(profiles.selectedUser.map(profiles.hasRememberedPin(for:)) ?? false)
        return result
    }

    // MARK: - Settings and log

    /// The app's own settings: numbers, flags and short plain strings. Anything that could be a
    /// credential, address or name is left out.
    private static func settingsSnapshot() -> [String: Any] {
        let skippedPrefixes = ["NS", "Apple", "AK", "com.apple", "PK", "WebKit", "INNext"]
        let secretWords = ["token", "pin", "password", "secret", "url", "server", "address", "user", "email", "name"]
        var result: [String: Any] = [:]
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() {
            guard !skippedPrefixes.contains(where: key.hasPrefix) else { continue }
            let lower = key.lowercased()
            guard !secretWords.contains(where: lower.contains) else { continue }
            switch value {
            case let number as NSNumber:
                result[key] = number
            case let string as String where string.count <= 40
                && !string.contains("/") && !string.contains("@") && !string.contains(":"):
                result[key] = string
            default:
                continue
            }
            if result.count >= 400 { break }
        }
        return result
    }

    /// This process's log since launch, newest last, in four capped groups so one chatty source
    /// cannot push out the rest: Rivulet's own lines (the launch kept too), its network lines,
    /// AetherEngine, and errors from everything else. `print` never reaches OSLog; see `DiagLog`.
    nonisolated static func recentLogLines() -> [String: Any] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries()
        else { return ["unavailable": true] }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        var app = LogBucket(head: 150, tail: 1350)
        var http = LogBucket(head: 0, tail: 400)
        var engine = LogBucket(head: 50, tail: 600)
        var system = LogBucket(head: 0, tail: 200)
        for case let entry as OSLogEntryLog in entries where entry.level.rawValue >= OSLogEntryLog.Level.notice.rawValue {
            let subsystem = entry.subsystem
            let isError = entry.level.rawValue >= OSLogEntryLog.Level.error.rawValue
            let line = "\(formatter.string(from: entry.date)) \(isError ? "E " : "")[\(entry.category)] \(entry.composedMessage)"
            if subsystem.hasPrefix("com.rivulet") || subsystem.hasPrefix("com.bain") {
                entry.category == DiagLog.Category.http.rawValue ? http.add(line) : app.add(line)
            } else if subsystem.hasPrefix("de.superuser404") {
                engine.add(line)
            } else if isError {
                system.add("\(line) {\(subsystem)}")
            }
        }
        return ["app": app.lines, "http": http.lines, "engine": engine.lines, "system_errors": system.lines]
    }
}

/// Keeps the first `head` and last `tail` lines, notes how many fell between, and folds runs of
/// one repeated message into a count.
nonisolated struct LogBucket {
    let head: Int
    let tail: Int
    private var first: [String] = []
    private var last: [String] = []
    private var dropped = 0
    private var lastMessage = ""
    private var repeats = 0

    init(head: Int, tail: Int) {
        self.head = head
        self.tail = tail
    }

    mutating func add(_ line: String) {
        let line = String(line.prefix(400))
        // Everything after the timestamp, so a repeat at a new time still folds.
        let message = String(line.drop { $0 != " " })
        if message == lastMessage {
            repeats += 1
            return
        }
        flushRepeats()
        lastMessage = message
        append(line)
    }

    var lines: [String] {
        var copy = self
        copy.flushRepeats()
        return copy.first + (copy.dropped > 0 ? ["… \(copy.dropped) lines omitted …"] : []) + copy.last
    }

    private mutating func flushRepeats() {
        guard repeats > 0 else { return }
        append("  (repeated \(repeats)x)")
        repeats = 0
    }

    private mutating func append(_ line: String) {
        if first.count < head {
            first.append(line)
            return
        }
        last.append(line)
        if last.count > tail {
            // ponytail: O(n) removeFirst per overflow; fine at these sizes, ring buffer if it ever shows.
            last.removeFirst()
            dropped += 1
        }
    }
}
