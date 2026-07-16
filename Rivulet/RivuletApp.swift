//
//  RivuletApp.swift
//  Rivulet
//
//  Created by Bain Gurley on 11/28/25.
//

import SwiftUI
import SwiftData
import Sentry

// MARK: - App Delegate

class RivuletAppDelegate: NSObject, UIApplicationDelegate {

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        Task {
            await DeepLinkHandler.shared.handle(url: url)
        }
        return true
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([any UIUserActivityRestoring]?) -> Void) -> Bool {
        guard let ratingKey = userActivity.userInfo?["ratingKey"] as? String,
              !ratingKey.isEmpty else { return false }

        switch userActivity.activityType {
        case "com.rivulet.viewMedia":
            Task {
                await DeepLinkHandler.shared.handle(
                    url: URL(string: "rivulet://detail?ratingKey=\(ratingKey)")!
                )
            }
            return true
        case "com.rivulet.playMedia":
            Task {
                await DeepLinkHandler.shared.handle(
                    url: URL(string: "rivulet://play?ratingKey=\(ratingKey)")!
                )
            }
            return true
        default:
            return false
        }
    }
}

// MARK: - App

@main
struct RivuletApp: App {
    @UIApplicationDelegateAdaptor(RivuletAppDelegate.self) var appDelegate

    init() {
        StartupTimer.arm()
        StartupTimer.mark("RivuletApp.init")
        // Default the Home hero ON for fresh installs (and any user who hasn't
        // explicitly toggled it). The home reads this via UserDefaults.bool(),
        // which returns false for an unset key, so register the default here
        // before any read. An explicit user choice still wins.
        UserDefaults.standard.register(defaults: ["showHomeHero": true])
        #if !DEBUG
        // Sentry start is DEFERRED off the launch window. Starting it in init()
        // fired envelope/session uploads to sentry.io before the network nexus
        // was ready — every cold launch spammed `NECP [22: Invalid argument]`
        // / `-1000 bad URL` failures (visible in release device logs) AND paid
        // its swizzling + session-tracking cost on the critical path. A few
        // seconds later the network is up, the uploads succeed, and the launch
        // window is clean. Trade-off: a crash in the first ~3s is not captured
        // (rare; acceptable given the launch-perf + log-noise win).
        Task.detached(priority: .utility) {
            // No DSN configured (Secrets.swift is local-only) — skip Sentry
            // entirely rather than initializing a dead SDK. SentryBridge stays
            // inactive so breadcrumb/capture calls no-op instead of spamming
            // "SDK is disabled" fatals.
            guard !Secrets.sentryDSN.isEmpty else { return }
            try? await Task.sleep(for: .seconds(3))
            SentrySDK.start { options in
                options.dsn = Secrets.sentryDSN
                options.debug = false
                options.tracesSampleRate = 1.0
                options.attachStacktrace = true
                options.enableAutoSessionTracking = true
                options.enableCaptureFailedRequests = true
                options.enableSwizzling = true
                // App Hang tracking. On tvOS the SDK uses ANR Tracker V2
                // unconditionally (no `enableAppHangTrackingV2` toggle exists
                // in 9.x — it was made GA and removed), which snapshots ALL
                // threads with stack traces at the moment the watchdog fires.
                // This is what backs RIVULET-41. The reason that issue's
                // in-app frames show as <unknown> is missing/mismatched dSYMs
                // for the release, NOT a tracker-version problem — ensure
                // dSYMs upload for each App Store build so the frames resolve.
                options.enableAppHangTracking = true
                options.appHangTimeoutInterval = 2
                // Also report non-fully-blocking hangs (partial main-thread
                // stalls), not just fully-blocked ones. Defaults true in 9.x;
                // set explicitly so a future SDK default flip can't silence them.
                options.enableReportNonFullyBlockingAppHangs = true

                options.beforeSend = { event in
                    // Drop cancelled URL request errors — these are normal when navigating away
                    if let exceptions = event.exceptions,
                       exceptions.contains(where: { $0.value?.contains("Code=-999") == true || $0.value?.contains("cancelled") == true }) {
                        return nil
                    }
                    if let message = event.message?.formatted,
                       message.contains("Code=-999") || (message.contains("NSURLErrorDomain") && message.contains("cancelled")) {
                        return nil
                    }
                    // Plex passes `X-Plex-Token` as a URL query parameter, and
                    // IPTV providers pass username/password the same way, so any
                    // URL that reaches an event carries a live credential. Call
                    // sites use SensitiveDataRedactor directly, but this hook is
                    // the actual guarantee: it also covers events the SDK builds
                    // itself (enableCaptureFailedRequests attaches the failing
                    // request URL) and NSError descriptions with an embedded URL,
                    // neither of which any call site can reach.
                    return SentryEventRedaction.redact(event)
                }
            }
            SentryBridge.isActive = true

            // Seed the App Hang triage scope so the very first hang event after
            // launch already carries a screen tag. Updated thereafter via
            // AppHangContext as the user navigates and plays. See RIVULET-41.
            await MainActor.run {
                AppHangContext.setScreen("launch")
            }
        }
        #endif

        // NowPlayingService disabled — AVPlayerViewController handles Now Playing natively.
        // NowPlayingService.shared.initialize()

        // Emit the AppLaunch perf event so launch time, memory, and scroll
        // smoothness can be correlated in Instruments traces.
        Task { @MainActor in
            Perf.event(.appLaunch, message: "init")
        }
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            ServerConfiguration.self,
            PlexServer.self,
            IPTVSource.self,
            Channel.self,
            FavoriteChannel.self,
            WatchProgress.self,
            EPGProgram.self,
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(MediaProviderRegistry.shared)
                .environment(MusicProviderRegistry.shared)
                .environment(MetadataSourceRegistry.shared)
        }
        .modelContainer(sharedModelContainer)
    }
}
