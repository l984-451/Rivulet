// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AVPlayerLayerView.swift
//  Rivulet
//
//  UIViewRepresentable wrapping AVPlayerLayer for SwiftUI.
//

import SwiftUI
import AVFoundation

/// SwiftUI wrapper for AVPlayerLayer.
struct AVPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var fillsScreen = false

    func makeUIView(context: Context) -> AVPlayerUIView {
        let view = AVPlayerUIView(player: player)
        view.playerLayer.videoGravity = fillsScreen ? .resizeAspectFill : .resizeAspect
        return view
    }

    func updateUIView(_ uiView: AVPlayerUIView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = fillsScreen ? .resizeAspectFill : .resizeAspect
    }
}

/// UIView that uses AVPlayerLayer as its backing layer.
class AVPlayerUIView: UIView {

    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    init(player: AVPlayer) {
        super.init(frame: .zero)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
