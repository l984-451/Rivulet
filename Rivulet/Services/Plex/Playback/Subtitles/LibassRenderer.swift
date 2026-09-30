// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LibassRenderer.swift
//  Rivulet
//
//  libass for ASS/SSA subtitles. The library, renderer and track are confined
//  to one serial queue: libass has no internal locking.
//

import CoreGraphics
import Foundation
import Libass

nonisolated final class LibassRenderer: @unchecked Sendable {

    /// The linked libass version, `LIBASS_VERSION` of the build (0x01705000 is 0.17.5).
    static var libraryVersion: Int32 { ass_library_version() }
}
