//
//  SampleBufferDisplayView.swift
//  Rivulet
//
//  SwiftUI wrapper for the video sink used by RivuletPlayer. Hosts either
//  AVSampleBufferDisplayLayer (default) or MetalVideoRenderer's UIView when a
//  Metal video sink is active (HLG content; opt-in via
//  SampleBufferRenderer.enableMetalVideoSink()).
//

import SwiftUI
import AVFoundation
import UIKit

/// SwiftUI view that displays video from a RivuletPlayer.
struct SampleBufferDisplayView: UIViewRepresentable {
    @ObservedObject var player: RivuletPlayer

    func makeUIView(context: Context) -> SampleBufferHostingView {
        let view = SampleBufferHostingView()
        view.update(displayLayer: player.displayLayer, metalView: player.renderer.metalRenderer?.view)
        return view
    }

    func updateUIView(_ uiView: SampleBufferHostingView, context: Context) {
        // Pipeline may switch sinks during playback start (e.g. on detecting
        // HLG in the first format description). The host responds idempotently.
        uiView.update(displayLayer: player.displayLayer, metalView: player.renderer.metalRenderer?.view)
    }
}

/// UIView that hosts either the AVSampleBufferDisplayLayer or a
/// MetalVideoRendererView. Whichever is currently active is laid out to fill
/// the bounds.
final class SampleBufferHostingView: UIView {
    private var displayLayer: AVSampleBufferDisplayLayer?
    private weak var metalView: UIView?
    private var activeSink: ActiveSink = .none

    private enum ActiveSink {
        case none
        case avsbl
        case metal
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func update(displayLayer: AVSampleBufferDisplayLayer, metalView: UIView?) {
        if let metalView {
            attachMetalSink(metalView)
        } else {
            attachAVSBLSink(displayLayer)
        }
    }

    private func attachAVSBLSink(_ displayLayer: AVSampleBufferDisplayLayer) {
        if activeSink == .avsbl, self.displayLayer === displayLayer { return }
        // Detach any prior metal view.
        if let metalView, metalView.superview === self {
            metalView.removeFromSuperview()
        }
        // Attach the AVSBL display layer.
        if displayLayer.superlayer !== layer {
            displayLayer.removeFromSuperlayer()
            displayLayer.frame = bounds
            displayLayer.videoGravity = .resizeAspect
            displayLayer.backgroundColor = UIColor.black.cgColor
            layer.addSublayer(displayLayer)
        }
        self.displayLayer = displayLayer
        self.metalView = nil
        activeSink = .avsbl
        setNeedsLayout()
    }

    private func attachMetalSink(_ metalView: UIView) {
        if activeSink == .metal, self.metalView === metalView { return }
        // Detach AVSBL.
        if let prior = displayLayer, prior.superlayer === layer {
            prior.removeFromSuperlayer()
        }
        // Attach the metal renderer's view.
        if metalView.superview !== self {
            metalView.removeFromSuperview()
            metalView.frame = bounds
            metalView.translatesAutoresizingMaskIntoConstraints = true
            metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(metalView)
        }
        self.metalView = metalView
        self.displayLayer = nil
        activeSink = .metal
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer?.frame = bounds
        metalView?.frame = bounds
    }
}
