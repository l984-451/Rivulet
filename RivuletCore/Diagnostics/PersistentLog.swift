// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// A size-capped log on disk, fed by DiagLog, so a report can show the launch before this one
// (a freeze followed by a relaunch leaves nothing in OSLog's current-process scope).
// Two files in Caches: this launch and the one before. Lines are already redacted by DiagLog.

import Foundation

nonisolated enum DiagLaunch {
    /// Tags this process's log and playback records.
    static let id = String(UUID().uuidString.prefix(8))
    static let startedAt = Date()
}

nonisolated final class PersistentLog: @unchecked Sendable {
    static let shared = PersistentLog(
        directory: (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("Diagnostics", isDirectory: true),
        observesLifecycle: true)

    static let lifecycleTag = "[life]"

    private let queue = DispatchQueue(label: "com.rivulet.persistent-log", qos: .utility)
    private let maxBytes: Int
    private let current: URL
    private let previous: URL
    private var handle: FileHandle?
    private var size = 0
    private let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private var observers: [NSObjectProtocol] = []

    /// Moves the last launch's file aside and opens a fresh one headed by the launch marker.
    init(directory: URL, maxBytes: Int = 1_000_000, version: String? = nil, observesLifecycle: Bool = false) {
        self.maxBytes = maxBytes
        current = directory.appendingPathComponent("log-current.txt")
        previous = directory.appendingPathComponent("log-previous.txt")
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // A launch that logged next to nothing (crash on start, relaunch loop) must not
        // push out the launch that actually has the story.
        let lastSize = (try? fm.attributesOfItem(atPath: current.path)[.size] as? Int) ?? 0
        if lastSize > 1_000 {
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: current, to: previous)
        }
        fm.createFile(atPath: current.path, contents: nil)
        handle = try? FileHandle(forWritingTo: current)
        let info = Bundle.main.infoDictionary ?? [:]
        let v = version ?? "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        write("=== launch \(DiagLaunch.id) v\(v) at \(stamp.string(from: Date())) os \(ProcessInfo.processInfo.operatingSystemVersionString)")
        if observesLifecycle { observeLifecycle() }
    }

    /// Appends a notice-or-error line. Returns at once; the file work runs on a utility queue.
    func append(_ category: String, _ message: String, isError: Bool) {
        let now = Date()
        queue.async { [self] in
            write("\(stamp.string(from: now)) \(isError ? "E " : "")[\(category)] \(message.prefix(600))")
        }
    }

    /// Foreground, background or terminate. A launch whose last marker is "foreground" never left cleanly.
    func mark(_ event: String) {
        append("life", "\(Self.lifecycleTag) \(event)", isError: false)
    }

    /// Both apps' notification names, as strings, so no platform import is needed here.
    private func observeLifecycle() {
        let events: [(String, String)] = [
            ("UIApplicationDidBecomeActiveNotification", "foreground"),
            ("UIApplicationDidEnterBackgroundNotification", "background"),
            ("UIApplicationWillTerminateNotification", "terminate"),
            ("NSApplicationDidBecomeActiveNotification", "foreground"),
            ("NSApplicationDidResignActiveNotification", "background"),
            ("NSApplicationWillTerminateNotification", "terminate"),
        ]
        observers = events.map { name, event in
            NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: nil) { [weak self] _ in
                self?.mark(event)
            }
        }
    }

    /// Waits for pending writes. For tests and for the moment a report is read.
    func flush() { queue.sync {} }

    /// The last `limit` lines of each file, plus how the previous launch last said it was doing.
    func tail(limit: Int = 5000) -> (previous: [String], current: [String], previousEnd: String) {
        queue.sync {
            let prev = Self.lines(of: previous, limit: limit)
            let last = prev.last { $0.contains(Self.lifecycleTag) }
                .flatMap { $0.components(separatedBy: Self.lifecycleTag).last?.trimmingCharacters(in: .whitespaces) }
            let end = prev.isEmpty ? "no previous launch" : (last ?? "no lifecycle marker")
            return (prev, Self.lines(of: current, limit: limit), end)
        }
    }

    private static func lines(of url: URL, limit: Int) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return Array(String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(limit).map(String.init))
    }

    // Queue-confined from here down (init is the one exception, before anything else holds a reference).

    private func write(_ line: String) {
        let data = Data((line + "\n").utf8)
        try? handle?.write(contentsOf: data)
        size += data.count
        if size > maxBytes { truncate() }
    }

    /// Keeps the launch marker and the newest half, so the file never passes the cap.
    private func truncate() {
        try? handle?.close()
        guard let data = try? Data(contentsOf: current) else { return }
        let text = String(decoding: data, as: UTF8.self)
        let all = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard let head = all.first else { return }
        var kept: [Substring] = []
        var bytes = 0
        for line in all.dropFirst().reversed() {
            bytes += line.utf8.count + 1
            if bytes > maxBytes / 2 { break }
            kept.append(line)
        }
        let body = ([head, "[earlier lines dropped]"] + kept.reversed()).joined(separator: "\n") + "\n"
        try? Data(body.utf8).write(to: current, options: .atomic)
        handle = try? FileHandle(forWritingTo: current)
        _ = try? handle?.seekToEnd()
        size = body.utf8.count
    }
}
