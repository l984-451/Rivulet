// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
#if os(iOS)
import OSLog
import StoreKit
import SwiftUI
import UIKit
#endif

@MainActor
enum IOSAutoLandscapePreference {
    static let key = "iosAutoLandscapeOnPlayback"

    static func isEnabled(isAvailable: Bool, defaults: UserDefaults = .standard) -> Bool {
        isAvailable && defaults.bool(forKey: key)
    }
}

#if os(iOS)
@MainActor
enum IOSPlaybackBeta {
    private static var isTestFlight: Bool?

    static func isAvailable() async -> Bool {
        #if DEBUG
        // The same opt-in is available when running a local development build from Xcode.
        return true
        #elseif targetEnvironment(simulator)
        return false
        #else
        if let isTestFlight { return isTestFlight }
        // Distribution is decided at runtime: the same archive can be promoted to the App Store.
        guard case .verified(let transaction)? = try? await AppTransaction.shared else { return false }
        let isTestFlight = transaction.environment == .sandbox
        self.isTestFlight = isTestFlight
        return isTestFlight
        #endif
    }
}

/// The probe uses the player cover's own window scene, not an arbitrary active scene (e.g. CarPlay).
struct IOSAutoLandscape: UIViewControllerRepresentable {
    let isPlayerPresented: @MainActor () -> Bool

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.isPlayerPresented = isPlayerPresented
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.isPlayerPresented = isPlayerPresented
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.restoreOrientation()
    }

    final class Controller: UIViewController {
        var isPlayerPresented: @MainActor () -> Bool = { false }
        private var entry: Task<Void, Never>?
        private weak var rotatedScene: UIWindowScene?
        private var originalOrientation: UIInterfaceOrientationMask?
        private static let logger = Logger(subsystem: "com.gstudios.Rivulet", category: "PlaybackOrientation")

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard entry == nil, UserDefaults.standard.bool(forKey: IOSAutoLandscapePreference.key) else { return }
            entry = Task { [weak self] in
                let isAvailable = await IOSPlaybackBeta.isAvailable()
                guard !Task.isCancelled, let self, isPlayerPresented(), let scene = view.window?.windowScene,
                      IOSAutoLandscapePreference.isEnabled(isAvailable: isAvailable) else { return }
                let orientation = scene.effectiveGeometry.interfaceOrientation
                guard orientation.isPortrait else { return }
                rotatedScene = scene
                originalOrientation = orientation == .portraitUpsideDown ? .portraitUpsideDown : .portrait
                let logger = Self.logger
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { [weak self] error in
                    logger.debug("Landscape request declined: \(error.localizedDescription, privacy: .private)")
                    Task { @MainActor [weak self] in
                        self?.rotatedScene = nil
                        self?.originalOrientation = nil
                    }
                }
            }
        }

        func restoreOrientation() {
            entry?.cancel()
            entry = nil
            guard let rotatedScene, let originalOrientation else { return }
            self.rotatedScene = nil
            self.originalOrientation = nil
            // Also supersede a landscape request that is still in flight on a quick dismissal.
            let logger = Self.logger
            rotatedScene.requestGeometryUpdate(.iOS(interfaceOrientations: originalOrientation)) { error in
                logger.debug("Playback orientation request declined: \(error.localizedDescription, privacy: .private)")
            }
        }
    }
}
#endif
