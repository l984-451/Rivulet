// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// Profile, servers and sign-out. Shown as the Settings Account tab and, with `showsDone`,
/// as the sheet the toolbar avatar opens. Parity source: RivuletiOS/Settings/IOSAccountView.swift.
struct MacAccountView: View {
    var showsDone = false
    @EnvironmentObject private var plex: PlexSession
    @ObservedObject private var profiles = PlexUserProfileManager.shared
    @ObservedObject private var sync = CloudSync.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingSignIn = false
    @State private var showingProfiles = false
    @State private var showingServers = false
    @State private var confirmingSignOut = false
    @State private var signInServer: OtherServerKind?
    /// Bumped when a server sheet closes, so the rows re-read their stored accounts.
    @State private var serverRevision = 0

    var body: some View {
        Form {
            if plex.isSignedIn {
                plexSections
            } else {
                signedOutSection
            }
            // Server accounts are the owner's, not a restricted profile's.
            if !profiles.isRestrictedProfile {
                serversSection
            }
            if plex.isSignedIn, !profiles.isRestrictedProfile {
                Section {
                    Button("Sign Out of Plex…", role: .destructive) { confirmingSignOut = true }
                        .confirmationDialog("Sign out of Plex?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                            if sync.isSynced(accountID: PlexAuthManager.syncID) {
                                Button("This Device Only") { plex.signOut(scope: .thisDevice) }
                                Button("All Devices", role: .destructive) { plex.signOut(scope: .everywhere) }
                            } else {
                                Button("Sign Out", role: .destructive) { plex.signOut() }
                            }
                        } message: {
                            Text(sync.isSynced(accountID: PlexAuthManager.syncID)
                                 ? "Your Plex sign-in is shared through iCloud. Sign out of this device only, or of every device?"
                                 : "You can sign back in at any time.")
                        }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingSignIn) { MacPlexSignInSheet() }
        .sheet(isPresented: $showingProfiles) { MacProfilePickerSheet() }
        .sheet(isPresented: $showingServers) { MacPlexServerPicker() }
        .sheet(item: $signInServer, onDismiss: { serverRevision += 1 }) { MacServerSignInSheet(server: $0) }
        .onAppear { serverRevision += 1 }
        .toolbar {
            if showsDone { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 460, minHeight: 360)
    }

    @ViewBuilder
    private var plexSections: some View {
        Section("Plex") {
            HStack(spacing: 14) {
                MacAccountAvatar(url: profiles.selectedUser?.avatarURL ?? plex.profileImageURL, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profiles.selectedUser?.displayName ?? plex.profileDisplayName ?? "Plex")
                        .font(.title3.weight(.semibold))
                    if let server = plex.selectedServerName {
                        Text(server).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            if profiles.hasMultipleProfiles {
                LabeledContent("Profile") {
                    Button("Switch Profile…") { showingProfiles = true }
                }
            }
            if !profiles.isRestrictedProfile {
                LabeledContent("Servers") {
                    Button(plex.serversSummary ?? String(localized: "Choose…")) { showingServers = true }
                }
            }
        }
    }

    private var serversSection: some View {
        Section("Servers") {
            let _ = serverRevision
            ForEach(OtherServerKind.all, id: \.kind) { server in
                LabeledContent("\(server.kind.displayName) Server") {
                    Button(server.account()?.name ?? String(localized: "Sign In…")) { signInServer = server }
                }
            }
        }
    }

    private var signedOutSection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 48))
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
}

extension OtherServerKind: Identifiable {
    var id: String { kind.displayName }
}

/// Every server on the account; the ones checked show their content. A click turns one on or off.
private struct MacPlexServerPicker: View {
    @EnvironmentObject private var plex: PlexSession
    @Environment(\.dismiss) private var dismiss
    @State private var servers: [PlexDevice]?
    @State private var loadError: String?
    @State private var connectingID: String?
    @State private var notice: ServerNotice?
    /// Bumped after a toggle so the checkmarks re-read.
    @State private var revision = 0

    var body: some View {
        VStack(spacing: 0) {
            List(servers ?? []) { server in
                Button { toggle(server) } label: {
                    let _ = revision
                    MacServerRow(server: server,
                                 isCurrent: connectingID == nil && plex.isServerEnabled(server),
                                 isConnecting: connectingID == server.id)
                }
                .buttonStyle(.plain)
                .disabled(connectingID != nil)
            }
            .overlay {
                if let loadError {
                    ContentUnavailableView("Couldn’t Load Servers", systemImage: "exclamationmark.triangle",
                                           description: Text(loadError))
                } else if servers == nil {
                    ProgressView()
                }
            }
            Divider()
            HStack {
                Button("Refresh") { Task { await load() } }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 420, height: 360)
        .task { await load() }
        .alert(notice?.title ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice?.message ?? "")
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

    private func toggle(_ server: PlexDevice) {
        connectingID = server.id
        Task {
            switch await plex.toggleServer(server, among: servers ?? []) {
            case .changed: break
            case .onlyServer: notice = .onlyServer
            case .unreachable: notice = .unreachable(server.name)
            }
            connectingID = nil
            revision += 1
        }
    }
}
