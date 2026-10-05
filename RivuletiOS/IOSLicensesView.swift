// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Licenses for iOS, read from the same `OpenSourceLicenses` text tvOS shows.
/// Required, not optional chrome: the (L)GPL text and source offer must ship with every build.
struct IOSLicensesView: View {
    var body: some View {
        List {
            Section {
                Text(OpenSourceLicenses.appLicense)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Rivulet")
            }

            Section("Open Source Software") {
                ForEach(OpenSourceLicenses.entries, id: \.name) { entry in
                    NavigationLink(entry.name) { IOSLicenseDetailView(entry: entry) }
                }
            }

            Section("Corresponding Source") {
                Link("FFmpeg Build Scripts and Sources", destination: URL(string: OpenSourceLicenses.ffmpegSourceURL)!)
                Link("AetherEngine", destination: URL(string: OpenSourceLicenses.aetherSourceURL)!)
            }
        }
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct IOSLicenseDetailView: View {
    let entry: OpenSourceLicenses.Entry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(entry.summary)
                    .font(.subheadline)
                Text(entry.licenseText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
