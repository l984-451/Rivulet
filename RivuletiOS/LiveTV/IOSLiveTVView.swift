// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

struct IOSLiveTVView: View {
    @StateObject private var store = IOSLiveTVStore()
    @State private var showingSourceEditor = false
    @State private var selectedGroup: String?
    let showSettings: () -> Void

    init(showSettings: @escaping () -> Void = {}) {
        self.showSettings = showSettings
    }

    private var visibleChannels: [IOSIPTVChannel] {
        guard let selectedGroup else { return store.channels }
        return store.channels.filter { $0.groupTitle == selectedGroup }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                IOSGuideDefaultBackdrop()

                VStack(spacing: 0) {
                    liveTVHeader

                    Group {
                        if !store.channels.isEmpty {
                            guideContent
                        } else {
                            emptyContent
                        }
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingSourceEditor) {
                IOSLiveTVSourceView(store: store)
            }
            .task {
                await store.loadSavedSourceIfNeeded()
            }
        }
        .preferredColorScheme(.dark)
    }

    private var liveTVHeader: some View {
        HStack(spacing: 10) {
            if !store.channels.isEmpty {
                groupMenu
                    .frame(width: 42, height: 42)
                    .background(.thinMaterial, in: Circle())
            }

            Text("Live TV")
                .font(.headline)
                .foregroundStyle(.white)

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                if !store.channels.isEmpty {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await store.load() }
                    }
                    .disabled(store.state == .loading)
                    .labelStyle(.iconOnly)
                    .frame(width: 42, height: 42)
                }

                Button("Source", systemImage: "link") {
                    showingSourceEditor = true
                }
                .labelStyle(.iconOnly)
                .frame(width: 42, height: 42)

                IOSAccountMenu(showSettings: showSettings)
                    .frame(width: 42, height: 42)
            }
            .background(.thinMaterial, in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }

    private var groupMenu: some View {
        Menu {
            Button {
                selectedGroup = nil
            } label: {
                if selectedGroup == nil {
                    Label("All channels", systemImage: "checkmark")
                } else {
                    Text("All channels")
                }
            }

            ForEach(store.groups, id: \.self) { group in
                Button {
                    selectedGroup = group
                } label: {
                    if selectedGroup == group {
                        Label(group, systemImage: "checkmark")
                    } else {
                        Text(group)
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.title3)
                .frame(width: 42, height: 42)
        }
        .accessibilityLabel(selectedGroup ?? "All channels")
    }

    private var guideContent: some View {
        VStack(spacing: 0) {
            if case .failed(let message) = store.state {
                IOSGuideBanner(message: message)
            }

            IOSGuideView(
                channels: visibleChannels,
                programsByChannel: store.programsByChannel
            )
        }
        .overlay {
            if store.state == .loading {
                ZStack {
                    Color.black.opacity(0.24)
                    ProgressView("Refreshing guide…")
                        .padding(22)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
                .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder
    private var emptyContent: some View {
        switch store.state {
        case .loading:
            ProgressView("Loading playlist and guide…")
        case .failed(let message):
            ContentUnavailableView {
                Label("Guide unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Edit source") { showingSourceEditor = true }
                if store.hasSavedSource {
                    Button("Try again") { Task { await store.load() } }
                }
            }
        case .idle, .loaded:
            ContentUnavailableView {
                Label("Add your Live TV source", systemImage: "list.bullet.rectangle")
            } description: {
                Text("Enter an M3U playlist URL and its XMLTV guide URL to load the iOS EPG.")
            } actions: {
                Button("Configure source") { showingSourceEditor = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

}

private struct IOSGuideBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.white)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange)
    }
}

private struct IOSLiveTVSourceView: View {
    @ObservedObject var store: IOSLiveTVStore
    @Environment(\.dismiss) private var dismiss

    @State private var m3uURL: String
    @State private var xmltvURL: String
    @State private var userAgent: String
    @State private var authorizationHeader: String
    @State private var referer: String

    init(store: IOSLiveTVStore) {
        self.store = store
        _m3uURL = State(initialValue: store.m3uURLString)
        _xmltvURL = State(initialValue: store.xmltvURLString)
        _userAgent = State(initialValue: store.userAgentString)
        _authorizationHeader = State(initialValue: store.authorizationHeaderString)
        _referer = State(initialValue: store.refererString)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/playlist.m3u", text: $m3uURL, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .lineLimit(2...4)
                } header: {
                    Text("M3U playlist URL")
                } footer: {
                    Text("The playlist supplies channel names, groups, IDs, and stream URLs.")
                }

                Section {
                    TextField("https://example.com/guide.xml", text: $xmltvURL, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .lineLimit(2...4)
                } header: {
                    Text("XMLTV guide URL")
                } footer: {
                    Text("Guide channels are matched by tvg-id first, then by channel name.")
                }

                Section {
                    LabeledContent("User-Agent") {
                        TextField(LiveTVClientIdentity.userAgent, text: $userAgent)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("Authorization") {
                        SecureField("Optional", text: $authorizationHeader)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("Referer") {
                        TextField("Optional", text: $referer)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("HTTP headers (optional)")
                } footer: {
                    Text("A bare Authorization value is treated as a Dispatcharr API token; otherwise enter the complete Bearer, Basic, or Token value. Blank User-Agent uses \(LiveTVClientIdentity.userAgent). Authorization is only forwarded to same-host streams; User-Agent and Referer apply to all requests.")
                }

                if case .failed(let message) = store.state {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task {
                            let loaded = await store.configureAndLoad(
                                m3uURL: m3uURL,
                                xmltvURL: xmltvURL,
                                userAgent: userAgent,
                                authorizationHeader: authorizationHeader,
                                referer: referer
                            )
                            if loaded { dismiss() }
                        }
                    } label: {
                        HStack {
                            Text("Load guide")
                            Spacer()
                            if store.state == .loading {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(store.state == .loading || m3uURL.isEmpty || xmltvURL.isEmpty)

                    if store.hasSavedSource {
                        Button("Remove source", role: .destructive) {
                            store.clearSource()
                            dismiss()
                        }
                    }
                }

                Section {
                    Text("URLs and optional headers are saved on this device. They may contain credentials, so avoid sharing screenshots of this screen.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Live TV source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    IOSLiveTVView()
}
