// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Seerr on the Mac: the detail page's Request button, the search Request row, and the Seerr
// sheet in Settings > Account. Port of RivuletiOS/Seerr/IOSSeerrViews.swift; the state and the
// requests live in `SeerrRequestModel` and `SeerrCatalog` (RivuletCore).

import SwiftUI

/// The detail page's Request button, in Play's place, for a title not in the library.
struct MacSeerrRequestButton: View {
    @ObservedObject var model: SeerrRequestModel

    var body: some View {
        Group {
            if !model.canRequest {
                Button {} label: { label }
                    .disabled(true)
            } else if model.kind == .movie {
                if let qualities = model.qualityChoices {
                    Menu { qualityButtons(qualities, seasons: nil) } label: { label }
                        .fixedSize()
                } else {
                    Button { Task { await model.request() } } label: { label }
                }
            } else {
                Menu { seasonChoices } label: { label }
                    .fixedSize()
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isRequesting || !model.isLoaded)
        .alert("Couldn’t Request", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: model.error ?? "")
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            if model.isRequesting {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: model.state.symbolName)
            }
            Text(model.state.badge ?? String(localized: "Request"))
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private var seasonChoices: some View {
        if model.requestableSeasons.count > 1 {
            choice(String(localized: "Request All Seasons"), seasons: nil)
            Divider()
        }
        ForEach(model.seasons, id: \.number) { season in
            if season.availability.canRequest {
                choice(SeerrRequestModel.label(for: season), seasons: [season.number])
            } else {
                Button(SeerrRequestModel.label(for: season)) {}
                    .disabled(true)
            }
        }
    }

    @ViewBuilder
    private func choice(_ title: String, seasons: [Int]?) -> some View {
        if let qualities = model.qualityChoices {
            Menu(title) { qualityButtons(qualities, seasons: seasons) }
        } else {
            Button(title) { Task { await model.request(seasons: seasons) } }
        }
    }

    private func qualityButtons(_ qualities: [SeerrQualityOption], seasons: [Int]?) -> some View {
        ForEach(Array(qualities.enumerated()), id: \.offset) { _, quality in
            Button(quality.title) { Task { await model.request(seasons: seasons, quality: quality) } }
        }
    }
}

/// A Seerr search result: poster, title, kind and year, and its state when already on its way.
struct MacSeerrSearchRow: View {
    let title: SeerrTitle

    var body: some View {
        HStack(spacing: 12) {
            MacItemArtwork(item: title.mediaItem, kind: .poster, width: 54, aspectRatio: 2 / 3)
                .aspectRatio(2 / 3, contentMode: .fit)
                .frame(width: 54)
                .clipShape(.rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title.title).lineLimit(2)
                Text(verbatim: title.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let badge = title.availability.badge {
                Label(badge, systemImage: title.availability.symbolName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// Settings > Account > Seerr: the server address and API key.
struct MacSeerrSettingsSheet: View {
    @State private var address = SeerrSettings.serverAddress
    @State private var apiKey = SeerrSettings.apiKey
    @State private var checking = false
    @State private var result: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Seerr").font(.title2.bold())
            Form {
                TextField("Server Address", text: $address, prompt: Text(verbatim: "192.168.1.10:5055"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                SecureField("API Key", text: $apiKey)
                    .autocorrectionDisabled()
            }
            Text("Find the API key in Seerr under Settings > General. Requests are made as Seerr's admin and approved automatically. Restricted profiles can't request.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let result {
                Text(verbatim: result)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if !SeerrSettings.serverAddress.isEmpty || !SeerrSettings.apiKey.isEmpty {
                    Button("Remove Seerr", role: .destructive) {
                        SeerrSettings.clear()
                        dismiss()
                    }
                }
                Spacer()
                Button("Check Connection") { Task { await check() } }
                    .disabled(checking)
                Button("Done") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func save() {
        SeerrSettings.serverAddress = address
        SeerrSettings.apiKey = apiKey
    }

    private func check() async {
        save()
        guard let client = SeerrClient.configured else {
            result = String(localized: "Enter the server address and an API key first.")
            return
        }
        checking = true
        defer { checking = false }
        do {
            let info = try await client.check()
            result = String(localized: "Seerr \(info.version), signed in as \(info.user). Search now shows titles you can request.")
        } catch {
            result = error.localizedDescription
        }
    }
}
