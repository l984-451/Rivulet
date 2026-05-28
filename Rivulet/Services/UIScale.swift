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
