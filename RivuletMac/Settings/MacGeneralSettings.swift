// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// Settings > General: app icon, iCloud sync and About. Parity source: the lower sections of IOSAccountView.
struct MacGeneralSettingsView: View {
    @ObservedObject private var profiles = PlexUserProfileManager.shared
    @ObservedObject private var sync = CloudSync.shared
    @EnvironmentObject private var browse: BrowseStore
    @State private var confirmingClear = false
    @State private var isClearing = false
    @State private var appIcon = AppIcon.current
    @State private var showingChangelog = false
    @State private var showingLicenses = false

    var body: some View {
        Form {
            Section {
                Picker("App Icon", selection: Binding(get: { appIcon }, set: { appIcon = $0; $0.apply() })) {
                    ForEach(AppIcon.allCases) { Text($0.title).tag($0) }
                }
            }

            // Sync carries sources and server sign-ins: the owner's, not a restricted profile's.
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
            }

            Section {
                Button("Clear Cache and Reload…", role: .destructive) { confirmingClear = true }
                    .disabled(isClearing)
            } header: {
                Text("Storage")
            } footer: {
                Text("Removes cached artwork and scrub thumbnails, then reloads your libraries and Home rows from your servers.")
            }

            Section("About") {
                LabeledContent("Version", value: MacChangelog.currentVersion)
                LabeledContent("Changelog") { Button("Show…") { showingChangelog = true } }
                LabeledContent("Licenses") { Button("Show…") { showingLicenses = true } }
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
                }
            }
        } message: {
            Text("Artwork and metadata are downloaded again as you browse.")
        }
        .sheet(isPresented: $showingChangelog) { MacChangelogSheet() }
        .sheet(isPresented: $showingLicenses) { MacLicensesSheet() }
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
