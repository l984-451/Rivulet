// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AetherVideoSurfaceView.swift
//  Rivulet
//
//  SwiftUI wrapper for AetherEngine's render surface. The engine attaches the
//  active backend's layer and re-attaches it across session swaps. Never bind
//  an AVPlayerLayer to `currentAVPlayer` instead: that covers one backend only.
//

import SwiftUI
import AetherEngine

struct AetherVideoSurfaceView: UIViewRepresentable {
    let player: AetherPlayer
    var fillsScreen = false

    @MainActor
    final class Coordinator {
        var boundPlayer: AetherPlayer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> AetherPlayerView {
        let view = AetherPlayerView()
        player.bind(view: view)
        player.fillsScreen = fillsScreen
        context.coordinator.boundPlayer = player
        return view
    }

    func updateUIView(_ uiView: AetherPlayerView, context: Context) {
        if player.fillsScreen != fillsScreen { player.fillsScreen = fillsScreen }
        guard context.coordinator.boundPlayer !== player else { return }
        context.coordinator.boundPlayer?.unbind(view: uiView)
        player.bind(view: uiView)
        context.coordinator.boundPlayer = player
    }

    static func dismantleUIView(_ uiView: AetherPlayerView, coordinator: Coordinator) {
        coordinator.boundPlayer?.unbind(view: uiView)
        coordinator.boundPlayer = nil
    }
}
