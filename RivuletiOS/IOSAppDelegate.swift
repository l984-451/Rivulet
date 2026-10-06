// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit

/// Only here for background download events; launch stays in `RivuletiOSApp.init`.
final class IOSAppDelegate: NSObject, UIApplicationDelegate {
    private static var pendingCompletion: (() -> Void)?
    /// The session is created at launch, so its events can finish before the handler arrives.
    private static var finishedEarly = false

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == IOSDownloadTransfer.sessionIdentifier else { return completionHandler() }
        // `shared` recreates the session, which reattaches its tasks.
        _ = IOSDownloadTransfer.shared
        if Self.finishedEarly {
            Self.finishedEarly = false
            completionHandler()
        } else {
            Self.pendingCompletion = completionHandler
        }
    }

    /// The download session delivered every queued event.
    static func backgroundEventsFinished() {
        guard let completion = pendingCompletion else { return finishedEarly = true }
        pendingCompletion = nil
        completion()
    }
}
