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
                // A server's own Live TV leaves with its sign-in.
                if !source.sourceType.followsServer {
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            // No Plex row: the Plex server's DVR is added on its own.
            List {
                Section("Your Server") {
                    NavigationLink {
                        IOSLiveDispatcharrForm { dismiss() }
                    } label: {
                        row("Dispatcharr", detail: "Channels, guide and recordings", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    NavigationLink {
                        IOSLiveTvheadendForm { dismiss() }
                    } label: {
                        row("Tvheadend", detail: "Channels, guide and recordings", systemImage: "tv")
                    }
                    NavigationLink {
                        IOSLiveThreadfinForm { dismiss() }
                    } label: {
                        row("Threadfin", detail: "Channels and guide", systemImage: "server.rack")
                    }
                }
                Section("Provider") {
                    NavigationLink {
                        IOSLiveXtreamForm { dismiss() }
                    } label: {
                        row("Xtream Codes", detail: "A server, username and password from your provider",
                            systemImage: "person.badge.key")
                    }
                    NavigationLink {
                        IOSLivePlaylistForm { dismiss() }
                    } label: {
                        row("Playlist URL", detail: "An M3U link from your provider", systemImage: "list.bullet")
                    }
                }
            }
            .navigationTitle("Add Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
            }
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
}

private struct IOSLiveDispatcharrForm: View {
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
                IOSFormField("Address", text: $address, prompt: "Required", kind: .url)
            } header: {
                Text("Server")
            } footer: {
                Text("Your Dispatcharr server's address on your network, with its port.")
            }

            Section {
                IOSFormField("Username", text: $username, prompt: "Optional", kind: .username)
                IOSFormField("Password", text: $password, prompt: "Optional", kind: .password)
            } header: {
                Text("Dispatcharr Sign-In")
            } footer: {
                Text("Only needed to record. Leave both empty to just watch.")
            }

            Section {
                IOSFormField("Channel Profile", text: $profile, prompt: "All Channels", kind: .username)
                IOSFormField("Name", text: $name, prompt: LiveTVSourceConnector.defaultServerName)
            } header: {
                Text("Options")
            } footer: {
                Text("A channel profile shows only that profile's channels. The name is how this source appears in Live TV.")
            }

            IOSLiveAddButton(isChecking: isChecking, action: add)
        }
        .navigationTitle("Dispatcharr")
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

private struct IOSLiveXtreamForm: View {
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
                IOSFormField("Server", text: $address, prompt: "http://provider.example:8080", kind: .url)
            } footer: {
                Text("The server address from your provider, with its port. You can also paste a get.php link: Rivulet fills in the username and password from it.")
            }
            Section {
                IOSFormField("Username", text: $username, prompt: "Required", kind: .username)
                IOSFormField("Password", text: $password, prompt: "Required", kind: .password)
            } header: {
                Text("Account")
            }
            Section {
                IOSFormField("Name", text: $name, prompt: LiveTVSourceConnector.defaultPlaylistName)
            } footer: {
                Text("How this source appears in Live TV.")
            }
            IOSLiveAddButton(isChecking: isChecking, action: add)
        }
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
        let connector = LiveTVSourceConnector()
        do {
            let request = try connector.xtreamRequest(address: address, username: username, password: password)
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

private struct IOSLiveTvheadendForm: View {
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
                IOSFormField("Address", text: $address, prompt: "Required", kind: .url)
            } header: {
                Text("Server")
            } footer: {
                Text("Your Tvheadend server's address on your network, with its port.")
            }
            Section {
                IOSFormField("Username", text: $username, prompt: "Optional", kind: .username)
                IOSFormField("Password", text: $password, prompt: "Optional", kind: .password)
            } header: {
                Text("Tvheadend Sign-In")
            } footer: {
                Text("Only needed if your server asks for a login, and to record. Leave both empty to just watch.")
            }
            Section {
                IOSFormField("Name", text: $name, prompt: LiveTVSourceConnector.defaultTvheadendName)
            } footer: {
                Text("How this source appears in Live TV.")
            }
            IOSLiveAddButton(isChecking: isChecking, action: add)
        }
        .navigationTitle("Tvheadend")
        .disabled(isChecking)
        .connectFailureAlert($failure)
    }

    private func add() {
        let connector = LiveTVSourceConnector()
        do {
            let request = try connector.tvheadendRequest(address: address, username: username, password: password)
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

private struct IOSLiveThreadfinForm: View {
    let onAdded: () -> Void
    @State private var address = LiveTVSourceConnector.defaultAddress(for: .threadfin)
    @State private var name = ""
    @State private var isChecking = false
    @State private var failure: LiveTVConnectError?

    var body: some View {
        Form {
            Section {
                IOSFormField("Address", text: $address, prompt: "Required", kind: .url)
            } header: {
                Text("Server")
            } footer: {
                Text("Your Threadfin server's address on your network, with its port.")
            }
            Section {
                IOSFormField("Name", text: $name, prompt: LiveTVSourceConnector.defaultThreadfinName)
            } footer: {
                Text("How this source appears in Live TV.")
            }
            IOSLiveAddButton(isChecking: isChecking, action: add)
        }
        .navigationTitle("Threadfin")
        .disabled(isChecking)
        .connectFailureAlert($failure)
    }

    private func add() {
        do {
            let request = try LiveTVSourceConnector.threadfinRequest(address: address)
            let name = name.trimmingCharacters(in: .whitespaces)
            isChecking = true
            Task {
                defer { isChecking = false }
                do {
                    try await LiveTVSourceConnector().connect(
                        request, name: name.isEmpty ? LiveTVSourceConnector.defaultThreadfinName : name)
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
                IOSFormField("Playlist", text: $m3u, prompt: "http://provider.example/playlist.m3u", kind: .url)
            } footer: {
                Text("The M3U link from your provider.")
            }
            Section {
                IOSFormField("Guide", text: $epg, prompt: "Optional", kind: .url)
            } footer: {
                Text("An XMLTV link for what's on. Leave it empty if the playlist names its own guide.")
            }
            Section {
                IOSFormField("Name", text: $name, prompt: LiveTVSourceConnector.defaultPlaylistName)
            } footer: {
                Text("How this source appears in Live TV.")
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

/// A labelled form row, the way Settings and Mail lay out an account: the label
/// stays put once the field has text, so what was typed is never ambiguous.
private struct IOSFormField: View {
    enum Kind { case text, url, username, password }

    let label: String
    @Binding var text: String
    let prompt: String
    let kind: Kind

    init(_ label: String, text: Binding<String>, prompt: String, kind: Kind = .text) {
        self.label = label
        self._text = text
        self.prompt = prompt
        self.kind = kind
    }

    var body: some View {
        LabeledContent(label) {
            field
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(kind == .text ? .words : .never)
                .autocorrectionDisabled(kind != .text)
        }
    }

    @ViewBuilder private var field: some View {
        switch kind {
        case .password:
            SecureField(label, text: $text, prompt: Text(verbatim: prompt))
                .textContentType(.password)
        case .url:
            TextField(label, text: $text, prompt: Text(verbatim: prompt))
                .keyboardType(.URL)
                .textContentType(.URL)
        case .username:
            TextField(label, text: $text, prompt: Text(verbatim: prompt))
                .textContentType(.username)
        case .text:
            TextField(label, text: $text, prompt: Text(verbatim: prompt))
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
