// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SentryBridge.swift
//  Rivulet
//
//  Thin wrapper around SentrySDK that silently no-ops in DEBUG builds.
//  The SDK is never started in debug, so calling it directly generates
//  console noise for every breadcrumb and capture call.
//

import Sentry
import Synchronization

// `nonisolated`: under MainActor default isolation every capture from a
// non-isolated context would be an actor hop. SentrySDK is thread-safe.
nonisolated enum SentryBridge {
    /// Set to true by RivuletApp right after SentrySDK.start. When the SDK was
    /// never started (no DSN configured), every call must stay clear of
    /// SentrySDK entirely: a disabled SDK logs a fatal line per call AND lazily
    /// initializes its DependencyContainer, which touches UIApplication off the
    /// main thread (Main Thread Checker violation). Written once at startup
    /// before any meaningful traffic, so the unsynchronized access is benign.
    nonisolated(unsafe) static var isActive = false

    /// Breadcrumbs only leave the device attached to an event, so info-and-up
    /// crumbs are mirrored as logs: a session with no error is still searchable.
    /// High-frequency crumbs (per remote press) stay `.debug` to skip the mirror.
    static func addBreadcrumb(_ crumb: Breadcrumb) {
        #if !DEBUG
        guard isActive else { return }
        SentrySDK.addBreadcrumb(crumb)
        guard crumb.level.rawValue >= SentryLevel.info.rawValue else { return }
        var attributes = crumb.data ?? [:]
        attributes["category"] = crumb.category
        let level: SentryLog.Level = switch crumb.level {
        case .error, .fatal: .error
        case .warning: .warn
        default: .info
        }
        log(level, crumb.message ?? crumb.category, attributes: attributes)
        #endif
    }

    /// Structured log for failures that are not Rivulet bugs (server down,
    /// timeouts, third-party 5xx). Logs bill against their own quota and are
    /// searchable by attribute; errors are for things we can fix.
    static func log(_ level: SentryLog.Level, _ body: String, attributes: [String: Any] = [:]) {
        #if !DEBUG
        guard isActive else { return }
        switch level {
        case .error, .fatal: SentrySDK.logger.error(body, attributes: attributes)
        case .warn: SentrySDK.logger.warn(body, attributes: attributes)
        default: SentrySDK.logger.info(body, attributes: attributes)
        }
        #endif
    }

    private static let throttle = Mutex(SentryThrottle())

    /// Whether an event under `key` may still go out this launch (see `SentryThrottle`).
    static func admit(_ key: String, limit: Int = 1) -> Bool {
        throttle.withLock { $0.admit(key, limit: limit) }
    }

    /// Once per launch per distinct error: a failure that repeats reaches Sentry once.
    static func capture(error: Error, configure: ((Scope) -> Void)? = nil) {
        #if !DEBUG
        guard isActive, admit(SentryThrottle.key(for: error)) else { return }
        if let configure {
            SentrySDK.capture(error: error) { configure($0) }
        } else {
            SentrySDK.capture(error: error)
        }
        #endif
    }

    static func capture(event: Event) {
        #if !DEBUG
        guard isActive else { return }
        SentrySDK.capture(event: event)
        #endif
    }

    /// Captures `event` with files attached. Returns the event id, or nil when Sentry is not running.
    @discardableResult
    static func capture(event: Event, attachments: [Attachment]) -> String? {
        #if !DEBUG
        guard isActive else { return nil }
        return SentrySDK.capture(event: event) { scope in attachments.forEach(scope.addAttachment) }.sentryIdString
        #else
        return nil
        #endif
    }

    static func configureScope(_ configure: @escaping (Scope) -> Void) {
        #if !DEBUG
        guard isActive else { return }
        SentrySDK.configureScope(configure)
        #endif
    }

    /// Starts a performance transaction, or nil when the SDK is inactive (DEBUG or
    /// no DSN). Sampling is `options.tracesSampler` in SentryStartup: add new
    /// measured names to its 1.0 branch.
    static func startTransaction(name: String, operation: String) -> (any Span)? {
        #if !DEBUG
        guard isActive else { return nil }
        return SentrySDK.startTransaction(name: name, operation: operation)
        #else
        return nil
        #endif
    }
}
