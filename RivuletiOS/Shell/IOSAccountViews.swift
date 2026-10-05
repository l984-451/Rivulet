// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI
import UIKit

/// Signed-out call to action shown in place of content.
struct IOSPlexConnectView: View {
    @State private var showingSignIn = false

    var body: some View {
        ContentUnavailableView {
            Label("Sign In to Plex", systemImage: "person.crop.circle")
        } description: {
            Text("Sign in to watch your Plex libraries on iPhone and iPad.")
        } actions: {
            Button("Sign In") { showingSignIn = true }
                .buttonStyle(.borderedProminent)
        }
        .sheet(isPresented: $showingSignIn) { IOSPlexConnectionSheet() }
    }
}

struct IOSPlexAccountAvatar: View {
    let url: URL?
    var size: CGFloat = 44

    var body: some View {
        IOSShellArtwork(url: url) {
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.45))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.thinMaterial)
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .overlay { Circle().strokeBorder(.separator, lineWidth: 0.5) }
        .accessibilityHidden(true)
    }
}

/// A remote image through `IOSArtworkCache`, with a placeholder until it loads.
struct IOSShellArtwork<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            image = nil
            guard let url, let loaded = await IOSArtworkCache.shared.image(for: url), !Task.isCancelled else { return }
            image = loaded
        }
    }
}

extension PlexHomeUser {
    /// plex.tv serves Home avatars as absolute URLs.
    var avatarURL: URL? { thumb.flatMap(URL.init(string:)) }
}

// MARK: - Sign in

/// PIN sign-in, then server choice, then the profile picker when the Plex Home has several users.
struct IOSPlexConnectionSheet: View {
    @EnvironmentObject private var plex: IOSPlexSession
    @ObservedObject private var profiles = PlexUserProfileManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .largeTitle) private var codeSize: CGFloat = 52
    @State private var choosingProfile = false
    @State private var lastError: String?
    @State private var connectingID: String?

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) {
                            if !plex.isConfigured { plex.cancelSignIn() }
                            dismiss()
                        }
                    }
                }
        }
        .task {
            if plex.state == .signedOut { await plex.retrySignIn() }
        }
        .onChange(of: plex.state) { _, state in
            switch state {
            case .failed(let message):
                lastError = message
            case .requestingPIN, .waitingForPIN, .findingServers, .selectingServer:
                lastError = nil
            case .connected:
                if profiles.hasMultipleProfiles { choosingProfile = true } else { dismiss() }
            case .signedOut:
                break
            }
        }
    }

    private var title: String {
        if choosingProfile { return "Who’s Watching?" }
        return plex.state == .selectingServer ? "Choose a Server" : "Sign In"
    }

    @ViewBuilder
    private var content: some View {
        if choosingProfile {
            IOSProfilePicker()
        } else {
            switch plex.state {
            case .waitingForPIN:
                pinStep
            case .selectingServer:
                List(plex.availableServers) { server in
                    Button {
                        connectingID = server.id
                        Task {
                            await plex.selectServer(server)
                            connectingID = nil
                        }
                    } label: {
                        IOSServerRow(server: server, isConnecting: connectingID == server.id)
                    }
                    .disabled(connectingID != nil)
                }
            case .failed(let message):
                failure(message)
            case .signedOut where lastError != nil:
                failure(lastError ?? "")
            case .connected:
                ContentUnavailableView("Signed In", systemImage: "checkmark.circle.fill")
            default:
                ProgressView()
            }
        }
    }

    private var pinStep: some View {
        ScrollView {
            VStack(spacing: 28) {
                Text("Open plex.tv/link and sign in. If it asks for a code, enter this one.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let code = plex.pinCode {
                    Text(code)
                        .font(.system(size: codeSize, weight: .bold, design: .monospaced))
                        .tracking(codeSize * 0.12)
                        .textSelection(.enabled)
                        .accessibilityLabel(code.map(String.init).joined(separator: " "))

                    VStack(spacing: 12) {
                        if let url = plex.authenticationURL {
                            Button { openURL(url) } label: {
                                Label("Open plex.tv/link", systemImage: "safari")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glassProminent)
                        }
                        Button { UIPasteboard.general.string = code } label: {
                            Label("Copy Code", systemImage: "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }
                    .controlSize(.large)
                    .frame(maxWidth: 360)
                }

                HStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for you to sign in")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private func failure(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn’t Sign In", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { Task { await plex.retrySignIn() } }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// A Plex server with a checkmark when current and a spinner while connecting.
struct IOSServerRow: View {
    let server: PlexDevice
    var isCurrent = false
    var isConnecting = false

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name).foregroundStyle(.primary)
                    if server.owned == false, let owner = server.sourceTitle {
                        Text("Shared by \(owner)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: server.owned == false ? "person.2" : "server.rack")
            }
            Spacer()
            if isConnecting {
                ProgressView()
            } else if isCurrent {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

// MARK: - Profiles

/// Plex Home profile grid. Dismisses its presentation (or pops its page) once a profile is chosen.
struct IOSProfilePicker: View {
    @ObservedObject private var profiles = PlexUserProfileManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var switchingID: Int?
    @State private var pinUser: PlexHomeUser?
    @State private var pinError: String?
    @State private var didSwitch = false
    @State private var switchFailed = false

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 20)], spacing: 24) {
                ForEach(profiles.homeUsers) { user in
                    Button { select(user) } label: { tile(user) }
                        .buttonStyle(.plain)
                        .disabled(switchingID != nil)
                }
            }
            .padding(20)
        }
        .sheet(item: $pinUser, onDismiss: { if didSwitch { dismiss() } }) { user in
            IOSProfilePINEntry(user: user, initialError: pinError) { pin, remember in
                await verify(user, pin: pin, remember: remember)
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
            IOSPlexAccountAvatar(url: user.avatarURL, size: 80)
                .overlay {
                    if switchingID == user.id {
                        Circle().fill(.black.opacity(0.35))
                        ProgressView().tint(.white)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isSelected {
                        badge("checkmark.circle.fill", color: .accentColor)
                    } else if user.requiresPin {
                        badge("lock.circle.fill", color: .gray)
                    }
                }
            Text(user.displayName)
                .font(.subheadline)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(user.requiresPin ? "\(user.displayName), requires PIN" : user.displayName)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func badge(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.title2)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, color)
            .background(Circle().fill(.background).padding(2))
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
                pinError = result.pinWasInvalid ? "Your saved PIN no longer works. Enter it again." : nil
                pinUser = user
            }
        }
    }

    private func verify(_ user: PlexHomeUser, pin: String, remember: Bool) async -> Bool {
        switchingID = user.id
        defer { switchingID = nil }
        guard await profiles.selectUser(user, pin: pin) else { return false }
        if remember { profiles.rememberPin(pin, for: user) }
        didSwitch = true
        return true
    }
}

/// Numeric PIN entry for a protected profile. Plex PINs are four digits, so the fourth submits.
private struct IOSProfilePINEntry: View {
    let user: PlexHomeUser
    let initialError: String?
    let submit: (String, Bool) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var remember = false
    @State private var error: String?
    @State private var isWorking = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("PIN", text: $pin)
                        .keyboardType(.numberPad)
                        .focused($focused)
                        .disabled(isWorking)
                        .onChange(of: pin) { _, value in
                            if value.count == 4 { send() }
                        }
                } header: {
                    Text("PIN for \(user.displayName)")
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Toggle("Remember PIN", isOn: $remember)
                } footer: {
                    Text("Stored in this device’s keychain so this profile opens without asking.")
                }
            }
            .navigationTitle("Enter PIN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button(role: .confirm) { send() }
                            .disabled(pin.isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            error = initialError
            focused = true
        }
    }

    private func send() {
        guard !isWorking, !pin.isEmpty else { return }
        isWorking = true
        Task {
            let ok = await submit(pin, remember)
            isWorking = false
            if ok {
                dismiss()
            } else {
                error = "Incorrect PIN. Try again."
                pin = ""
                focused = true
            }
        }
    }
}
