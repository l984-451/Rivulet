// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI
import UIKit

struct IOSGuideView: View {
    let channels: [IOSIPTVChannel]
    let programsByChannel: [String: [IOSEPGProgram]]

    @State private var selection: IOSGuideSelection?
    @State private var playbackRequest: IOSPlaybackRequest?
    @State private var snapGeneration = 0

    var body: some View {
        IOSGuideCollectionView(
            channels: channels,
            programsByChannel: programsByChannel,
            snapToken: snapGeneration
        ) { channel, program in
            if let program {
                selection = IOSGuideSelection(channel: channel, program: program)
            } else {
                beginPlayback(IOSPlaybackRequest(channel: channel, program: nil))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .bottom)
        .sheet(item: $selection) { selected in
            IOSProgramDetailView(selection: selected) {
                beginPlayback(
                    IOSPlaybackRequest(channel: selected.channel, program: selected.program)
                )
            }
                .presentationDetents([.medium])
                .presentationBackground(.clear)
        }
        .fullScreenCover(item: $playbackRequest, onDismiss: {
            snapGeneration += 1
        }) { request in
            IOSAetherPlayerView(
                request: request,
                channels: channels,
                programsByChannel: programsByChannel
            )
        }
        .preferredColorScheme(.dark)
    }

    private func beginPlayback(_ request: IOSPlaybackRequest) {
        selection = nil
        Task { @MainActor in
            // Let the programme sheet finish dismissing before presenting the
            // full-screen player from the guide beneath it.
            try? await Task.sleep(for: .milliseconds(200))
            playbackRequest = request
        }
    }
}

/// The guide has no focus-driven programme artwork on touch devices, so it
/// always uses the tvOS no-art ambient state. Programme artwork belongs to the
/// play menu, where the selected programme is unambiguous.
struct IOSGuideDefaultBackdrop: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // tvOS's stock no-art surface is a neutral charcoal vignette:
                // softly illuminated in the centre and darker at every edge.
                // It contains no brand-blue or cyan tint.
                Color(white: 0.045)
                RadialGradient(
                    stops: [
                        .init(color: Color(white: 0.145), location: 0),
                        .init(color: Color(white: 0.105), location: 0.52),
                        .init(color: Color(white: 0.055), location: 1)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: hypot(geometry.size.width, geometry.size.height) * 0.62
                )
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.12), location: 0),
                        .init(color: .clear, location: 0.38),
                        .init(color: .black.opacity(0.18), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct IOSProgramDetailView: View {
    let selection: IOSGuideSelection
    let onPlay: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let portrait = iosGuideInterfaceIsPortrait(fallback: geometry.size)
                let artworkURL = portrait
                    ? selection.program.posterURL
                    : selection.program.landscapeURL

                ZStack {
                    IOSProgramDetailArtworkBackdrop(url: artworkURL)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(selection.channel.name)
                                .font(.headline)
                                .foregroundStyle(.white.opacity(0.78))

                            Text(selection.program.title)
                                .font(.system(.title2, design: .rounded, weight: .bold))
                                .foregroundStyle(.white)

                            if let subtitle = selection.program.subtitle,
                               !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.headline)
                                    .foregroundStyle(.white.opacity(0.8))
                            }

                            Button(action: onPlay) {
                                Label(
                                    "Play \(selection.channel.name)",
                                    systemImage: "play.fill"
                                )
                                .font(.headline)
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .background(.white, in: Capsule())
                            }
                            .buttonStyle(.plain)

                            HStack(spacing: 10) {
                                Text(
                                    "\(selection.program.start.formatted(date: .omitted, time: .shortened)) – \(selection.program.end.formatted(date: .omitted, time: .shortened))"
                                )
                                if let category = selection.program.category {
                                    Text(category)
                                        .lineLimit(1)
                                }
                                if let episode = selection.program.episodeNumber {
                                    Text(episode)
                                        .lineLimit(1)
                                }
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.76))

                            if let description = selection.program.description,
                               !description.isEmpty {
                                Text(description)
                                    .font(.body)
                                    .foregroundStyle(.white.opacity(0.88))
                                    .lineSpacing(3)
                            }
                        }
                        .padding(.horizontal, portrait ? 20 : 36)
                        .padding(.top, 20)
                        .padding(.bottom, 32)
                        .frame(
                            maxWidth: portrait ? .infinity : 760,
                            alignment: .leading
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Programme")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct IOSProgramDetailArtworkBackdrop: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                IOSGuideDefaultBackdrop()

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .transition(.opacity)
                }

                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.42), location: 0),
                        .init(color: .black.opacity(0.16), location: 0.38),
                        .init(color: .black.opacity(0.82), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            let loaded = await IOSArtworkCache.shared.image(for: url)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) { image = loaded }
        }
    }
}

private func iosGuideInterfaceIsPortrait(fallback size: CGSize) -> Bool {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first(where: { $0.activationState == .foregroundActive })
        ?? scenes.first
    return scene?.effectiveGeometry.interfaceOrientation.isPortrait
        ?? (size.height >= size.width)
}
