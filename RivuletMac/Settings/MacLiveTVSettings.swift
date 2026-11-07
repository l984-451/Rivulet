// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// Settings > Live TV: sources, favorites, suggestions and the default layout.
/// Parity source: IOSLiveTVSettingsView.
struct MacLiveTVSettingsView: View {
    @ObservedObject private var store = LiveTVDataStore.shared
    @ObservedObject private var profiles = PlexUserProfileManager.shared
    @AppStorage(LiveLayout.storageKey) private var layoutRaw = LiveLayout.browse.rawValue
    @AppStorage(LiveTVDataStore.suggestionsKey) private var suggestions = true
    @State private var showingAddSource = false
    @State private var showingFavorites = false
    @State private var detailSourceID: String?
    @State private var askingToErase = false
    /// Bumped after a server's Live TV is shown or hidden, to re-read the hidden sources.
    @State private var hiddenRevision = 0

    var body: some View {
        let _ = hiddenRevision
        Form {
            Section {
                ForEach(MacLiveSourceList.all(store)) { source in
                    LabeledContent {
                        HStack {
                            Text(MacLiveSourceList.isHidden(source, store) ? "Off"
                                 : source.isConnected ? "\(source.channelCount) channels" : "Offline")
                                .foregroundStyle(.secondary)
                            Button("Details…") { detailSourceID = source.id }
                        }
                    } label: {
                        Label(source.displayName, systemImage: source.sourceType.iconName)
                    }
                }
                // Sources are the owner's, not a restricted profile's.
                if !profiles.isRestrictedProfile {
                    Button("Add Source…") { showingAddSource = true }
                }
            } header: {
                Text("Sources")
            }

            Section {
                LabeledContent("Favorites") {
                    HStack {
                        if !store.favoriteIds.isEmpty { Text("\(store.favoriteIds.count)").foregroundStyle(.secondary) }
                        Button("Edit…") { showingFavorites = true }
                    }
                }
                Picker("Default Layout", selection: $layoutRaw) {
                    ForEach(LiveLayout.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
            }

            Section {
                Toggle("Suggestions", isOn: $suggestions)
            } footer: {
                Text("For You picks channels from what you watch. It learns on this Mac only.")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingAddSource) { MacLiveAddSourceSheet() }
        .sheet(isPresented: $showingFavorites) { MacLiveFavoritesSheet() }
        .sheet(isPresented: Binding(get: { detailSourceID != nil }, set: { if !$0 { detailSourceID = nil } })) {
            if let id = detailSourceID { MacLiveSourceDetailSheet(sourceId: id, onVisibilityChange: { hiddenRevision += 1 }) }
        }
        .onChange(of: suggestions) { _, on in
            if !on { askingToErase = true }
        }
        .confirmationDialog("Erase What For You Learned?", isPresented: $askingToErase, titleVisibility: .visible) {
            Button("Erase", role: .destructive) { store.forgetViewings() }
            Button("Keep", role: .cancel) {}
        }
    }
}

/// One source: status, channel count, refresh and remove.
/// Sources for Settings: the active ones plus a server's Live TV the user hid, listed as Off.
@MainActor
enum MacLiveSourceList {
    static func all(_ store: LiveTVDataStore) -> [LiveTVDataStore.LiveTVSourceInfo] {
        store.sources + store.hiddenPlexSources
            + [JellyfinLiveTVProvider.hiddenSource, EmbyLiveTVProvider.hiddenSource].compactMap { $0 }
    }

    static func isHidden(_ source: LiveTVDataStore.LiveTVSourceInfo, _ store: LiveTVDataStore) -> Bool {
        !store.sources.contains { $0.id == source.id }
    }
}

private struct MacLiveSourceDetailSheet: View {
    let sourceId: String
    var onVisibilityChange: () -> Void = {}
    @ObservedObject private var store = LiveTVDataStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRemove = false
    @State private var isRefreshing = false

    private var source: LiveTVDataStore.LiveTVSourceInfo? { MacLiveSourceList.all(store).first { $0.id == sourceId } }

    private var shownInLiveTV: Binding<Bool> {
        Binding(
            get: {
                switch source?.sourceType {
                case .plex: store.plexMachineIDs[sourceId].map { !store.isPlexLiveTVHidden(machineID: $0) } ?? true
                case .jellyfin: !UserDefaults.standard.bool(forKey: JellyfinLiveTVProvider.hiddenKey)
                case .emby: !UserDefaults.standard.bool(forKey: EmbyLiveTVProvider.hiddenKey)
                default: true
                }
            },
            set: { shown in
                switch source?.sourceType {
                case .plex:
                    if let id = store.plexMachineIDs[sourceId] { store.setPlexLiveTVHidden(!shown, machineID: id) }
                    Task { await store.plexSourcesSynced(); onVisibilityChange() }
                case .jellyfin:
                    let sync = JellyfinLiveTVProvider.setHidden(!shown)
                    Task { await sync?.value; onVisibilityChange() }
                case .emby:
                    let sync = EmbyLiveTVProvider.setHidden(!shown)
                    Task { await sync?.value; onVisibilityChange() }
                default: break
                }
            })
    }
    private var synced: Bool { CloudSync.shared.isSynced(accountID: LiveTVDataStore.syncID(forSource: sourceId)) }

    private func remove(_ scope: SignOutScope?) {
        Task {
            await store.removeSource(id: sourceId, scope: scope)
            dismiss()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let source {
                    Section(source.displayName) {
                        LabeledContent("Status", value: source.isConnected ? String(localized: "Connected") : String(localized: "Offline"))
                        LabeledContent("Channels", value: "\(source.channelCount)")
                        if let profile = source.channelProfile, !profile.isEmpty {
                            LabeledContent("Channel Profile", value: profile)
                        }
                    }
                    if source.sourceType.followsServer {
                        Section {
                            Toggle("Show in Live TV", isOn: shownInLiveTV)
                        }
                    }
                    Section {
                        Button {
                            isRefreshing = true
                            Task {
                                await store.refreshChannels()
                                await store.loadEPG(startDate: Date(), hours: LiveTVDataStore.refreshWindowHours)
                                isRefreshing = false
                            }
                        } label: {
                            HStack {
                                Text("Refresh Channels")
                                if isRefreshing { ProgressView().controlSize(.small) }
                            }
                        }
                        .disabled(isRefreshing)
                    }
                    // A server's own Live TV leaves with its sign-in.
                    if !source.sourceType.followsServer {
                        Section {
                            Button("Remove Source…", role: .destructive) { confirmingRemove = true }
                                .confirmationDialog("Remove Source?", isPresented: $confirmingRemove, titleVisibility: .visible) {
                                    if synced {
                                        Button("This Device Only") { remove(.thisDevice) }
                                        Button("All Devices", role: .destructive) { remove(.everywhere) }
                                    } else {
                                        Button("Remove", role: .destructive) { remove(nil) }
                                    }
                                } message: {
                                    Text(synced
                                         ? "\"\(source.displayName)\" is shared through iCloud. Remove it from this device only, or from every device?"
                                         : "This will remove \"\(source.displayName)\" and all its channels from Live TV.")
                                }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 440, height: 400)
    }
}

/// Rivulet's favorites in order: drag to reorder, Delete to remove.
private struct MacLiveFavoritesSheet: View {
    @ObservedObject private var store = LiveTVDataStore.shared
    @Environment(\.dismiss) private var dismiss

    /// What `moveFavorites` offsets index: favorites whose channel is loaded.
    private var favorites: [UnifiedChannel] {
        let byId = Dictionary(store.channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return store.favoriteIds.compactMap { byId[$0] }
    }

    var body: some View {
        let favorites = favorites
        VStack(spacing: 0) {
            Text("Favorites").font(.headline).padding(.top, 16)
            List {
                ForEach(favorites) { channel in
                    HStack(spacing: 12) {
                        MacImage(url: channel.logoURL).frame(width: 52, height: 32)
                        Text(channel.numberAndName)
                        Spacer()
                        Button { store.toggleFavorite(channel) } label: { Image(systemName: "star.slash") }
                            .buttonStyle(.borderless)
                            .help("Remove from Favorites")
                    }
                }
                .onMove { store.moveFavorites(fromOffsets: $0, toOffset: $1) }
                .onDelete { offsets in offsets.map { favorites[$0] }.forEach(store.toggleFavorite) }
            }
            .overlay {
                if favorites.isEmpty {
                    ContentUnavailableView("No Favorites Yet", systemImage: "star",
                                           description: Text("Right-click a channel in Live TV to add it."))
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 440, height: 440)
    }
}

// MARK: - Add Source

/// Picker named after what the user has, then a short form. Closes on success.
struct MacLiveAddSourceSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            // No Plex row: the Plex server's DVR is added on its own.
            List {
                Section("Your Server") {
                    NavigationLink {
                        MacLiveDispatcharrForm { dismiss() }
                    } label: {
                        row("Dispatcharr", detail: "Channels, guide and recordings", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    NavigationLink {
                        MacLiveTvheadendForm { dismiss() }
                    } label: {
                        row("Tvheadend", detail: "Channels, guide and recordings", systemImage: "tv")
                    }
                    NavigationLink {
                        MacLiveThreadfinForm { dismiss() }
                    } label: {
                        row("Threadfin", detail: "Channels and guide", systemImage: "server.rack")
                    }
                }
                Section("Provider") {
                    NavigationLink {
                        MacLiveXtreamForm { dismiss() }
                    } label: {
                        row("Xtream Codes", detail: "A server, username and password from your provider",
                            systemImage: "person.badge.key")
                    }
                    NavigationLink {
                        MacLivePlaylistForm { dismiss() }
                    } label: {
                        row("Playlist URL", detail: "An M3U link from your provider", systemImage: "list.bullet")
                    }
                }
            }
            .navigationTitle("Add Source")
            .safeAreaInset(edge: .bottom, alignment: .trailing) {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).padding(12)
            }
        }
        .frame(width: 480, height: 420)
    }

    private func row(_ title: LocalizedStringKey, detail: LocalizedStringKey, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
        }
        .padding(.vertical, 2)
    }
}

/// Runs a source check with the busy and failure state every add form shares.
@MainActor
private func addSource(
    isChecking: Binding<Bool>, failure: Binding<LiveTVConnectError?>, onAdded: @escaping () -> Void,
    build: () throws -> () async throws -> Void
) {
    do {
        let connect = try build()
        isChecking.wrappedValue = true
        Task {
            defer { isChecking.wrappedValue = false }
            do {
                try await connect()
                onAdded()
            } catch {
                failure.wrappedValue = error as? LiveTVConnectError ?? .source(error.localizedDescription)
            }
        }
    } catch {
        failure.wrappedValue = error as? LiveTVConnectError ?? .source(error.localizedDescription)
    }
}

private struct MacLiveDispatcharrForm: View {
    let onAdded: () -> Void
    @State private var address = LiveTVSourceConnector.defaultAddress(for: .dispatcharr)
    @State private var name = ""
    @State private var username = ""
    @State private var password = ""
    @State private var profile = ""
    @State private var isChecking = false
    @State private var failure: LiveTVConnectError?

    var body: some View {
        Form {
            Section {
                MacFormField("Address", text: $address, prompt: "Required", kind: .url)
            } header: {
                Text("Server")
            } footer: {
                Text("Your Dispatcharr server's address on your network, with its port.")
            }

            Section {
                MacFormField("Username", text: $username, prompt: "Optional", kind: .username)
                MacFormField("Password", text: $password, prompt: "Optional", kind: .password)
            } header: {
                Text("Dispatcharr Sign-In")
            } footer: {
                Text("Only needed to record. Leave both empty to just watch.")
            }

            Section {
                MacFormField("Channel Profile", text: $profile, prompt: "All Channels", kind: .username)
                MacFormField("Name", text: $name, prompt: LocalizedStringKey(LiveTVSourceConnector.defaultServerName))
            } header: {
                Text("Options")
            } footer: {
                Text("A channel profile shows only that profile's channels. The name is how this source appears in Live TV.")
            }

            MacLiveAddButton(isChecking: isChecking, action: add)
        }
        .formStyle(.grouped)
        .navigationTitle("Dispatcharr")
        .disabled(isChecking)
        .connectFailureAlert($failure)
    }

    private func add() {
        addSource(isChecking: $isChecking, failure: $failure, onAdded: onAdded) {
            let request = try LiveTVSourceConnector().serverRequest(
                address: address, username: username, password: password, channelProfile: profile)
            let name = name.trimmingCharacters(in: .whitespaces)
            return { try await LiveTVSourceConnector().connect(request, name: name) }
        }
    }
}

private struct MacLiveXtreamForm: View {
    let onAdded: () -> Void
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var name = ""
    @State private var isChecking = false
    @State private var failure: LiveTVConnectError?

    var body: some View {
        Form {
            Section {
                MacFormField("Server", text: $address, prompt: "http://provider.example:8080", kind: .url)
            } footer: {
                Text("The server address from your provider, with its port. You can also paste a get.php link: Rivulet fills in the username and password from it.")
            }
            Section {
                MacFormField("Username", text: $username, prompt: "Required", kind: .username)
                MacFormField("Password", text: $password, prompt: "Required", kind: .password)
            } header: {
                Text("Account")
            }
            Section {
                MacFormField("Name", text: $name, prompt: LocalizedStringKey(LiveTVSourceConnector.defaultPlaylistName))
            } footer: {
                Text("How this source appears in Live TV.")
            }
            MacLiveAddButton(isChecking: isChecking, action: add)
        }
        .formStyle(.grouped)
        .navigationTitle("Xtream Codes")
        .disabled(isChecking)
        .connectFailureAlert($failure)
        .onChange(of: address) { _, new in fillLogin(from: new) }
    }

    /// A pasted get.php link carries the login: move it into its own fields.
    private func fillLogin(from text: String) {
        let parsed = XtreamService.parseAddress(text)
        guard let user = parsed.username, let pass = parsed.password else { return }
        username = user
        password = pass
        address = parsed.server
    }

    private func add() {
        addSource(isChecking: $isChecking, failure: $failure, onAdded: onAdded) {
            let request = try LiveTVSourceConnector().xtreamRequest(address: address, username: username, password: password)
            let name = name.trimmingCharacters(in: .whitespaces)
            return { try await LiveTVSourceConnector().connect(request, name: name) }
        }
    }
}

private struct MacLiveTvheadendForm: View {
    let onAdded: () -> Void
    @State private var address = LiveTVSourceConnector.defaultAddress(for: .tvheadend)
    @State private var username = ""
    @State private var password = ""
    @State private var name = ""
    @State private var isChecking = false
    @State private var failure: LiveTVConnectError?

    var body: some View {
        Form {
            Section {
                MacFormField("Address", text: $address, prompt: "Required", kind: .url)
            } header: {
                Text("Server")
            } footer: {
                Text("Your Tvheadend server's address on your network, with its port.")
            }
            Section {
                MacFormField("Username", text: $username, prompt: "Optional", kind: .username)
                MacFormField("Password", text: $password, prompt: "Optional", kind: .password)
            } header: {
                Text("Tvheadend Sign-In")
            } footer: {
                Text("Only needed if your server asks for a login, and to record. Leave both empty to just watch.")
            }
            Section {
                MacFormField("Name", text: $name, prompt: LocalizedStringKey(LiveTVSourceConnector.defaultTvheadendName))
            } footer: {
                Text("How this source appears in Live TV.")
            }
            MacLiveAddButton(isChecking: isChecking, action: add)
        }
        .formStyle(.grouped)
        .navigationTitle("Tvheadend")
        .disabled(isChecking)
        .connectFailureAlert($failure)
    }

    private func add() {
        addSource(isChecking: $isChecking, failure: $failure, onAdded: onAdded) {
            let request = try LiveTVSourceConnector().tvheadendRequest(address: address, username: username, password: password)
            let name = name.trimmingCharacters(in: .whitespaces)
            return { try await LiveTVSourceConnector().connect(request, name: name) }
        }
    }
}

private struct MacLiveThreadfinForm: View {
    let onAdded: () -> Void
    @State private var address = LiveTVSourceConnector.defaultAddress(for: .threadfin)
    @State private var name = ""
    @State private var isChecking = false
    @State private var failure: LiveTVConnectError?

    var body: some View {
        Form {
            Section {
                MacFormField("Address", text: $address, prompt: "Required", kind: .url)
            } header: {
                Text("Server")
            } footer: {
                Text("Your Threadfin server's address on your network, with its port.")
            }
            Section {
                MacFormField("Name", text: $name, prompt: LocalizedStringKey(LiveTVSourceConnector.defaultThreadfinName))
            } footer: {
                Text("How this source appears in Live TV.")
            }
            MacLiveAddButton(isChecking: isChecking, action: add)
        }
        .formStyle(.grouped)
        .navigationTitle("Threadfin")
        .disabled(isChecking)
        .connectFailureAlert($failure)
    }

    private func add() {
        addSource(isChecking: $isChecking, failure: $failure, onAdded: onAdded) {
            let request = try LiveTVSourceConnector.threadfinRequest(address: address)
            let name = name.trimmingCharacters(in: .whitespaces)
            return { try await LiveTVSourceConnector().connect(
                request, name: name.isEmpty ? LiveTVSourceConnector.defaultThreadfinName : name) }
        }
    }
}

private struct MacLivePlaylistForm: View {
    let onAdded: () -> Void
    @State private var m3u = ""
    @State private var epg = ""
    @State private var name = ""
    @State private var isChecking = false
    @State private var failure: LiveTVConnectError?

    var body: some View {
        Form {
            Section {
                MacFormField("Playlist", text: $m3u, prompt: "http://provider.example/playlist.m3u", kind: .url)
            } footer: {
                Text("The M3U link from your provider.")
            }
            Section {
                MacFormField("Guide", text: $epg, prompt: "Optional", kind: .url)
            } footer: {
                Text("An XMLTV link for what's on. Leave it empty if the playlist names its own guide.")
            }
            Section {
                MacFormField("Name", text: $name, prompt: LocalizedStringKey(LiveTVSourceConnector.defaultPlaylistName))
            } footer: {
                Text("How this source appears in Live TV.")
            }
            MacLiveAddButton(isChecking: isChecking, action: add)
        }
        .formStyle(.grouped)
        .navigationTitle("Playlist URL")
        .disabled(isChecking)
        .connectFailureAlert($failure)
    }

    private func add() {
        addSource(isChecking: $isChecking, failure: $failure, onAdded: onAdded) {
            let request = try LiveTVSourceConnector.playlistRequest(m3uURL: m3u, epgURL: epg)
            let name = name.trimmingCharacters(in: .whitespaces)
            return { try await LiveTVSourceConnector().connect(request, name: name) }
        }
    }
}

private struct MacLiveAddButton: View {
    let isChecking: Bool
    let action: () -> Void

    var body: some View {
        Section {
            HStack {
                Spacer()
                Button(action: action) {
                    if isChecking {
                        ProgressView().controlSize(.small)
                        Text("Checking…")
                    } else {
                        Text("Add Source")
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private extension View {
    func connectFailureAlert(_ failure: Binding<LiveTVConnectError?>) -> some View {
        alert(
            failure.wrappedValue?.title ?? "",
            isPresented: Binding(get: { failure.wrappedValue != nil }, set: { if !$0 { failure.wrappedValue = nil } }),
            presenting: failure.wrappedValue
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
    }
}
