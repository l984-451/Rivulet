//
//  SettingsComponents.swift
//  Rivulet
//
//  Reusable settings UI components for tvOS
//

import SwiftUI

// MARK: - Settings Section

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title.uppercased())
                .font(.system(size: 21, weight: .bold))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.5))
                .padding(.leading, 12)

            VStack(spacing: 12) {
                content
            }
            .padding(8)  // Room for scale effect
        }
    }
}

// MARK: - Settings Row (Navigation)

struct SettingsRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let action: () -> Void
    var focusTrigger: Int? = nil  // When non-nil and changes, claim focus

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 20) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(iconColor.gradient)
                        .frame(width: 64, height: 64)

                    Image(systemName: icon)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }

                // Text - white for dark glass background
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 29, weight: .medium))
                        .foregroundStyle(.white)

                    Text(subtitle)
                        .font(.system(size: 23))
                        .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()

                // Chevron
                Image(systemName: "chevron.right")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isFocused ? .white.opacity(0.8) : .white.opacity(0.4))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                isFocused ? .white.opacity(0.25) : .white.opacity(0.08),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(SettingsButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .onChange(of: focusTrigger) { _, newValue in
            if newValue != nil {
                isFocused = true
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }
}

/// Button style that removes tvOS default focus ring
struct SettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

// MARK: - Settings Info Row (Display Only)

struct SettingsInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.7))

            Spacer()

            Text(value)
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }
}

// MARK: - Settings Toggle Row

struct SettingsToggleRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 20) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(iconColor.gradient)
                        .frame(width: 64, height: 64)

                    Image(systemName: icon)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }

                // Text - white for dark glass background
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 29, weight: .medium))
                        .foregroundStyle(.white)

                    Text(subtitle)
                        .font(.system(size: 23))
                        .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()

                // On/Off text
                Text(isOn ? "On" : "Off")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(isOn ? .green : .white.opacity(0.5))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                isFocused ? .white.opacity(0.25) : .white.opacity(0.08),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(SettingsButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }
}

// MARK: - Settings Action Row (Button)

struct SettingsActionRow: View {
    let title: String
    var isDestructive: Bool = false
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack {
                Spacer()
                Text(title)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(isDestructive ? .red : .white)
                Spacer()
            }
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? (isDestructive ? .red.opacity(0.25) : .white.opacity(0.18)) : .white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isFocused ? (isDestructive ? .red.opacity(0.4) : .white.opacity(0.25)) : .white.opacity(0.08),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(SettingsButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }
}

// MARK: - Settings Picker Row

struct SettingsPickerRow<T: Hashable & CustomStringConvertible>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    @Binding var selection: T
    let options: [T]

    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            cycleToNextOption()
        } label: {
            HStack(spacing: 20) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(iconColor.gradient)
                        .frame(width: 64, height: 64)

                    Image(systemName: icon)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }

                // Text
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 29, weight: .medium))
                        .foregroundStyle(.white)

                    Text(subtitle)
                        .font(.system(size: 23))
                        .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()

                // Current selection
                Text(selection.description)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                isFocused ? .white.opacity(0.25) : .white.opacity(0.08),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(SettingsButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }

    private func cycleToNextOption() {
        guard let currentIndex = options.firstIndex(of: selection) else { return }
        let nextIndex = (currentIndex + 1) % options.count
        selection = options[nextIndex]
    }
}

// MARK: - Settings List Picker Row (Popup Selection)

struct SettingsListPickerRow<T: Hashable & CustomStringConvertible>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    @Binding var selection: T
    let options: [T]

    @FocusState private var isFocused: Bool
    @State private var showPicker = false

    var body: some View {
        Button {
            showPicker = true
        } label: {
            HStack(spacing: 20) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(iconColor.gradient)
                        .frame(width: 64, height: 64)

                    Image(systemName: icon)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }

                // Text
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 29, weight: .medium))
                        .foregroundStyle(.white)

                    Text(subtitle)
                        .font(.system(size: 23))
                        .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()

                // Current selection with chevron
                HStack(spacing: 12) {
                    Text(selection.description)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))

                    Image(systemName: "chevron.right")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(isFocused ? .white.opacity(0.8) : .white.opacity(0.4))
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                isFocused ? .white.opacity(0.25) : .white.opacity(0.08),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(SettingsButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        .sheet(isPresented: $showPicker) {
            ListPickerSheet(
                title: title,
                selection: $selection,
                options: options,
                isPresented: $showPicker
            )
        }
    }
}

// MARK: - List Picker Sheet

struct ListPickerSheet<T: Hashable & CustomStringConvertible>: View {
    let title: String
    @Binding var selection: T
    let options: [T]
    @Binding var isPresented: Bool

    @FocusState private var focusedOption: T?

    var body: some View {
        VStack(spacing: 24) {
            // Header
            Text(title)
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(.white)
                .padding(.top, 40)

            // Options list
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(options, id: \.self) { option in
                        ListPickerOptionRow(
                            option: option,
                            isSelected: selection == option,
                            isFocused: focusedOption == option,
                            onSelect: {
                                selection = option
                                isPresented = false
                            }
                        )
                        .focused($focusedOption, equals: option)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 600)

            Spacer(minLength: 0)
        }
        .padding(.bottom, 40)
        .frame(width: 500)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(.black.opacity(0.3))
        )
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .onAppear {
            // Focus the currently selected option
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focusedOption = selection
            }
        }
        #if os(tvOS)
        .onExitCommand {
            isPresented = false
        }
        #endif
    }
}

// MARK: - List Picker Option Row

struct ListPickerOptionRow<T: CustomStringConvertible>: View {
    let option: T
    let isSelected: Bool
    let isFocused: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                Text(option.description)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                isFocused ? .white.opacity(0.25) : .white.opacity(0.08),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(SettingsButtonStyle())
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }
}

// MARK: - Connect Button

struct ConnectButton: View {
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "link")
                .font(.system(size: 26, weight: .semibold))
            Text("Connect to Plex")
                .font(.system(size: 28, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 40)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isFocused ? Color.blue : Color.blue.opacity(0.85))
        )
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .shadow(color: .blue.opacity(isFocused ? 0.4 : 0), radius: 12, y: 4)
        .focusable()
        .focused($isFocused)
        .onTapGesture {
            action()
        }
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}
