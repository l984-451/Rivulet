// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// Who's Watching: the gate shown while the Plex Home needs a profile. Port of IOSProfilePicker.
struct MacProfilePickerSheet: View {
    @ObservedObject private var profiles = PlexUserProfileManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var switchingID: Int?
    @State private var pinUser: PlexHomeUser?
    @State private var pinError: String?
    @State private var switchFailed = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Who’s Watching?").font(.title2.bold())
            if profiles.homeUsers.isEmpty {
                ContentUnavailableView {
                    Label("Couldn’t Load Profiles", systemImage: "person.2.slash")
                } actions: {
                    Button("Try Again") { Task { await profiles.fetchHomeUsers() } }
                        .disabled(profiles.isLoadingUsers)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 20)], spacing: 24) {
                    ForEach(profiles.homeUsers) { user in
                        Button { select(user) } label: { tile(user) }
                            .buttonStyle(.plain)
                            .disabled(switchingID != nil)
                    }
                }
            }
        }
        .padding(28)
        .frame(width: 520, height: 380)
        .sheet(item: $pinUser) { user in
            MacProfilePINEntry(user: user, initialError: pinError) { pin, remember in
                switchingID = user.id
                defer { switchingID = nil }
                guard await profiles.selectUser(user, pin: pin) else { return false }
                if remember { profiles.rememberPin(pin, for: user) }
                dismiss()
                return true
            }
        }
        .alert("Couldn’t Switch Profile", isPresented: $switchFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check your connection and try again.")
        }
    }

    private func tile(_ user: PlexHomeUser) -> some View {
        let isSelected = profiles.selectedUser?.id == user.id
        return VStack(spacing: 8) {
            MacAccountAvatar(url: user.avatarURL, size: 80)
                .overlay {
                    if switchingID == user.id { ProgressView().controlSize(.small) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Color.accentColor)
                    } else if user.requiresPin {
                        Image(systemName: "lock.circle.fill").foregroundStyle(.white, .gray)
                    }
                }
                .macTileHover()
            Text(user.displayName).font(.subheadline).lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(user.requiresPin ? String(localized: "\(user.displayName), requires PIN") : user.displayName)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func select(_ user: PlexHomeUser) {
        if profiles.selectedUser?.id == user.id {
            dismiss()
            return
        }
        guard user.requiresPin else {
            Task {
                switchingID = user.id
                let ok = await profiles.selectUser(user)
                switchingID = nil
                if ok { dismiss() } else { switchFailed = true }
            }
            return
        }
        guard profiles.hasRememberedPin(for: user) else {
            pinError = nil
            pinUser = user
            return
        }
        Task {
            switchingID = user.id
            let result = await profiles.selectUserWithRememberedPin(user)
            switchingID = nil
            if result.success {
                dismiss()
            } else {
                pinError = result.pinWasInvalid ? String(localized: "Your saved PIN no longer works. Enter it again.") : nil
                pinUser = user
            }
        }
    }
}

/// PIN entry for a protected profile. Plex PINs are four digits, so the fourth submits.
private struct MacProfilePINEntry: View {
    let user: PlexHomeUser
    let initialError: String?
    let submit: (String, Bool) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var remember = false
    @State private var error: String?
    @State private var isWorking = false

    var body: some View {
        Form {
            Section {
                SecureField("PIN", text: $pin)
                    .disabled(isWorking)
                    .onChange(of: pin) { _, value in
                        let digits = String(value.filter(\.isNumber).prefix(4))
                        if digits != value { pin = digits }
                        if digits.count == 4, digits == value { send() }
                    }
                Toggle("Remember PIN on this Mac", isOn: $remember)
            } header: {
                Text("Enter the PIN for \(user.displayName)")
            } footer: {
                if let error = error ?? initialError { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 360, height: 240)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }

    private func send() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            let ok = await submit(pin, remember)
            isWorking = false
            if ok {
                dismiss()
            } else {
                error = String(localized: "That PIN didn’t work.")
                pin = ""
            }
        }
    }
}

/// Call to action shown in place of content when no server is signed in, or the Plex Home
/// is waiting on a profile.
struct MacSignInLanding: View {
    @EnvironmentObject private var plex: PlexSession
    @ObservedObject private var profiles = PlexUserProfileManager.shared
    @State private var showingSignIn = false
    @State private var choosingProfile = false

    var body: some View {
        Group {
            if plex.isSignedIn, !profiles.needsProfileSelection {
                // plex.tv is still being asked to let the saved profile in.
                ProgressView()
            } else if plex.isSignedIn {
                ContentUnavailableView {
                    Label("Who’s Watching?", systemImage: "person.2")
                } description: {
                    Text("Choose a profile to load your Plex libraries.")
                } actions: {
                    Button("Choose Profile") { choosingProfile = true }.buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView {
                    Label("Sign In to Plex", systemImage: "person.crop.circle")
                } description: {
                    Text("Sign in to watch your Plex libraries on your Mac.")
                } actions: {
                    Button("Sign In") { showingSignIn = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(isPresented: $choosingProfile) { MacProfilePickerSheet() }
        .sheet(isPresented: $showingSignIn) { MacPlexSignInSheet() }
    }
}
