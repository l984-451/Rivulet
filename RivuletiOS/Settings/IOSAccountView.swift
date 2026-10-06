// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// The Account sheet behind every tab's avatar: profile, server, settings pages, About.
struct IOSAccountView: View {
    @EnvironmentObject private var plex: IOSPlexSession
    @ObservedObject private var profiles = PlexUserProfileManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingSignIn = false
    @State private var confirmingSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                if plex.isConfigured {
                    accountSections
                } else {
                    signedOutSection
                }

                Section("Settings") {
                    NavigationLink {
                        IOSHomeSettingsView()
                    } label: {
                        Label("Home", systemImage: "house")
                    }
                    NavigationLink {
                        IOSPlaybackSettingsView()
                    } label: {
                        Label("Playback", systemImage: "play.rectangle")
                    }
                    NavigationLink {
                        IOSDownloadSettingsView()
                    } label: {
                        Label("Downloads", systemImage: "arrow.down.circle")
                    }
                    NavigationLink {
                        IOSLiveTVSettingsView()
                    } label: {
                        Label("Live TV", systemImage: "play.tv")
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: Self.version)
                    NavigationLink("Licenses") { IOSLicensesView() }
                }

                if plex.isConfigured {
                    Section {
                        Button("Sign Out", role: .destructive) { confirmingSignOut = true }
                            .confirmationDialog("Sign out of Plex?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                                Button("Sign Out", role: .destructive) { plex.signOut() }
                            } message: {
                                Text("You can sign back in at any time.")
                            }
                    }
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showingSignIn) { IOSPlexConnectionSheet() }
    }

    @ViewBuilder
    private var accountSections: some View {
        Section {
            HStack(spacing: 14) {
                IOSPlexAccountAvatar(url: profiles.selectedUser?.avatarURL ?? plex.profileImageURL, size: 60)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profiles.selectedUser?.displayName ?? plex.profileDisplayName ?? "Plex")
                        .font(.title3.weight(.semibold))
                    if let server = plex.selectedServerName {
                        Text(server).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }

        Section {
            if profiles.hasMultipleProfiles {
                NavigationLink {
                    IOSProfilePicker().navigationTitle("Switch Profile")
                } label: {
                    Label("Switch Profile", systemImage: "person.2")
                }
            }
            NavigationLink {
                IOSServerPicker()
            } label: {
                LabeledContent {
                    Text(plex.selectedServerName ?? "")
                } label: {
                    Label("Server", systemImage: "server.rack")
                }
            }
        }
    }

    private var signedOutSection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Sign in to watch your Plex libraries.")
                    .multilineTextAlignment(.center)
                Button("Sign In to Plex") { showingSignIn = true }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// Every server on the account, current one checked. Picking another connects to it.
private struct IOSServerPicker: View {
    @EnvironmentObject private var plex: IOSPlexSession
    @State private var servers: [PlexDevice]?
    @State private var loadError: String?
    @State private var connectingID: String?
    @State private var failedServer: String?

    var body: some View {
        List(servers ?? []) { server in
            Button { connect(to: server) } label: {
                IOSServerRow(
                    server: server,
                    isCurrent: connectingID == nil && plex.isCurrentServer(server),
                    isConnecting: connectingID == server.id
                )
            }
            .disabled(connectingID != nil)
        }
        .overlay {
            if let loadError {
                ContentUnavailableView("Couldn’t Load Servers", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else if servers == nil {
                ProgressView()
            }
        }
        .navigationTitle("Server")
        .task { await load() }
        .refreshable { await load() }
        .alert("Couldn’t Connect", isPresented: Binding(get: { failedServer != nil }, set: { if !$0 { failedServer = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(failedServer ?? "The server") isn’t reachable right now.")
        }
    }

    private func load() async {
        do {
            servers = try await plex.accountServers()
            loadError = nil
        } catch let error where isCancellationError(error) {
        } catch {
            if servers == nil { loadError = error.localizedDescription }
        }
    }

    private func connect(to server: PlexDevice) {
        guard !plex.isCurrentServer(server) else { return }
        connectingID = server.id
        Task {
            if !(await plex.switchServer(to: server)) { failedServer = server.name }
            connectingID = nil
        }
    }
}
