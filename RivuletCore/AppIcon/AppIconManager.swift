// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

//
//  AppIconManager.swift
//  RivuletCore
//
//  Manages alternate app icons and user icon preferences across iOS and tvOS.
//

import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

public enum AppIconOption: String, CaseIterable, Identifiable, Sendable {
    case defaultIcon = "default"
    case simpleColor = "simple-color"
    case simpleWhite = "simple-white"
    case pixel = "pixel"

    public init?(rawValue: String) {
        switch rawValue {
        case "default":
            self = .defaultIcon
        case "simple-color", "simple-colour", "simple_color", "simple_colour", "simple-dark", "simple_dark":
            self = .simpleColor
        case "simple-white", "simple_white", "simple-light", "simple_light":
            self = .simpleWhite
        case "pixel":
            self = .pixel
        default:
            return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .defaultIcon: return "default"
        case .simpleColor: return "simple-color"
        case .simpleWhite: return "simple-white"
        case .pixel: return "pixel"
        }
    }

    public static var simpleDark: AppIconOption { .simpleColor }
    public static var simpleLight: AppIconOption { .simpleWhite }

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .defaultIcon: return "Default"
        case .simpleColor: return "Simple (Colour)"
        case .simpleWhite: return "Simple (White)"
        case .pixel: return "Pixel"
        }
    }

    /// The alternate icon name declared in Info.plist / Asset catalog.
    /// `nil` indicates the primary (default) app icon.
    public var alternateIconName: String? {
        switch self {
        case .defaultIcon: return nil
        case .simpleColor: return "AppIconSimpleColor"
        case .simpleWhite: return "AppIconSimpleWhite"
        case .pixel: return "AppIconPixel"
        }
    }

    /// Preview image asset name in xcassets.
    public var previewImageName: String {
        switch self {
        case .defaultIcon: return "AppIconPreviewDefault"
        case .simpleColor: return "AppIconPreviewSimpleColor"
        case .simpleWhite: return "AppIconPreviewSimpleWhite"
        case .pixel: return "AppIconPreviewPixel"
        }
    }
}

public final class AppIconManager: ObservableObject {
    public static let shared = AppIconManager()

    public static let storageKey = "appIcon"
    public static let didChangeNotification = Notification.Name("AppIconManagerDidChangeNotification")

    @Published public private(set) var currentIcon: AppIconOption

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey) ?? AppIconOption.defaultIcon.rawValue
        currentIcon = AppIconOption(rawValue: stored) ?? .defaultIcon
    }

    public func setIcon(_ option: AppIconOption) {
        guard currentIcon != option else { return }
        currentIcon = option
        UserDefaults.standard.set(option.rawValue, forKey: Self.storageKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: option)
        applyToSystem(option)
    }

    public func syncWithSystem() {
        applyToSystem(currentIcon)
    }

    private func applyToSystem(_ option: AppIconOption) {
        #if canImport(UIKit)
        DispatchQueue.main.async {
            guard UIApplication.shared.supportsAlternateIcons else {
                print("AppIconManager: System reports supportsAlternateIcons = false")
                return
            }
            let targetIconName = option.alternateIconName
            print("AppIconManager: Applying icon '\(String(describing: targetIconName))' (current='\(String(describing: UIApplication.shared.alternateIconName))')")
            if UIApplication.shared.alternateIconName != targetIconName {
                UIApplication.shared.setAlternateIconName(targetIconName) { error in
                    if let error = error {
                        print("AppIconManager: Failed to set alternate icon to '\(String(describing: targetIconName))': \(error.localizedDescription)")
                    } else {
                        print("AppIconManager: Successfully set alternate icon to '\(String(describing: targetIconName))'")
                    }
                }
            }
        }
        #endif
    }
}
