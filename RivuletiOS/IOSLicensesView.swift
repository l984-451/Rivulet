// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Licenses & Legal for iOS. The tvOS build shows the same text through
/// `InfoPopupContent.acknowledgements()`; both read `OpenSourceLicenses` from
/// RivuletCore so the wording cannot drift between platforms.
///
/// This is not optional chrome. The app links FFmpeg and AetherEngine under the
/// (L)GPL, which requires the licence text and the written offer of
/// corresponding source to travel with every binary — TestFlight builds
/// included.
struct IOSLicensesView: View {
    var body: some View {
        List {
            Section {
                Text(OpenSourceLicenses.appLicense)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Corresponding source") {
                Link("FFmpeg build scripts and pinned sources",
                     destination: URL(string: OpenSourceLicenses.ffmpegSourceURL)!)
                Link("AetherEngine",
                     destination: URL(string: OpenSourceLicenses.aetherSourceURL)!)
            }

            ForEach(OpenSourceLicenses.entries) { entry in
                Section(entry.name) {
                    Text(entry.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    NavigationLink("Full licence text") {
                        ScrollView {
                            Text(entry.licenseText)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                        .navigationTitle(entry.name)
                        .navigationBarTitleDisplayMode(.inline)
                    }
                }
            }
        }
        .navigationTitle("Licenses & Legal")
        .navigationBarTitleDisplayMode(.inline)
    }
}
