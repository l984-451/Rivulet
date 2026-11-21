// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Seerr on iOS: the detail page's Request button, the search Request row, and Settings > Seerr.
// The state and the requests live in `SeerrRequestModel` and `SeerrCatalog` (RivuletCore), shared
// with tvOS and Mac.

import SwiftUI

/// The detail page's Request button, in Play's place, for a title not in the library. A movie
/// requests in place (after a quality choice when there is more than one profile); a show opens
/// its seasons, each with the same choice. A title already on its way shows its state.
struct IOSSeerrRequestButton: View {
    @ObservedObject var model: SeerrRequestModel

    var body: some View {
        Group {
            if !model.canRequest {
                Button {} label: { label }
                    .disabled(true)
            } else if model.kind == .movie {
                if let qualities = model.qualityChoices {
                    Menu { qualityButtons(qualities, seasons: nil) } label: { label }
                } else {
                    Button { Task { await model.request() } } label: { label }
                }
            } else {
                Menu { seasonChoices } label: { label }
            }
        }
        .buttonStyle(.glassProminent)
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
                ProgressView()
            } else {
                Image(systemName: model.state.symbolName)
            }
            Text(model.state.badge ?? String(localized: "Request"))
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var seasonChoices: some View {
        if model.requestableSeasons.count > 1 {
            choice(String(localized: "Request All Seasons"), seasons: nil)
        }
        Section {
            ForEach(model.seasons, id: \.number) { season in
                if season.availability.canRequest {
                    choice(SeerrRequestModel.label(for: season), seasons: [season.number])
                } else {
                    Label(SeerrRequestModel.label(for: season), systemImage: season.availability.symbolName)
                }
            }
        }
    }

    /// A season (or all of them): a submenu of profiles when there is a choice, else a button.
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
            Button(quality.title, systemImage: quality.is4K ? "4k.tv" : "tv") {
                Task { await model.request(seasons: seasons, quality: quality) }
            }
        }
    }
}

/// A Seerr search result: the title's row, with its state when it is already on its way.
struct IOSSeerrSearchRow: View {
    let title: SeerrTitle

    var body: some View {
        HStack(spacing: 12) {
            IOSShellArtwork(url: title.mediaItem.artwork.poster) { Rectangle().fill(.quaternary) }
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
                    .labelStyle(.titleAndIcon)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Settings > Servers > Seerr.
struct IOSSeerrSettingsView: View {
    @State private var address = SeerrSettings.serverAddress
    @State private var apiKey = SeerrSettings.apiKey
    @State private var checking = false
    @State private var result: (title: String, message: String)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField("Server Address", text: $address, prompt: Text(verbatim: "192.168.1.10:5055"))
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { SeerrSettings.serverAddress = address }
                SecureField("API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { SeerrSettings.apiKey = apiKey }
            } footer: {
                Text("Find the API key in Seerr under Settings > General. Requests are made as Seerr's admin and approved automatically. Restricted profiles can't request.")
            }
            Section {
                Button {
                    Task { await check() }
                } label: {
                    HStack {
                        Text("Check Connection")
                        if checking { Spacer(); ProgressView() }
                    }
                }
                .disabled(checking)
                if !address.isEmpty || !apiKey.isEmpty {
                    Button("Remove Seerr", role: .destructive) {
                        SeerrSettings.clear()
                        address = ""
                        apiKey = ""
                    }
                }
            } footer: {
                Text("Search then shows titles you can request, and their pages a Request button.")
            }
        }
        .navigationTitle("Seerr")
        .onDisappear {
            SeerrSettings.serverAddress = address
            SeerrSettings.apiKey = apiKey
        }
        .alert(result?.title ?? "", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: result?.message ?? "")
        }
    }

    private func check() async {
        SeerrSettings.serverAddress = address
        SeerrSettings.apiKey = apiKey
        guard let client = SeerrClient.configured else {
            result = (String(localized: "Seerr Isn’t Set Up"), String(localized: "Enter the server address and an API key first."))
            return
        }
        checking = true
        defer { checking = false }
        do {
            let info = try await client.check()
            result = (String(localized: "Connected"),
                      String(localized: "Seerr \(info.version), signed in as \(info.user). Search now shows titles you can request."))
        } catch {
            result = (String(localized: "Couldn’t Connect"), error.localizedDescription)
        }
    }
}
