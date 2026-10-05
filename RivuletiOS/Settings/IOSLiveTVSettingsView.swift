// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Account > Live TV: sources, favorites, suggestions and the default layout.
struct IOSLiveTVSettingsView: View {
    @ObservedObject private var store = LiveTVDataStore.shared
    @AppStorage(IOSLiveLayout.storageKey) private var layoutRaw = IOSLiveLayout.browse.rawValue
    @AppStorage(LiveTVDataStore.suggestionsKey) private var suggestions = true
    @State private var showingAddSource = false
    @State private var askingToErase = false

    var body: some View {
        Form {
            Section {
                ForEach(store.sources) { source in
                    NavigationLink {
                        IOSLiveSourceDetailView(sourceId: source.id)
                    } label: {
                        LabeledContent {
                            Text(source.isConnected ? "\(source.channelCount) channels" : "Offline")
                        } label: {
                            Label(source.displayName, systemImage: source.sourceType.iconName)
                        }
                    }
                }
                Button("Add Source…") { showingAddSource = true }
            } header: {
                Text("Sources")
            }

            Section {
                NavigationLink {
                    IOSLiveFavoritesView()
                } label: {
                    LabeledContent("Favorites", value: store.favoriteIds.isEmpty ? "" : "\(store.favoriteIds.count)")
                }
                Picker("Default Layout", selection: $layoutRaw) {
                    ForEach(IOSLiveLayout.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
            }

            Section {
                Toggle("Suggestions", isOn: $suggestions)
            } footer: {
                Text("For You picks channels from what you watch. It learns on this device only.")
            }
        }
        .navigationTitle("Live TV")
        .sheet(isPresented: $showingAddSource) { IOSLiveAddSourceSheet() }
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
private struct IOSLiveSourceDetailView: View {
    let sourceId: String
    @ObservedObject private var store = LiveTVDataStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRemove = false
    @State private var isRefreshing = false

    private var source: LiveTVDataStore.LiveTVSourceInfo? { store.sources.first { $0.id == sourceId } }

    var body: some View {
        Form {
            if let source {
                Section {
                    LabeledContent("Status", value: source.isConnected ? "Connected" : "Offline")
                    LabeledContent("Channels", value: "\(source.channelCount)")
                    if let profile = source.channelProfile, !profile.isEmpty {
                        LabeledContent("Channel Profile", value: profile)
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
                            if isRefreshing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isRefreshing)
                }
                Section {
                    Button("Remove Source", role: .destructive) { confirmingRemove = true }
                        .confirmationDialog("Remove Source?", isPresented: $confirmingRemove, titleVisibility: .visible) {
                            Button("Remove", role: .destructive) {
                                Task {
                                    await store.removeSource(id: sourceId)
                                    dismiss()
                                }
                            }
                        } message: {
                            Text("This will remove \"\(source.displayName)\" and all its channels from Live TV.")
                        }
                }
            }
        }
        .navigationTitle(source?.displayName ?? "Source")
    }
}

/// Rivulet's favourites in order: drag to reorder, swipe to remove.
private struct IOSLiveFavoritesView: View {
    @ObservedObject private var store = LiveTVDataStore.shared

    /// What `moveFavorites` offsets index: favourites whose channel is loaded.
    private var favorites: [UnifiedChannel] {
        let byId = Dictionary(store.channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return store.favoriteIds.compactMap { byId[$0] }
    }

    var body: some View {
        let favorites = favorites
        List {
            ForEach(favorites) { channel in
                HStack(spacing: 12) {
                    IOSLiveLogo(url: channel.logoURL).frame(width: 52, height: 32)
                    Text(channel.numberAndName)
                }
            }
            .onMove { store.moveFavorites(fromOffsets: $0, toOffset: $1) }
            .onDelete { offsets in offsets.map { favorites[$0] }.forEach(store.toggleFavorite) }
        }
        .overlay {
            if favorites.isEmpty {
                ContentUnavailableView("No Favorites Yet", systemImage: "star",
                                       description: Text("Touch and hold a channel in Live TV to add it."))
            }
        }
        .navigationTitle("Favorites")
        .toolbar {
            if !favorites.isEmpty { EditButton() }
        }
    }
}

// MARK: - Add Source

/// Picker named after what the user has, then a short form. Closes on success.
struct IOSLiveAddSourceSheet: View {
    @EnvironmentObject private var plex: IOSPlexSession
    @Environment(\.dismiss) private var dismiss
    @State private var checkingPlex = false
    @State private var failure: LiveTVConnectError?

    var body: some View {
        NavigationStack {
            List {
                if plex.isConfigured {
                    Button(action: addPlex) {
                        HStack {
                            row("Plex Live TV", detail: "From your Plex server's tuners", systemImage: "server.rack")
                            if checkingPlex {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(checkingPlex)
                    .foregroundStyle(.primary)
                }
                NavigationLink {
                    IOSLiveServerForm { dismiss() }
                } label: {
                    row("My Own Server", detail: "Dispatcharr, Threadfin", systemImage: "antenna.radiowaves.left.and.right")
                }
                NavigationLink {
                    IOSLivePlaylistForm { dismiss() }
                } label: {
                    row("Playlist URL", detail: "From an IPTV provider", systemImage: "list.bullet")
                }
            }
            .navigationTitle("Add Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
            }
            .connectFailureAlert($failure)
        }
        .presentationSizing(.form)
    }

    private func row(_ title: String, detail: String, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }

    private func addPlex() {
        checkingPlex = true
        Task {
            defer { checkingPlex = false }
            do {
                try await LiveTVSourceConnector().connect(LiveTVSourceConnector.plexRequest())
                dismiss()
            } catch {
                failure = error as? LiveTVConnectError ?? .plex(error.localizedDescription)
            }
        }
    }
}

private struct IOSLiveServerForm: View {
    let onAdded: () -> Void
    @State private var address = ""
    @State private var name = ""
    @State private var username = ""
    @State private var password = ""
    @State private var profile = ""
    @State private var isChecking = false
    @State private var failure: LiveTVConnectError?

    private let host = LiveTVSourceConnector.suggestedHost

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Server URL", text: $address, prompt: Text(verbatim: "http://\(host):9191"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Menu {
                        ForEach(LiveTVSourceConnector.serverSuggestions(host: host), id: \.label) { suggestion in
                            Button(suggestion.label) { address = suggestion.value }
                        }
                    } label: {
                        Image(systemName: "list.bullet.circle")
                    }
                    .accessibilityLabel("Suggestions")
                }
                TextField("Display Name", text: $name, prompt: Text(LiveTVSourceConnector.defaultServerName))
            } footer: {
                Text("The address of the server on your network, with its port.")
            }

            Section {
                TextField("Username", text: $username, prompt: Text("Optional"))
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password, prompt: Text("Optional"))
                    .textContentType(.password)
            } header: {
                Text("Sign In")
            } footer: {
                Text("Only needed to record. Leave it empty to just watch.")
            }

            Section {
                TextField("Channel Profile", text: $profile, prompt: Text("Optional"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("Shows only the channels in one profile.")
            }

            IOSLiveAddButton(isChecking: isChecking, action: add)
        }
        .navigationTitle("My Own Server")
        .disabled(isChecking)
        .connectFailureAlert($failure)
    }

    private func add() {
        let connector = LiveTVSourceConnector()
        do {
            let request = try connector.serverRequest(address: address, username: username, password: password,
                                                      channelProfile: profile)
            isChecking = true
            Task {
                defer { isChecking = false }
                do {
                    try await connector.connect(request, name: name.trimmingCharacters(in: .whitespaces))
                    onAdded()
                } catch {
                    failure = error as? LiveTVConnectError ?? .source(error.localizedDescription)
                }
            }
        } catch {
            failure = error as? LiveTVConnectError ?? .source(error.localizedDescription)
        }
    }
}

private struct IOSLivePlaylistForm: View {
    let onAdded: () -> Void
    @State private var m3u = ""
    @State private var epg = ""
    @State private var name = ""
    @State private var isChecking = false
    @State private var failure: LiveTVConnectError?

    var body: some View {
        Form {
            Section {
                TextField("M3U Playlist URL", text: $m3u, prompt: Text(verbatim: "http://example.com/playlist.m3u"))
                    .urlEntry()
            } footer: {
                Text("The playlist link from your provider.")
            }
            Section {
                TextField("EPG URL (Optional)", text: $epg, prompt: Text(verbatim: "http://example.com/epg.xml"))
                    .urlEntry()
            } footer: {
                Text("A guide link in XMLTV format, for what's on.")
            }
            Section {
                TextField("Display Name", text: $name, prompt: Text(LiveTVSourceConnector.defaultPlaylistName))
            }
            IOSLiveAddButton(isChecking: isChecking, action: add)
        }
        .navigationTitle("Playlist URL")
        .disabled(isChecking)
        .connectFailureAlert($failure)
    }

    private func add() {
        do {
            let request = try LiveTVSourceConnector.playlistRequest(m3uURL: m3u, epgURL: epg)
            isChecking = true
            Task {
                defer { isChecking = false }
                do {
                    try await LiveTVSourceConnector().connect(request, name: name.trimmingCharacters(in: .whitespaces))
                    onAdded()
                } catch {
                    failure = error as? LiveTVConnectError ?? .source(error.localizedDescription)
                }
            }
        } catch {
            failure = error as? LiveTVConnectError ?? .source(error.localizedDescription)
        }
    }
}

private struct IOSLiveAddButton: View {
    let isChecking: Bool
    let action: () -> Void

    var body: some View {
        Section {
            Button(action: action) {
                HStack(spacing: 8) {
                    if isChecking {
                        ProgressView()
                        Text("Checking…")
                    } else {
                        Text("Add Source")
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private extension View {
    func urlEntry() -> some View {
        keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

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
