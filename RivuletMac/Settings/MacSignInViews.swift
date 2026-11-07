// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import AppKit
import SwiftUI

/// PIN sign-in, then server choice, then the profile picker when the Plex Home has several users.
/// Parity source: IOSPlexConnectionSheet in RivuletiOS/Shell/IOSAccountViews.swift.
struct MacPlexSignInSheet: View {
    @EnvironmentObject private var plex: PlexSession
    @ObservedObject private var profiles = PlexUserProfileManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var choosingProfile = false
    @State private var lastError: String?
    @State private var connectingID: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.headline).padding(.top, 16)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    if !plex.isSignedIn { plex.cancelSignIn() }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 440, height: 400)
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
        .sheet(isPresented: $choosingProfile, onDismiss: { dismiss() }) { MacProfilePickerSheet() }
    }

    private var title: String {
        plex.state == .selectingServer ? String(localized: "Choose a Server") : String(localized: "Sign In to Plex")
    }

    @ViewBuilder
    private var content: some View {
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
                    MacServerRow(server: server, isConnecting: connectingID == server.id)
                }
                .buttonStyle(.plain)
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

    private var pinStep: some View {
        VStack(spacing: 20) {
            Text("Open plex.tv/link and sign in. If it asks for a code, enter this one.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let code = plex.pinCode {
                Text(code)
                    .font(.system(size: 48, weight: .bold, design: .monospaced))
                    .tracking(6)
                    .textSelection(.enabled)
                    .accessibilityLabel(code.map(String.init).joined(separator: " "))

                HStack(spacing: 12) {
                    if let url = plex.authenticationURL {
                        Button { openURL(url) } label: { Label("Open plex.tv/link", systemImage: "safari") }
                            .buttonStyle(.borderedProminent)
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    } label: { Label("Copy Code", systemImage: "doc.on.doc") }
                }
                .controlSize(.large)
            }

            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for you to sign in").foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(24)
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
struct MacServerRow: View {
    let server: PlexDevice
    var isCurrent = false
    var isConnecting = false

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name).foregroundStyle(.primary)
                    if server.owned == false, let owner = server.sourceTitle {
                        Text("Shared by \(owner)").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: server.owned == false ? "person.2" : "server.rack")
            }
            Spacer()
            if isConnecting {
                ProgressView().controlSize(.small)
            } else if isCurrent {
                Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// A labelled form row for an address, name or login.
struct MacFormField: View {
    enum Kind { case text, url, username, password }

    let label: LocalizedStringKey
    @Binding var text: String
    let prompt: LocalizedStringKey
    let kind: Kind

    init(_ label: LocalizedStringKey, text: Binding<String>, prompt: LocalizedStringKey, kind: Kind = .text) {
        self.label = label
        self._text = text
        self.prompt = prompt
        self.kind = kind
    }

    var body: some View {
        if kind == .password {
            SecureField(label, text: $text, prompt: Text(prompt))
        } else {
            TextField(label, text: $text, prompt: Text(prompt))
                .autocorrectionDisabled(kind != .text)
        }
    }
}

/// Jellyfin or Emby. Signed out: address, username and password (and Quick Connect where the
/// server has it). Signed in: the server, the user and Sign Out. Parity source: IOSServerSignInView.
struct MacServerSignInSheet: View {
    let server: OtherServerKind
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isChecking = false
    @State private var failure: String?
    @State private var quickConnectCode: String?
    @State private var quickConnectTask: Task<Void, Never>?
    /// Bumped after a sign-in or sign-out, so the page re-reads the stored account.
    @State private var revision = 0
    @State private var confirmingSignOut = false

    private var name: String { server.kind.displayName }

    var body: some View {
        let _ = revision
        VStack(spacing: 0) {
            Form {
                if let account = server.account() {
                    signedInSections(account)
                } else {
                    signInSections
                }
            }
            .formStyle(.grouped)
            .disabled(isChecking)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 420)
        .alert("Couldn’t Sign In", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
        .alert(quickConnectCode ?? "", isPresented: Binding(get: { quickConnectCode != nil },
                                                             set: { if !$0 { quickConnectCode = nil } })) {
            Button("Cancel", role: .cancel) { quickConnectTask?.cancel() }
        } message: {
            Text("On a device signed in to \(name), open Settings, choose Quick Connect and enter this code.")
        }
        .onDisappear { quickConnectTask?.cancel() }
    }

    @ViewBuilder
    private func signedInSections(_ account: (providerID: String, name: String)) -> some View {
        let synced = CloudSync.shared.isSynced(accountID: account.providerID)
        Section(name) {
            LabeledContent("Server", value: account.name)
            if let user = server.userName(), !user.isEmpty {
                LabeledContent("User", value: user)
            }
        }
        Section {
            Button("Sign Out…", role: .destructive) { confirmingSignOut = true }
                .confirmationDialog("Sign out of \(name)?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                    if synced {
                        Button("This Device Only") { signOut(.thisDevice) }
                        Button("All Devices", role: .destructive) { signOut(.everywhere) }
                    } else {
                        Button("Sign Out", role: .destructive) { signOut(nil) }
                    }
                } message: {
                    if synced {
                        Text("Your \(name) sign-in is shared through iCloud. Sign out of this device only, or of every device?")
                    } else {
                        Text("You can sign back in at any time.")
                    }
                }
        }
    }

    @ViewBuilder private var signInSections: some View {
        Section {
            MacFormField("Address", text: $address, prompt: "Required", kind: .url)
        } header: {
            Text("\(name) Server")
        } footer: {
            Text("Your \(name) server's address, with its port.")
        }
        Section {
            MacFormField("Username", text: $username, prompt: "Required", kind: .username)
            MacFormField("Password", text: $password, prompt: "None", kind: .password)
        } footer: {
            Text("Leave the password empty if the user has none.")
        }
        Section {
            HStack {
                Button(action: signIn) {
                    if isChecking, quickConnectTask == nil {
                        ProgressView().controlSize(.small)
                        Text("Signing In…")
                    } else {
                        Text("Sign In")
                    }
                }
                .keyboardShortcut(.defaultAction)
                if server.quickConnect != nil {
                    Button("Quick Connect", action: startQuickConnect)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func signOut(_ scope: SignOutScope?) {
        Task {
            await server.signOut(scope)
            revision += 1
        }
    }

    private var serverURL: URL? { URL(string: sanitizeURL(address)) }

    private func signIn() {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = serverURL, !user.isEmpty else {
            failure = String(localized: "Enter your server's address and your username.")
            return
        }
        isChecking = true
        Task {
            defer { isChecking = false }
            do {
                try await server.signIn(url, user, password)
                password = ""
                revision += 1
            } catch {
                failure = server.failureMessage(error)
            }
        }
    }

    private func startQuickConnect() {
        guard let quickConnect = server.quickConnect else { return }
        guard let url = serverURL else {
            failure = String(localized: "Enter your server's address.")
            return
        }
        isChecking = true
        quickConnectTask = Task {
            defer {
                isChecking = false
                quickConnectCode = nil
                quickConnectTask = nil
            }
            do {
                try await quickConnect(url) { quickConnectCode = $0 }
                revision += 1
            } catch where isCancellationError(error) {
            } catch {
                // One alert at a time: the code alert goes before the failure shows.
                quickConnectCode = nil
                failure = server.quickConnectFailureMessage(error)
            }
        }
    }
}
