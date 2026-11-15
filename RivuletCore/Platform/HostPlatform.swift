// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Foundation

/// What differs per platform, injected by each app at launch before any store starts.
/// Shared code reads these instead of naming UIKit or AppKit.
@MainActor
enum HostPlatform {
    /// Posted when the app comes back to the front; stores refresh stale data on it.
    /// The default is UIKit's name, so tvOS and iOS work even before `install`.
    static var willEnterForeground = Notification.Name("UIApplicationWillEnterForegroundNotification")
    /// Posts that change `isForeground` or `allowsVideoPreviews`.
    static var appearanceChangeNotifications: [Notification.Name] = []
    static var isForeground: () -> Bool = { true }
    /// The system's video-preview and Reduce Motion settings allow a looping backdrop.
    static var allowsVideoPreviews: () -> Bool = { true }
    /// The alternate app icon in use; nil is the primary.
    static var alternateIconName: () -> String? = { nil }
    static var setAlternateIconName: (String?) -> Void = { _ in }
}
