// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

enum IOSColorTheme: String, CaseIterable, Identifiable {
    case system
    case dark
    case light

    static let storageKey = "iosColorTheme"

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .system: "System"
        case .dark: "Dark"
        case .light: "Light"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
}

/// The Account sheet behind every tab's avatar: profile, server, settings pages, About.
struct IOSAccountView: View {
    @EnvironmentObject private var plex: PlexSession
    @ObservedObject private var profiles = PlexUserProfileManager.shared
    @ObservedObject private var sync = CloudSync.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingSignIn = false
    @State private var confirmingSignOut = false
    @State private var appIcon = AppIcon.current
    @AppStorage(IOSColorTheme.storageKey) private var colorThemeRawValue = IOSColorTheme.system.rawValue
    /// Bumped when the sheet shows again, so the server rows re-read their stored accounts.
    @State private var serverRevision = 0

    var body: some View {
        NavigationStack {
            Form {
                if plex.isSignedIn {
                    accountSections
                } else {
                    signedOutSection
                }

                // Server accounts are the owner's, not a restricted profile's.
                if !profiles.isRestrictedProfile {
                    serversSection
                }

                Section("Settings") {
                    NavigationLink {
                        IOSHomeSettingsView()
                    } label: {
                        Label("Home", systemImage: "house")
                    }
                    NavigationLink {
                        IOSLibrarySettingsView()
                    } label: {
                        Label("Library", systemImage: "rectangle.stack")
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
                    Picker(selection: $colorThemeRawValue) {
                        ForEach(IOSColorTheme.allCases) { theme in
                            Text(theme.title).tag(theme.rawValue)
                        }
                    } label: {
                        Label("Color Theme", systemImage: "circle.lefthalf.filled")
                    }
                    .pickerStyle(.navigationLink)
                    Picker(selection: Binding(get: { appIcon }, set: { appIcon = $0; $0.apply() })) {
                        ForEach(AppIcon.allCases) { Text($0.title).tag($0) }
                    } label: {
                        Label("App Icon", systemImage: "app.badge")
                    }
                    .pickerStyle(.navigationLink)
                    // Sources and server choice are the owner's, not a restricted profile's.
                    if !profiles.isRestrictedProfile {
                        NavigationLink {
                            IOSLiveTVSettingsView()
                        } label: {
                            Label("Live TV", systemImage: "play.tv")
                        }
                    }
                }

                // Sources and server choice are the owner's, not a restricted profile's.
                if !profiles.isRestrictedProfile {
                    Section {
                        Toggle("iCloud Sync", isOn: Binding(get: { sync.isEnabled }, set: { sync.setEnabled($0) }))
                    } footer: {
                        Text(sync.status == .noAccount
                             ? "Sign in to iCloud in the Settings app to sync."
                             : sync.status == .on && sync.blockedAccountIDs.contains(PlexAuthManager.syncID)
                             ? "iCloud has a different Plex account."
                             : "Keeps your settings, servers and Live TV sources the same on your Apple TV, iPhone and iPad. Sign-ins are stored encrypted in iCloud. Watch progress comes from your servers and is not part of this.")
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: IOSChangelog.currentVersion)
                    NavigationLink("Changelog") { IOSChangelogView() }
                    NavigationLink("Licenses") { IOSLicensesView() }
                }

                if plex.isSignedIn, !profiles.isRestrictedProfile {
                    Section {
                        Button("Sign Out", role: .destructive) { confirmingSignOut = true }
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
            .onAppear { serverRevision += 1 }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showingSignIn) { IOSPlexConnectionSheet().iosSessionObjects(plex) }
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
            if !profiles.isRestrictedProfile {
                NavigationLink {
                    IOSServerPicker()
                } label: {
                    LabeledContent {
                        Text(plex.serversSummary ?? "")
                    } label: {
                        Label("Servers", systemImage: "server.rack")
                    }
                }
            }
        }
    }

    private var serversSection: some View {
        Section("Servers") {
            let _ = serverRevision
            ForEach(OtherServerKind.all, id: \.kind) { server in
                NavigationLink {
                    IOSServerSignInView(server: server)
                } label: {
                    LabeledContent {
                        Text(server.account()?.name ?? "")
                    } label: {
                        Label("\(server.kind.displayName) Server", systemImage: "server.rack")
                    }
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
}

/// Every server on the account; the ones checked show their content. A click turns one on or off.
private struct IOSServerPicker: View {
    @EnvironmentObject private var plex: PlexSession
    @State private var servers: [PlexDevice]?
    @State private var loadError: String?
    @State private var connectingID: String?
    @State private var notice: ServerNotice?
    /// Bumped after a toggle so the checkmarks re-read.
    @State private var revision = 0

    var body: some View {
        List(servers ?? []) { server in
            Button { toggle(server) } label: {
                let _ = revision
                IOSServerRow(
                    server: server,
                    isCurrent: connectingID == nil && plex.isServerEnabled(server),
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
        .navigationTitle("Servers")
        .task { await load() }
        .refreshable { await load() }
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
