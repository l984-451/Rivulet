// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Account > a Jellyfin or Emby server. Signed out: address, username and password
/// (and Quick Connect where the server has it). Signed in: the server, the user and Sign Out.
struct IOSServerSignInView: View {
    let server: OtherServerKind
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
        Form {
            if let account = server.account() {
                let synced = CloudSync.shared.isSynced(accountID: account.providerID)
                Section {
                    LabeledContent("Server", value: account.name)
                    if let user = server.userName(), !user.isEmpty {
                        LabeledContent("User", value: user)
                    }
                }
                Section {
                    Button("Sign Out", role: .destructive) { confirmingSignOut = true }
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
            } else {
                signInSections
            }
        }
        .navigationTitle(name)
        .disabled(isChecking)
        .alert("Couldn't Sign In", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
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

    @ViewBuilder private var signInSections: some View {
        Section {
            IOSFormField("Address", text: $address, prompt: "Required", kind: .url)
        } header: {
            Text("Server")
        } footer: {
            Text("Your \(name) server's address, with its port.")
        }
        Section {
            IOSFormField("Username", text: $username, prompt: "Required", kind: .username)
            IOSFormField("Password", text: $password, prompt: "None", kind: .password)
        } footer: {
            Text("Leave the password empty if the user has none.")
        }
        Section {
            Button(action: signIn) {
                HStack(spacing: 8) {
                    if isChecking, quickConnectTask == nil {
                        ProgressView()
                        Text("Signing In…")
                    } else {
                        Text("Sign In")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            if server.quickConnect != nil {
                Button("Quick Connect", action: startQuickConnect)
                    .frame(maxWidth: .infinity)
            }
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
