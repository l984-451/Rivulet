// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import StoreKit
import SwiftUI

/// Settings > General: app icon, iCloud sync, TMDB key and About. Parity source: the lower sections of IOSAccountView.
struct MacGeneralSettingsView: View {
    @ObservedObject private var profiles = PlexUserProfileManager.shared
    @ObservedObject private var sync = CloudSync.shared
    @EnvironmentObject private var browse: BrowseStore
    @State private var confirmingClear = false
    @State private var isClearing = false
    @State private var appIcon = AppIcon.current
    @State private var showingChangelog = false
    @State private var showingLicenses = false
    @State private var tips: [Product] = []
    @State private var spaceUsed: Int64?
    @State private var thanked = false

    var body: some View {
        Form {
            Section {
                Picker("App Icon", selection: Binding(get: { appIcon }, set: { appIcon = $0; $0.apply() })) {
                    ForEach(AppIcon.allCases) { Text($0.title).tag($0) }
                }
            }

            // Sync (sources, server sign-ins) and the TMDB key are the owner's, not a restricted profile's.
            if !profiles.isRestrictedProfile {
                Section {
                    Toggle("iCloud Sync", isOn: Binding(get: { sync.isEnabled }, set: { sync.setEnabled($0) }))
                } footer: {
                    Text(sync.status == .noAccount
                         ? "Sign in to iCloud in System Settings to sync."
                         : sync.status == .on && sync.blockedAccountIDs.contains(PlexAuthManager.syncID)
                         ? "iCloud has a different Plex account."
                         : "Keeps your settings, servers and Live TV sources the same on your Apple TV, iPhone, iPad and Mac. Sign-ins are stored encrypted in iCloud. Watch progress comes from your servers and is not part of this.")
                }

                MacTMDBKeySection()
            }

            Section {
                LabeledContent("Space Used", value: spaceUsed.map(StorageUsage.formatted) ?? String(localized: "Calculating…"))
                Button("Clear Cache and Reload…", role: .destructive) { confirmingClear = true }
                    .disabled(isClearing)
            } header: {
                Text("Storage")
            } footer: {
                Text("Removes cached artwork and scrub thumbnails, then reloads your libraries and Home rows from your servers.")
            }

            Section {
                LabeledContent("Version", value: MacChangelog.currentVersion)
                LabeledContent("Changelog") { Button("Show…") { showingChangelog = true } }
                LabeledContent("Licenses") { Button("Show…") { showingLicenses = true } }
                if !tips.isEmpty {
                    LabeledContent("Leave a Tip") {
                        HStack {
                            ForEach(tips, id: \.id) { product in
                                Button(product.displayPrice) {
                                    Task { thanked = await TipJar.purchase(product) }
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("About")
            } footer: {
                if !tips.isEmpty {
                    Text("Rivulet is free and open source. A one-time tip helps keep it going.")
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear Cache and Reload?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear Cache", role: .destructive) {
                isClearing = true
                Task {
                    await MacArtworkCache.shared.clear()
                    URLCache.shared.removeAllCachedResponses()
                    await PlexThumbnailService.shared.clearAllCache()
                    ArtworkTitleCheck.clearDisk()
                    await browse.watchStateDidChange()
                    isClearing = false
                    await measureSpace()
                }
            }
        } message: {
            Text("Artwork and metadata are downloaded again as you browse.")
        }
        .sheet(isPresented: $showingChangelog) { MacChangelogSheet() }
        .sheet(isPresented: $showingLicenses) { MacLicensesSheet() }
        .task { tips = await TipJar.products() }
        .task { await measureSpace() }
        .alert("Thank You", isPresented: $thanked) {
            Button("OK") {}
        } message: {
            Text("Your tip helps keep Rivulet going.")
        }
    }

    private func measureSpace() async {
        spaceUsed = nil
        spaceUsed = await Task.detached(priority: .utility) { StorageUsage.totalBytes() }.value
    }
}

/// General > TMDB Key: the user's own key (`TMDBCredential`). The field never shows a saved key.
private struct MacTMDBKeySection: View {
    @State private var isSaved = TMDBCredential.saved != nil
    @State private var key = ""
    @State private var isChecking = false
    @State private var failure: String?

    var body: some View {
        Section {
            if isSaved {
                LabeledContent("TMDB Key") {
                    HStack {
                        Text("Set")
                        Button("Remove TMDB Key", role: .destructive) {
                            TMDBCredential.remove()
                            isSaved = false
                        }
                    }
                }
            } else {
                MacFormField("TMDB Key", text: $key, prompt: "Required", kind: .password)
                    .onSubmit(save)
                HStack(spacing: 8) {
                    if isChecking { ProgressView().controlSize(.small) }
                    Button("Save", action: save).disabled(key.isEmpty || isChecking)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        } footer: {
            Text("Uses your own TMDB key instead of Rivulet's service, for builds from source or to use your own TMDB quota. Takes an API Read Access Token or API key from themoviedb.org.")
        }
        .alert("Couldn't Save Key", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func save() {
        guard !key.isEmpty, !isChecking else { return }
        isChecking = true
        failure = nil
        Task {
            do {
                try await TMDBCredential.saveVerified(key)
                key = ""
                isSaved = true
            } catch {
                failure = error.localizedDescription
            }
            isChecking = false
        }
    }
}

/// Every release, newest first.
private struct MacChangelogSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            List(MacChangelog.entries, id: \.version) { entry in
                Section(entry.version) {
                    MacChangelogLines(lines: entry.lines).padding(.vertical, 4)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 440)
    }
}

/// Licenses, read from the same `OpenSourceLicenses` text tvOS and iOS show.
/// Required, not optional chrome: the (L)GPL text and source offer must ship with every build.
private struct MacLicensesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Rivulet") {
                    Text(OpenSourceLicenses.appLicense).font(.footnote).foregroundStyle(.secondary)
                }
                Section("Open Source Software") {
                    ForEach(OpenSourceLicenses.entries, id: \.name) { entry in
                        NavigationLink(entry.name) { MacLicenseDetail(entry: entry) }
                    }
                }
                Section("Corresponding Source") {
                    if let url = URL(string: OpenSourceLicenses.ffmpegSourceURL) {
                        Link("FFmpeg Build Scripts and Sources", destination: url)
                    }
                    if let url = URL(string: OpenSourceLicenses.aetherSourceURL) {
                        Link("AetherEngine", destination: url)
                    }
                }
            }
            .navigationTitle("Licenses")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .frame(width: 560, height: 520)
    }
}

private struct MacLicenseDetail: View {
    let entry: OpenSourceLicenses.Entry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(entry.summary).font(.subheadline)
                Text(entry.licenseText).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(entry.name)
    }
}
