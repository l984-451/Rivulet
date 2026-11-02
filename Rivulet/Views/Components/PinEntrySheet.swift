// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PinEntrySheet.swift
//  Rivulet
//
//  tvOS number-pad PIN entry for switching to a PIN-protected Plex home
//  profile. Presented from the profile picker overlay, the sidebar profile
//  switcher, and the UIKit settings profile flow.
//

import SwiftUI

// MARK: - Profile Avatar

private struct ProfileAvatar: View {
    let user: PlexHomeUser
    let size: CGFloat

    var body: some View {
        Group {
            if let thumbURL = user.thumb, let url = URL(string: thumbURL) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .empty:
                        avatarPlaceholder
                    case .failure:
                        avatarPlaceholder
                    @unknown default:
                        avatarPlaceholder
                    }
                }
            } else {
                avatarPlaceholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle()
                .strokeBorder(Color.primary.opacity(0.2), lineWidth: 2)
        )
    }

    private var avatarPlaceholder: some View {
        ZStack {
            Circle()
                .fill(profileColor.gradient)

            Text(user.displayName.prefix(1).uppercased())
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var profileColor: Color {
        let colors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo]
        return colors[abs(user.id) % colors.count]
    }
}

// MARK: - PIN Entry Sheet (tvOS number pad)

struct PinEntrySheet: View {
    let user: PlexHomeUser
    @Binding var error: String?
    let onSubmit: (String, Bool) -> Void
    let onCancel: () -> Void

    @State private var pin: String = ""
    @State private var rememberPin: Bool = false
    @FocusState private var focusedButton: String?

    private let numberPadLayout: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["delete", "0", "submit"]
    ]

    var body: some View {
        VStack(spacing: 40) {
            // Header
            VStack(spacing: 16) {
                ProfileAvatar(user: user, size: 100)

                Text(user.displayName)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(Color.primary)

                Text("Enter PIN to switch profile")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.primary.opacity(0.6))
            }

            // PIN display
            VStack(spacing: 16) {
                HStack(spacing: 20) {
                    ForEach(0..<4, id: \.self) { index in
                        PinDigitView(
                            digit: pin.count > index ? "\u{2022}" : "",
                            isFilled: pin.count > index
                        )
                    }
                }

                if let error = error {
                    Text(error)
                        .font(.system(size: 22))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }

            // Number pad
            VStack(spacing: 12) {
                ForEach(numberPadLayout, id: \.self) { row in
                    HStack(spacing: 12) {
                        ForEach(row, id: \.self) { key in
                            PinPadButton(
                                key: key,
                                pin: $pin,
                                isFocused: focusedButton == key,
                                onSubmit: {
                                    if pin.count == 4 {
                                        onSubmit(pin, rememberPin)
                                    }
                                }
                            )
                            .focused($focusedButton, equals: key)
                        }
                    }
                }
            }

            // Remember PIN toggle
            RememberPinToggle(isOn: $rememberPin, isFocused: focusedButton == "remember")
                .focused($focusedButton, equals: "remember")

            // Cancel button
            Button("Cancel") {
                onCancel()
            }
            .buttonStyle(.plain)
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(Color.primary.opacity(0.6))
            .focused($focusedButton, equals: "cancel")
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.clear)
        .onExitCommand {
            onCancel()
        }
        .onAppear {
            focusedButton = "1"
        }
        .onChange(of: pin) { _, newValue in
            if newValue.count == 4 {
                onSubmit(newValue, rememberPin)
            }
        }
    }
}

// MARK: - Remember PIN Toggle

private struct RememberPinToggle: View {
    @Binding var isOn: Bool
    let isFocused: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 16) {
                Text("Remember PIN")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Color.primary)

                Spacer()

                Text(isOn ? String(localized: "On") : String(localized: "Off"))
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(isOn ? .green : Color.primary.opacity(0.5))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? Color.primary.opacity(0.18) : Color.primary.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isFocused ? Color.primary.opacity(0.25) : Color.primary.opacity(0.08),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(NoFocusEffectButtonStyle())
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }
}

// MARK: - Number Pad Button

private struct PinPadButton: View {
    let key: String
    @Binding var pin: String
    let isFocused: Bool
    let onSubmit: () -> Void

    var body: some View {
        Button {
            handleTap()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(backgroundColor)
                    .frame(width: 90, height: 70)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                isFocused ? Color.primary.opacity(0.25) : Color.primary.opacity(0.08),
                                lineWidth: 1
                            )
                    )

                if key == "delete" {
                    Image(systemName: "delete.left.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.primary)
                } else if key == "submit" {
                    Image(systemName: "checkmark")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Color.primary)
                } else {
                    Text(key)
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(Color.primary)
                }
            }
        }
        .buttonStyle(NoFocusEffectButtonStyle())
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }

    private var backgroundColor: Color {
        if key == "submit" && pin.count == 4 {
            return .blue.opacity(0.6)
        }
        return isFocused ? Color.primary.opacity(0.18) : Color.primary.opacity(0.08)
    }

    private func handleTap() {
        switch key {
        case "delete":
            if !pin.isEmpty {
                pin.removeLast()
            }
        case "submit":
            onSubmit()
        default:
            if pin.count < 4 {
                pin += key
            }
        }
    }
}

private struct PinDigitView: View {
    let digit: String
    let isFilled: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(isFilled ? 0.2 : 0.1))
                .frame(width: 60, height: 80)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.3), lineWidth: 2)
                )

            Text(digit)
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(Color.primary)
        }
    }
}
