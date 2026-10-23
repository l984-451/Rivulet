// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  UIScale.swift
//  Rivulet
//
//  Global UI scale system for adjusting interface element sizes
//

import SwiftUI

// MARK: - Display Size

/// Controls the overall scale of UI elements throughout the app
enum DisplaySize: String, CaseIterable, CustomStringConvertible {
    case normal = "normal"
    case large = "large"
    case extraLarge = "extraLarge"

    var description: String {
        switch self {
        case .normal: return "Normal"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        }
    }

    /// Scale multiplier for dimensions and font sizes
    var scale: CGFloat {
        switch self {
        case .normal: return 1.0
        case .large: return 1.15
        case .extraLarge: return 1.3
        }
    }

    /// Posters fully visible across a shelf or library grid row: the most whole columns of the
    /// Apple TV app grid (`MediaRowMetrics`) whose tiles are at least `scale` times the Normal tile,
    /// so a row still ends on a whole tile and its peek. Normal 6, Large 5 (1.23×), Extra Large 4 (1.58×).
    var posterColumns: Int {
        switch self {
        case .normal: return 6
        case .large: return 5
        case .extraLarge: return 4
        }
    }

    /// The `displaySize` setting as stored (Settings › Appearance › Display Size).
    static let storageKey = "displaySize"

    static var current: DisplaySize {
        DisplaySize(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .normal
    }
}

// MARK: - Environment Key

private struct UIScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    /// Global UI scale factor (1.0 = normal, 1.15 = large, 1.3 = extra large)
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}

// MARK: - Convenience Extensions

extension View {
    /// Applies the display size scale to the environment
    func displaySize(_ size: DisplaySize) -> some View {
        environment(\.uiScale, size.scale)
    }
}

// MARK: - Scaled Dimensions

/// Standard UI dimensions that scale with the display size setting
enum ScaledDimensions {
    // Poster card dimensions (base sizes - larger for fewer items per row)
    static let posterWidth: CGFloat = 260
    static let posterHeight: CGFloat = 390
    static let squarePosterSize: CGFloat = 260  // For music items

    // Continue Watching card dimensions (wide landscape, ~7:5)
    static let continueWatchingWidth: CGFloat = 392
    static let continueWatchingHeight: CGFloat = 280

    // Grid column constraints
    static let gridMinWidth: CGFloat = 260
    static let gridMaxWidth: CGFloat = 300
    static let gridSpacing: CGFloat = 32

    // Typography
    static let posterTitleSize: CGFloat = 24
    static let posterSubtitleSize: CGFloat = 19
    static let sectionTitleSize: CGFloat = 30
    static let heroTitleSize: CGFloat = 56

    // Spacing
    static let rowHorizontalPadding: CGFloat = 48
    static let rowVerticalPadding: CGFloat = 32
    static let rowItemSpacing: CGFloat = 40

    // Corner radii
    static let posterCornerRadius: CGFloat = 16

    /// Apply scale factor to a dimension
    static func scaled(_ value: CGFloat, by scale: CGFloat) -> CGFloat {
        value * scale
    }
}
