// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Whether an error is an ordinary task/URL cancellation rather than a real
/// playback failure. The user backing out of the preview carousel, or picking
/// a different item, cancels whatever load was in flight, and that must not be
/// wrapped into a `PlayerError`, reported to Sentry, or used to trigger the
/// HLS fallback (RIVULET-19). Both spellings are needed: structured
/// concurrency throws `CancellationError`, URLSession throws NSURLError -999,
/// and a cancelled load can surface as either depending on how far it got.
nonisolated func isCancellationError(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return true }
    return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
}
