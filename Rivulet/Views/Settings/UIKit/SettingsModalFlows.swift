// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SettingsModalFlows.swift
//  Rivulet
//
//  Thin SwiftUI wrappers presented as focus-contained modals FROM the UIKit
//  Settings pages (same proven pattern as the Plex sign-in modal). What's left
//  here reuses the existing, working SwiftUI numeric PIN pad. Each takes an
//  explicit `onClose` so dismissal is deterministic (the host VC dismisses the
//  presentation and reloads its row list). Presented modals live outside the
//  sidebar shell, so the focus wedge does not apply here.
//
//  The add-source forms used to live here too; they are now real UIKit pages in
//  the settings stack (`AddLiveTVSourceContent.swift`).
//

import SwiftUI

// MARK: - Profile PIN entry

/// Wraps `PinEntrySheet` with verify-and-switch logic. Calls `onClose` on
/// success or cancel; shows an inline error on a wrong PIN.
struct ProfilePinFlow: View {
    let user: PlexHomeUser
    let onClose: () -> Void

    @StateObject private var profileManager = PlexUserProfileManager.shared
    @State private var error: String?

    init(user: PlexHomeUser, initialError: String?, onClose: @escaping () -> Void) {
        self.user = user
        self.onClose = onClose
        _error = State(initialValue: initialError)
    }

    var body: some View {
        PinEntrySheet(
            user: user,
            error: $error,
            onSubmit: { pin, rememberPin in
                Task {
                    let success = await profileManager.selectUser(user, pin: pin)
                    if success {
                        if rememberPin { profileManager.rememberPin(pin, for: user) }
                        onClose()
                    } else {
                        error = "Incorrect PIN. Please try again."
                    }
                }
            },
            onCancel: onClose
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.6))
    }
}
