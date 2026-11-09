// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  VersionPickerPopup.swift
//  Rivulet
//
//  The "Play Version" list for an item with more than one file. Built on the
//  tile menu popup; the pick plays once and is not remembered.
//

import UIKit

extension VersionPicker {
    static func present(_ versions: [MediaSource], from host: UIViewController,
                        sourceFrame: CGRect?, onPick: @escaping (String) -> Void) {
        guard versions.count >= 2 else { return }
        let rows = zip(versions, labels(for: versions)).map { source, label in
            TileMenuAction(verbatim: label, systemImage: "play.fill") { onPick(source.id) }
        }
        let popup = TileMenuPopupViewController(sections: [rows], sourceFrame: sourceFrame,
                                                header: TileMenuHeader(title: String(localized: "Play Version")))
        // The popup runs its own entrance from `sourceFrame`.
        host.topmostPresented.present(popup, animated: false)
    }
}
