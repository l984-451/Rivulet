// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ConnectionAlert.swift
//  Rivulet
//
//  How the app says "the server is gone": cached content keeps rendering and a
//  popup says so once per outage (`presentOnceIfOffline`). A modal, not a
//  banner, so the layout never shifts. `allowPlayback` gates playback only.
//

import UIKit

/// Once-per-outage gate for the unprompted popup. A pure value type so the
/// state machine is testable without a device.
struct ConnectionAlertGate {

    private(set) var hasShown = false

    /// True the first time we go offline, then false while we stay offline —
    /// a flapping connection must not stack popups. Reconnecting re-arms it,
    /// so a second outage later in the session is announced again.
    mutating func shouldPresent(isConnected: Bool) -> Bool {
        if isConnected {
            hasShown = false
            return false
        }
        guard !hasShown else { return false }
        hasShown = true
        return true
    }
}

@MainActor
enum ConnectionAlert {

    private static var gate = ConnectionAlertGate()

    /// Unprompted popup for a connection that just dropped. No-op while
    /// connected, while signed out (`HomeStateView.notConnected` covers that
    /// case with its own full-screen prompt), or once this outage has already
    /// been announced.
    static func presentOnceIfOffline(from presenter: UIViewController) {
        let auth = PlexAuthManager.shared
        guard auth.hasCredentials else { return }
        guard gate.shouldPresent(isConnected: auth.isConnected) else { return }
        present(from: presenter, retry: nil)
    }

    /// Gate for anything that needs a live server. Returns true when the
    /// caller may proceed; when offline it shows the popup and returns false.
    /// A Retry that reconnects runs `retry`, so the user doesn't have to find
    /// the item and press Play a second time.
    static func allowPlayback(from presenter: UIViewController,
                              retry: (() -> Void)? = nil) -> Bool {
        guard !PlexAuthManager.shared.isConnected else { return true }
        present(from: presenter, retry: retry)
        return false
    }

    private static func present(from presenter: UIViewController, retry: (() -> Void)?) {
        let host = presenter.topmostPresented
        // Never stack two of these — a flap and a double Play press both get here.
        guard !(host is ConfirmationPopupViewController) else { return }

        let name = PlexAuthManager.shared.savedServerName ?? String(localized: "your Plex server")
        let popup = ConfirmationPopupViewController(
            title: String(localized: "Can't Reach Your Server"),
            message: String(localized: "Rivulet can't connect to \(name). Check that the server is running and your network is connected. Recently loaded content is still available to browse."),
            confirmTitle: String(localized: "Retry"),
            cancelTitle: String(localized: "OK"),
            onConfirm: { retryConnection(from: presenter, then: retry) }
        )
        host.present(popup, animated: true)
    }

    /// `onConfirm` fires from the popup's dismiss completion, so the card is
    /// already gone by the time we get here and re-presenting on a failed
    /// retry is safe.
    private static func retryConnection(from presenter: UIViewController,
                                        then retry: (() -> Void)?) {
        Task { @MainActor in
            await PlexAuthManager.shared.verifyAndFixConnection()
            guard PlexAuthManager.shared.isConnected else {
                present(from: presenter, retry: retry)
                return
            }
            NotificationCenter.default.post(name: .plexDataNeedsRefresh, object: nil)
            retry?()
        }
    }
}

extension UIViewController {
    /// The controller actually on screen above this one. Presenting onto a
    /// covered controller silently does nothing.
    var topmostPresented: UIViewController {
        var top = self
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}
