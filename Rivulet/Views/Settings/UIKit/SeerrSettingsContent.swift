// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Settings > Servers > Seerr: the server address and API key behind Search's Request row and
// the detail page's Request button.

import UIKit

extension SettingsContent {
    static var seerr: [SettingsRowItem] {
        var rows = [
            SettingsRowItem(
                id: "seerrAddress", title: "Server Address",
                kind: .textEntry(value: { SeerrSettings.serverAddress },
                                 placeholder: String(localized: "Server Address"),
                                 hint: nil, suggestions: [], keyboardType: .URL,
                                 set: { SeerrSettings.serverAddress = $0 })),
            SettingsRowItem(
                id: "seerrAPIKey", title: "API Key",
                kind: .textEntry(value: { SeerrSettings.apiKey },
                                 placeholder: String(localized: "API Key"),
                                 hint: nil, suggestions: [], keyboardType: .asciiCapable, isSecure: true,
                                 set: { SeerrSettings.apiKey = $0 })),
            SettingsRowItem(
                id: "seerrCheck", title: "Check Connection",
                kind: .action(destructive: false, handler: { vc in checkSeerr(from: vc) }))
        ]
        if !SeerrSettings.serverAddress.isEmpty || !SeerrSettings.apiKey.isEmpty {
            rows.append(SettingsRowItem(
                id: "seerrRemove", title: "Remove Seerr",
                kind: .action(destructive: true, handler: { vc in
                    vc.present(ConfirmationPopupViewController(
                        title: String(localized: "Remove Seerr?"),
                        message: String(localized: "Search stops showing titles to request. Seerr itself is unchanged."),
                        confirmTitle: String(localized: "Remove"),
                        destructive: true,
                        onConfirm: {
                            SeerrSettings.clear()
                            (vc as? SettingsPageViewController)?.reloadRows()
                        }), animated: true)
                })))
        }
        return rows
    }

    /// The Servers page row's value: the server, or Off.
    static var seerrServerValue: String {
        SeerrSettings.isConfigured ? SeerrSettings.displayHost : String(localized: "Off")
    }

    private static func checkSeerr(from vc: UIViewController) {
        guard let client = SeerrClient.configured else {
            showSeerrResult(title: String(localized: "Seerr Isn’t Set Up"),
                            message: String(localized: "Enter the server address and an API key first."),
                            from: vc)
            return
        }
        Task {
            do {
                let info = try await client.check()
                showSeerrResult(title: String(localized: "Connected"),
                                message: String(localized: "Seerr \(info.version), signed in as \(info.user). Search now shows titles you can request."),
                                from: vc)
            } catch {
                showSeerrResult(title: String(localized: "Couldn’t Connect"),
                                message: error.localizedDescription, from: vc)
            }
            (vc as? SettingsPageViewController)?.reloadRows()
        }
    }

    private static func showSeerrResult(title: String, message: String, from vc: UIViewController) {
        guard vc.presentedViewController == nil else { return }
        vc.present(ConfirmationPopupViewController(
            title: title, message: message, confirmTitle: String(localized: "OK"),
            cancelTitle: nil, onConfirm: {}), animated: true)
    }
}
