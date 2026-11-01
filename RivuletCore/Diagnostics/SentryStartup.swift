// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SentryStartup.swift
//  RivuletCore
//
//  The one Sentry configuration for both apps: the tracesSampler and the
//  beforeSend credential scrubbing must hold on each. Callers own deferral and
//  DEBUG gating.
//

import Sentry

public enum SentryStartup {
    /// Which app sent the event (both report into one project). Passed in by the
    /// caller: no `#if os` here, and `UIDevice.systemName` splits iPads across
    /// "iOS" and "iPadOS".
    public enum Platform: String {
        case tvOS
        case iOS
    }

    /// MUST be main-actor isolated: `SentrySDK.start` builds the SDK's
    /// dependency container, which reads `UIApplication.applicationState` and
    /// installs swizzling plus session / app-hang tracking. Called off the main
    /// actor it trips the Main Thread Checker on every launch.
    @MainActor
    public static func start(platform: Platform) {
        SentrySDK.start { options in
            options.dsn = Secrets.sentryDSN
            options.debug = false
            // Initial scope, so startup events carry the tag. It tags without
            // splitting grouping: a shared-code crash stays one issue.
            options.initialScope = { scope in
                scope.setTag(value: platform.rawValue, key: "platform")
                return scope
            }
            // Measured transactions at 1.0, everything else at 0.05. Swizzling
            // emits a transaction per view appearance and request, and a full
            // quota makes Sentry drop spans server-side, biasing the named ones.
            options.tracesSampler = { context in
                ["live.join", "live.av"].contains(context.transactionContext.name)
                    ? NSNumber(value: 1.0)
                    : NSNumber(value: 0.05)
            }
            // Only consulted if the sampler ever returns nil.
            options.tracesSampleRate = 0.05
            options.attachStacktrace = true
            options.enableAutoSessionTracking = true
            // Off: it filed every 5xx from any host (IPTV proxies, picons, Plex
            // part fetches) as an error, ~1/4 of the error quota. Our own
            // request paths log what they need.
            options.enableCaptureFailedRequests = false
            options.enableSwizzling = true
            options.beforeSendSpan = { SentryEventRedaction.redact($0) }
            // Default is every host: no trace headers to Plex, IPTV or Jellyfin servers.
            options.tracePropagationTargets = []
            // Logs skip beforeSend, so they get their own scrub.
            options.enableLogs = true
            options.beforeSendLog = { SentryEventRedaction.redact($0) }
            // Every crumb, SDK-made ones (network, screens) included, also goes to the diagnostics log.
            options.beforeBreadcrumb = { crumb in
                DiagLog.mirror(crumb)
                return crumb
            }
            // App Hang tracking (ANR Tracker V2 on tvOS, no toggle in 9.x).
            // <unknown> in-app frames mean missing dSYMs for that build.
            options.enableAppHangTracking = true
            options.appHangTimeoutInterval = 2
            // Also report non-fully-blocking hangs (partial main-thread
            // stalls), not just fully-blocked ones. Defaults true in 9.x;
            // set explicitly so a future SDK default flip can't silence them.
            options.enableReportNonFullyBlockingAppHangs = true

            options.beforeSend = { event in
                // Drop cancelled URL request errors — these are normal when
                // navigating away. "CancellationError" is listed explicitly:
                // Swift's structured-concurrency error stringifies as
                // "CancellationError()", which matches neither "Code=-999"
                // nor the lowercase double-l "cancelled" (RIVULET-19). This
                // is a backstop; the real fix is not raising the event.
                func isCancellationText(_ text: String) -> Bool {
                    text.contains("Code=-999")
                        || text.contains("cancelled")
                        || text.contains("CancellationError")
                }
                if let exceptions = event.exceptions,
                   exceptions.contains(where: { isCancellationText($0.value ?? "") }) {
                    return nil
                }
                if let message = event.message?.formatted,
                   message.contains("Code=-999")
                    || message.contains("CancellationError")
                    || (message.contains("NSURLErrorDomain") && message.contains("cancelled")) {
                    return nil
                }
                // Plex tokens and IPTV credentials ride in URL queries. This hook
                // covers SDK-built events and NSError URLs no call site can reach.
                return SentryEventRedaction.redact(event)
            }
        }
        SentryBridge.isActive = true
    }
}
