//
//  SummarySheet.swift
//  Rivulet
//
//  Full-screen sheet that surfaces a long item description in a focusable,
//  scrollable form. The hero text on the detail page is `lineLimit(3)`-
//  truncated; this sheet is the path to read the rest. Matches the
//  affordance Plex's first-party tvOS client and Infuse both provide.
//

import SwiftUI

struct SummarySheet: View {
    let title: String
    let summary: String

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedParagraph: Int?

    /// Split the summary on sentence boundaries and pack into ~300-char
    /// chunks. Each chunk becomes a focusable row so the touchpad can
    /// scroll long descriptions smoothly.
    private var summaryChunks: [String] {
        let sentences = summary.components(separatedBy: ". ")
        var chunks: [String] = []
        var currentChunk = ""

        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let sentenceWithPeriod = trimmed.hasSuffix(".") ? trimmed : trimmed + "."

            if currentChunk.isEmpty {
                currentChunk = sentenceWithPeriod
            } else if currentChunk.count + sentenceWithPeriod.count < 300 {
                currentChunk += " " + sentenceWithPeriod
            } else {
                chunks.append(currentChunk)
                currentChunk = sentenceWithPeriod
            }
        }
        if !currentChunk.isEmpty { chunks.append(currentChunk) }

        return chunks.isEmpty ? [summary] : chunks
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 40) {
                Text(title)
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1200)
                    .padding(.horizontal, 80)
                    .padding(.top, 60)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(summaryChunks.enumerated()), id: \.offset) { index, chunk in
                        SummaryParagraphRow(
                            text: chunk,
                            isFocused: focusedParagraph == index
                        )
                        .focusable()
                        .focused($focusedParagraph, equals: index)
                    }
                }
                .frame(maxWidth: 1200)
                .padding(.horizontal, 80)

                SummaryDoneButton(isFocused: focusedParagraph == -1) {
                    dismiss()
                }
                .focused($focusedParagraph, equals: -1)
                .padding(.top, 20)
                .padding(.bottom, 80)
            }
            .padding(8)
        }
        .onExitCommand {
            dismiss()
        }
    }
}

/// Focusable text chunk — minimal styling for continuous reading.
private struct SummaryParagraphRow: View {
    let text: String
    let isFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isFocused ? .white.opacity(0.6) : .clear)
                .frame(width: 3)

            Text(text)
                .font(.system(size: 26))
                .foregroundStyle(isFocused ? .white : .white.opacity(0.8))
                .multilineTextAlignment(.leading)
                .lineSpacing(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// Done button — glass styling consistent with other sheet dismiss controls.
private struct SummaryDoneButton: View {
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Done")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(isFocused ? .black : .white)
                .padding(.horizontal, 60)
                .padding(.vertical, 18)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isFocused ? Color.white : Color.white.opacity(0.18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(
                                    .white.opacity(isFocused ? 0 : 0.3),
                                    lineWidth: 1
                                )
                        )
                )
        }
        .buttonStyle(SettingsButtonStyle())
        .scaleEffect(isFocused ? 1.06 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }
}
