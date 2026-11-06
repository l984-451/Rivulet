// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Account sign-in, with explicit profile/PIN selection for staged native accounts.
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
    @State private var profiles: [SiloProfile]?
    @State private var selectedProfile: SiloProfile?
    @State private var profilePIN = ""
    @State private var signInTask: Task<Void, Never>?

    private var name: String { server.kind.displayName }

    var body: some View {
        let _ = revision
        Form {
            if let profiles {
                profileSections(profiles)
            } else if let account = server.account() {
                let synced = CloudSync.shared.isSynced(accountID: account.providerID)
                Section {
                    LabeledContent("Server", value: account.name)
                    if let user = server.userName(), !user.isEmpty {
                        LabeledContent("User", value: user)
                    }
                }
                if server.kind == .silo {
                    Section {
                        Button("Switch Profile") { loadProfiles() }
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
        .onDisappear {
            quickConnectTask?.cancel()
            signInTask?.cancel()
            if server.kind == .silo {
                SiloSession.cancelPendingSignIn()
                SiloSession.cancelProfileSelection()
            }
        }
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

    @ViewBuilder private func profileSections(_ profiles: [SiloProfile]) -> some View {
        Section("Choose Profile") {
            ForEach(profiles, id: \.id) { profile in
                Button {
                    profilePIN = ""
                    selectedProfile = profile
                    if !profile.hasPIN { selectProfile(profile) }
                } label: {
                    Label(profile.name, systemImage: profile.hasPIN ? "lock.fill" : "person.fill")
                }
            }
        }
        if let profile = selectedProfile, profile.hasPIN {
            Section(profile.name) {
                SecureField("PIN", text: $profilePIN)
                    .keyboardType(.numberPad)
                Button("Unlock Profile") { selectProfile(profile) }
                    .disabled(profilePIN.isEmpty)
            }
        }
        Section {
            Button("Cancel", role: .cancel) {
                SiloSession.cancelPendingSignIn()
                SiloSession.cancelProfileSelection()
                self.profiles = nil
                selectedProfile = nil
                profilePIN = ""
            }
        }
    }

    private func loadProfiles() {
        isChecking = true
        signInTask = Task {
            defer { isChecking = false }
            do { profiles = try await SiloSession.profiles() }
            catch where isCancellationError(error) {}
            catch { failure = server.failureMessage(error) }
        }
    }

    private func selectProfile(_ profile: SiloProfile) {
        isChecking = true
        signInTask = Task {
            defer { isChecking = false }
            do {
                try await SiloSession.selectProfile(profile, pin: profile.hasPIN ? profilePIN : nil)
                profiles = nil
                selectedProfile = nil
                profilePIN = ""
                revision += 1
            } catch where isCancellationError(error) {
            } catch {
                profilePIN = ""
                failure = server.failureMessage(error)
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
        signInTask = Task {
            defer { isChecking = false }
            do {
                try await server.signIn(url, user, password)
                if server.kind == .silo { profiles = try await SiloSession.profiles() }
                password = ""
                revision += 1
            } catch where isCancellationError(error) {
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
