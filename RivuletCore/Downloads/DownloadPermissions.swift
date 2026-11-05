// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Which servers' accounts may download. Each server is asked until it answers: a failed read is
/// not an answer, so it is asked again on the next pass instead of hiding Download for the session.
nonisolated struct DownloadPermissions: Sendable {
    private(set) var allowed: Set<String> = []
    private(set) var answered: Set<String> = []

    mutating func ask(_ providers: [any MediaProvider]) async {
        for provider in providers where !answered.contains(provider.id) {
            guard let yes = try? await provider.canDownloadMedia() else { continue }
            answered.insert(provider.id)
            if yes { allowed.insert(provider.id) }
        }
    }

    mutating func reset() {
        allowed = []
        answered = []
    }
}
