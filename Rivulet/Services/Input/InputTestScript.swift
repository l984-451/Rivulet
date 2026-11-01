// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// The prompted remote-input test (#212, #232, #305): the presses to ask for and the pure
// state machine matching what arrived. Input comes from `InputProbe`, which sees presses the
// focus engine swallows. Select and Menu are recorded but not prompted.

import Foundation

/// One prompted press.
struct InputTestStep {
    /// Shown on screen, and reused as the transcript label.
    let prompt: String
    /// Matches `InputProbe`'s press names ("left", "playPause", …).
    let type: String
    /// A hold step wants a press longer than `InputConfig.holdThreshold`. A tap
    /// arriving instead is RECORDED as a tap rather than retried — "this remote
    /// cannot express a hold" is itself the finding, not a user error.
    let wantsHold: Bool
}

enum InputTestScript {
    /// Taps first so a remote that fails outright fails early, then the holds,
    /// which are what the #212 hypothesis turns on (a late or missing release
    /// makes every tap read as a hold, or blocks the tap recognizer entirely).
    static let steps: [InputTestStep] = [
        InputTestStep(prompt: String(localized: "Press Right"), type: "right", wantsHold: false),
        InputTestStep(prompt: String(localized: "Press Left"), type: "left", wantsHold: false),
        InputTestStep(prompt: String(localized: "Press Up"), type: "up", wantsHold: false),
        InputTestStep(prompt: String(localized: "Press Down"), type: "down", wantsHold: false),
        InputTestStep(prompt: String(localized: "Hold Right for 2 seconds"), type: "right", wantsHold: true),
        InputTestStep(prompt: String(localized: "Hold Left for 2 seconds"), type: "left", wantsHold: true),
        InputTestStep(prompt: String(localized: "Hold Up for 2 seconds"), type: "up", wantsHold: true),
        InputTestStep(prompt: String(localized: "Hold Down for 2 seconds"), type: "down", wantsHold: true),
        InputTestStep(prompt: String(localized: "Press Play/Pause"), type: "playPause", wantsHold: false)
    ]
}

/// Advances through `steps`, one prompt at a time, and builds the transcript.
/// Pure: fed `began`/`finished`/`timedOut` by the view controller, holds no
/// timers and touches no UI.
struct InputTestRun {

    /// How long a step waits before recording what did NOT arrive and moving
    /// on. A dead direction has to cost a bounded amount of time, or the run
    /// stalls on exactly the button the report is about.
    static let stepTimeout: TimeInterval = 10

    /// A repeating IR code storm can emit dozens of presses per second; the
    /// first few say everything the rest would.
    private static let maxExtras = 20
    private static let labelWidth = 26

    let steps: [InputTestStep]
    private(set) var index = 0
    /// One formatted line per completed step.
    private(set) var lines: [String] = []
    /// Presses that arrived but were not what the current step asked for.
    private(set) var extras: [String] = []
    private var droppedExtras = 0
    private var sawBegan = false

    init(steps: [InputTestStep] = InputTestScript.steps) {
        self.steps = steps
    }

    var currentStep: InputTestStep? { index < steps.count ? steps[index] : nil }
    var isFinished: Bool { index >= steps.count }
    var hasResults: Bool { !lines.isEmpty }

    /// A press of the expected type opened. Remembered so a step that times out
    /// can distinguish "nothing arrived" from "it began and never terminated" —
    /// the second is the #212 smoking gun and the first is #305's.
    mutating func began(type: String) {
        if type == currentStep?.type { sawBegan = true }
    }

    /// Returns true when this verdict completed the current step.
    @discardableResult
    mutating func finished(_ verdict: InputPressTracker.Verdict) -> Bool {
        guard let step = currentStep else {
            addExtra("after the last step: \(Self.describe(verdict))")
            return false
        }
        guard verdict.type == step.type else {
            addExtra("during “\(step.prompt)”: \(Self.describe(verdict))")
            return false
        }
        var outcome = Self.describe(verdict)
        if step.wantsHold && !verdict.isHold {
            outcome += "  ← asked for a HOLD"
        } else if !step.wantsHold && verdict.isHold {
            outcome += "  ← asked for a TAP"
        }
        record(step, outcome)
        return true
    }

    mutating func timedOut() {
        guard let step = currentStep else { return }
        record(step, sawBegan ? "began but NEVER TERMINATED" : "nothing received")
    }

    /// Screen and Sentry read the same text, so a screenshot and an event are
    /// never two different stories.
    func transcript(header: String) -> String {
        var out = [header, ""]
        out += lines
        if !extras.isEmpty {
            out.append("")
            out.append("Unprompted presses:")
            out += extras.map { "  \($0)" }
        }
        if droppedExtras > 0 {
            out.append("  (+\(droppedExtras) more suppressed)")
        }
        return out.joined(separator: "\n")
    }

    static func describe(_ verdict: InputPressTracker.Verdict) -> String {
        var text = "\(verdict.type) \(InputPressTracker.ms(verdict.duration)) "
        text += verdict.isHold ? "HOLD" : "TAP"
        text += " gc=\(verdict.sawGamepad ? "yes" : "no")"
        if verdict.cancelled { text += " (cancelled)" }
        return text
    }

    // MARK: Private

    private mutating func record(_ step: InputTestStep, _ outcome: String) {
        lines.append(Self.pad(step.prompt) + outcome)
        sawBegan = false
        index += 1
    }

    private mutating func addExtra(_ text: String) {
        guard extras.count < Self.maxExtras else {
            droppedExtras += 1
            return
        }
        extras.append(text)
    }

    private static func pad(_ text: String) -> String {
        let width = max(labelWidth, text.count + 2)
        return text + String(repeating: " ", count: width - text.count)
    }
}
