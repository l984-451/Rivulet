// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Upcoming recordings and the rules behind them, across every source that records.
struct IOSLiveRecordingsView: View {
    @ObservedObject private var store = LiveTVDataStore.shared
    @StateObject private var recorder = IOSLiveRecorder()
    @State private var rules: [LiveTVRecordingRule] = []
    @State private var isLoading = true

    private var upcoming: [LiveTVScheduledRecording] {
        store.scheduledRecordings
            .filter { $0.status == .scheduled || $0.status == .recording }
            .sorted { $0.startTime < $1.startTime }
    }

    var body: some View {
        List {
            Section("Upcoming") {
                if upcoming.isEmpty, !isLoading {
                    Text("Nothing is scheduled. Long-press a programme in the guide to record it.")
                        .foregroundStyle(.secondary)
                }
                ForEach(upcoming) { recording in
                    row(recording)
                        .swipeActions {
                            Button(recording.status == .recording ? "Stop" : "Cancel", role: .destructive) {
                                recorder.cancel(recording)
                            }
                            if recording.ruleIsSeries {
                                Button("Cancel Series") { recorder.cancelSeries(of: recording) }
                                    .tint(.orange)
                            }
                        }
                        .contextMenu {
                            Button(recording.status == .recording ? "Stop Recording" : "Cancel Recording",
                                   systemImage: "stop.circle", role: .destructive) { recorder.cancel(recording) }
                            if recording.ruleIsSeries {
                                Button("Cancel Series", systemImage: "square.stack.3d.up.slash", role: .destructive) {
                                    recorder.cancelSeries(of: recording)
                                }
                            }
                        }
                }
            }
            if !rules.isEmpty {
                Section("Series and Rules") {
                    ForEach(rules) { rule in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.title)
                            if let detail = rule.detail, !detail.isEmpty {
                                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("Delete Rule", role: .destructive) {
                                recorder.delete(rule) { Task { await reload() } }
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if isLoading, upcoming.isEmpty, rules.isEmpty { ProgressView() }
        }
        .navigationTitle("Recordings")
        .task { await reload() }
        .refreshable { await reload() }
        .onChange(of: store.scheduledRecordings) { Task { rules = await store.recordingRules() } }
        .liveRecorder(recorder)
    }

    private func reload() async {
        await store.refreshScheduledRecordings()
        rules = await store.recordingRules()
        isLoading = false
    }

    private func row(_ recording: LiveTVScheduledRecording) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.title)
                if let subtitle = recording.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline)
                }
                Text(detail(recording))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if recording.status == .recording {
                IOSLivePill(text: "REC", dot: true, style: .red)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(recording.status == .recording ? "Recording now" : "")
    }

    private func detail(_ recording: LiveTVScheduledRecording) -> String {
        let day = Calendar.current.isDateInToday(recording.startTime)
            ? "Today"
            : recording.startTime.formatted(.dateTime.weekday(.wide).month().day())
        let time = Date.FormatStyle.dateTime.hour().minute()
        let range = "\(recording.startTime.formatted(time)) to \(recording.endTime.formatted(time))"
        return [day, range, recording.channelName].compactMap { $0 }.joined(separator: " · ")
    }
}
