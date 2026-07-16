//
//  SentryBridge.swift
//  Rivulet
//
//  Thin wrapper around SentrySDK that silently no-ops in DEBUG builds.
//  The SDK is never started in debug, so calling it directly generates
//  console noise for every breadcrumb and capture call.
//

import Sentry

// `nonisolated` on purpose. The project compiles with MainActor default
// isolation, so without this the whole enum is inferred @MainActor — which made
// every capture from a non-isolated async context (the Live TV providers, any
// URLSession continuation) an actor hop, and a hard error under full Swift 6.
// SentrySDK is internally thread-safe and explicitly documented as callable
// from any thread, so binding it to the main actor buys nothing and costs a hop
// on the error path, which is exactly where we least want to perturb timing.
nonisolated enum SentryBridge {
    /// Set to true by RivuletApp right after SentrySDK.start. When the SDK was
    /// never started (no DSN configured), every call must stay clear of
    /// SentrySDK entirely: a disabled SDK logs a fatal line per call AND lazily
    /// initializes its DependencyContainer, which touches UIApplication off the
    /// main thread (Main Thread Checker violation). Written once at startup
    /// before any meaningful traffic, so the unsynchronized access is benign.
    nonisolated(unsafe) static var isActive = false

    static func addBreadcrumb(_ crumb: Breadcrumb) {
        #if !DEBUG
        guard isActive else { return }
        SentrySDK.addBreadcrumb(crumb)
        #endif
    }

    static func capture(error: Error, configure: ((Scope) -> Void)? = nil) {
        #if !DEBUG
        guard isActive else { return }
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

    static func configureScope(_ configure: @escaping (Scope) -> Void) {
        #if !DEBUG
        guard isActive else { return }
        SentrySDK.configureScope(configure)
        #endif
    }
}
