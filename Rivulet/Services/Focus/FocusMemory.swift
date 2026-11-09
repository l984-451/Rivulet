// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Last-focused item per section key, for SwiftUI focus restoration.
/// Use with `.focusSection()` and `.remembersFocus(key:focusedId:)`.
@MainActor
final class FocusMemory {
    static let shared = FocusMemory()

    private var memory: [String: String] = [:]

    private init() {}

    /// Remember the currently focused item for a section
    func remember(_ itemId: String, for key: String) {
        memory[key] = itemId
    }

    /// Recall the last focused item for a section
    func recall(for key: String) -> String? {
        memory[key]
    }

    /// Forget the focus for a specific section
    func forget(key: String) {
        memory.removeValue(forKey: key)
    }

    /// Clear all focus memory
    func clear() {
        memory.removeAll()
    }

    /// Check if there's a remembered focus for a section
    func hasMemory(for key: String) -> Bool {
        memory[key] != nil
    }
}

// MARK: - Environment Key

private struct FocusMemoryKey: EnvironmentKey {
    static let defaultValue = FocusMemory.shared
}

extension EnvironmentValues {
    var focusMemory: FocusMemory {
        get { self[FocusMemoryKey.self] }
        set { self[FocusMemoryKey.self] = newValue }
    }
}

// MARK: - View Modifier


/// View modifier that remembers and restores focus for a section
///
/// Note: Uses onChange to redirect focus after tvOS picks a default.
/// This may cause a brief visual flash (1-2 frames) when redirecting focus.
/// This is a fundamental SwiftUI limitation - there's no way to intercept
/// focus BEFORE the visual update in pure SwiftUI.
struct FocusMemoryModifier: ViewModifier {
    let memoryKey: String
    var focusedId: FocusState<String?>.Binding
    var restoreOnEntry: Bool = true
    @Environment(\.focusMemory) private var focusMemory

    #if DEBUG
    private func debugLog(_ event: String, extra: String = "") {
    }
    #else
    private func debugLog(_ event: String, extra: String = "") {}
    #endif

    func body(content: Content) -> some View {
        content
            .onChange(of: focusedId.wrappedValue) { oldValue, newValue in
                debugLog("focusChanged", extra: "old=\(oldValue ?? "nil") new=\(newValue ?? "nil")")
                // Focus is entering this section (was nil, now has value)
                if restoreOnEntry, oldValue == nil, let newValue = newValue {
                    // Check if we have a remembered value that's different
                    if let remembered = focusMemory.recall(for: memoryKey),
                       remembered != newValue {
                        debugLog("redirectToRemembered", extra: "new=\(newValue) remembered=\(remembered)")
                        // Redirect to remembered item instantly (no animation)
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            focusedId.wrappedValue = remembered
                        }
                        return
                    }
                }

                // Remember the new focus (only if not nil)
                if let id = newValue {
                    focusMemory.remember(id, for: memoryKey)
                    debugLog("remembered", extra: "id=\(id)")
                }
            }
    }
}

extension View {
    /// Remembers this section's focused item and restores it when focus re-enters.
    /// Do not combine with `.scrollPosition()`; let the focus engine scroll.
    /// `restoreOnEntry: false` remembers without redirecting on entry.
    func remembersFocus(
        key: String,
        focusedId: FocusState<String?>.Binding,
        restoreOnEntry: Bool = true
    ) -> some View {
        modifier(FocusMemoryModifier(memoryKey: key, focusedId: focusedId, restoreOnEntry: restoreOnEntry))
    }
}

