// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  CardStatsView.swift
//  Rivulet
//
//  The Advanced tab of the player's Now Playing popup — AetherEngine's live
//  "stats for nerds" telemetry. Built lazily by `PlayerInfoTabsView` on the
//  first tab-over and ticked 1 Hz only while it is the visible tab. Reads an
//  app-side `AetherAdvancedStats` snapshot on each tick (a pure engine read;
//  the telemetry is already sampled by the engine). Rows self-prune when
//  their source field is nil — the engine's nils are path-asymmetric — so a
//  software-decode session and a native session show different subsets.
//
//  Shares `InfoScrollView` and `PlayerInfoSheetStyle` with the Info tab so the
//  two sheets are visually identical by construction.
//

import UIKit

final class CardStatsView: UIView, InfoTabSheet {

    private let provider: () -> AetherAdvancedStats?
    private let scrollView = InfoScrollView()
    private let stack = UIStackView()

    /// Per-section UI, built ONCE in declaration order. The `pairRows` are the
    /// focus targets and are never torn down — a redistribute only re-parents
    /// the persistent labels into them and toggles `isHidden`. Tearing a focus
    /// target down mid-tick would yank focus out of the sheet, which is exactly
    /// why the pool exists rather than rebuilding rows per tick.
    private struct SectionUI {
        /// THE focus target: one stop per section, not per line. Eleven stops in
        /// a stats sheet gave the user no sense of where focus was and made
        /// walking back to the tabs a ten-press job.
        let focusRow: InfoFocusRowView
        let container: UIStackView          // label + grid, inside `focusRow`
        let pairRows: [InfoFocusRowView]    // plain two-up lines, NOT focusable
    }
    private var sectionUIs: [SectionUI] = []

    /// One persistent label per declared row, keyed by row title. A same-shape
    /// tick just rewrites `attributedText` here and never touches the view
    /// hierarchy at all.
    private var rowLabels: [String: UILabel] = [:]
    private lazy var gatheringLabel = PlayerInfoSheetStyle.bodyLabel("Gathering stats…", secondary: true)

    private var liveTickTimer: Timer?
    private var isActiveTab = false

    /// The set of row titles currently rendered. When the next tick's present
    /// set differs (a field appeared/disappeared, or the empty→populated
    /// transition), the section contents are rebuilt; otherwise values update
    /// in place.
    private var renderedSignature: Set<String> = []
    /// Distinct from an empty signature so the "Gathering stats…" placeholder
    /// and a genuinely-empty row set don't collide.
    private var renderedGathering = false

    /// Last value rendered per row title. A tick only touches the rows whose
    /// value actually CHANGED — most of this sheet is static or slow-moving,
    /// and crossfading an unchanged value would pulse the whole sheet every
    /// second.
    private var renderedValues: [String: String] = [:]

    /// Long enough to read as a fade rather than a flicker, short enough to
    /// finish inside the 1 Hz tick.
    private static let valueFadeDuration: TimeInterval = 0.25

    var onFocusChange: ((Bool) -> Void)? {
        didSet { scrollView.onFocusChange = onFocusChange }
    }

    var infoScrollView: InfoScrollView { scrollView }

    init(provider: @escaping () -> AetherAdvancedStats?) {
        self.provider = provider
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        liveTickTimer?.invalidate()
    }

    // MARK: - Row model

    private struct RowSpec {
        let title: String
        let value: (AetherAdvancedStats) -> String?
    }
    private struct SectionSpec {
        let name: String
        let rows: [RowSpec]
    }

    private static let sections: [SectionSpec] = [
        SectionSpec(name: "DECODE", rows: [
            RowSpec(title: "Backend", value: { $0.backend }),
            RowSpec(title: "Audio Bridge", value: { $0.audioBridge }),
            RowSpec(title: "Audio Delivery", value: { $0.audioDelivery }),
        ]),
        SectionSpec(name: "STREAM", rows: [
            RowSpec(title: "Bitrate", value: { $0.instantBitrateMbps.map(PlayerInfoSheetStyle.mbps) }),
            RowSpec(title: "Avg Bitrate", value: { $0.averageBitrateMbps.map(PlayerInfoSheetStyle.mbps) }),
            RowSpec(title: "Frame Rate", value: { $0.observedFps.map(PlayerInfoSheetStyle.fps) }),
            RowSpec(title: "Dropped Frames", value: { $0.droppedFrameCount.map { "\($0)" } }),
            RowSpec(title: "Audio Bitrate", value: { $0.audioBridgeBitrateMbps.map(PlayerInfoSheetStyle.mbps) }),
        ]),
        SectionSpec(name: "BUFFER / NETWORK", rows: [
            RowSpec(title: "Buffer", value: { $0.forwardBufferSeconds.map(PlayerInfoSheetStyle.bufferSeconds) }),
            RowSpec(title: "Cached", value: { $0.cachedBytes.map(PlayerInfoSheetStyle.fileSize) }),
            RowSpec(title: "Throughput", value: { $0.networkThroughputMbps.map(PlayerInfoSheetStyle.mbps) }),
            RowSpec(title: "Transferred", value: { $0.networkTransferredBytes.map(PlayerInfoSheetStyle.fileSize) }),
            RowSpec(title: "A/V Sync", value: { $0.avSyncGapMs.map(PlayerInfoSheetStyle.milliseconds) }),
        ]),
        SectionSpec(name: "ENGINE", rows: [
            RowSpec(title: "Producer Restarts", value: { $0.producerRestartCount.map { "\($0)" } }),
            RowSpec(title: "Muxed", value: { $0.muxedBytesLifetime.map(PlayerInfoSheetStyle.fileSize) }),
            RowSpec(title: "Server Sent", value: { $0.serverBytesSentLifetime.map(PlayerInfoSheetStyle.fileSize) }),
            RowSpec(title: "Server Requests", value: { $0.serverRequestCount.map { "\($0)" } }),
            RowSpec(title: "Demuxer Fetched", value: { $0.demuxerBytesFetched.map(PlayerInfoSheetStyle.fileSize) }),
            RowSpec(title: "Audio Bridge Bytes", value: { $0.audioBridgeLiveBytes.map { PlayerInfoSheetStyle.fileSize(Int64($0)) } }),
            RowSpec(title: "Memory", value: { $0.rssMb.map { "\($0) MB" } }),
        ]),
    ]

    // MARK: - Layout

    private func setupViews() {
        stack.axis = .vertical
        stack.spacing = 12
        // .fill so the two-column section grids stretch to the full sheet
        // width and their columns split it evenly (matches CardInfoView).
        stack.alignment = .fill
        scrollView.addSubview(stack)
        addSubview(scrollView)

        [scrollView, stack].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        gatheringLabel.isHidden = true
        stack.addArrangedSubview(gatheringLabel)
        for spec in Self.sections {
            // Plain, NON-focusable container: the focus targets are the pair
            // rows below, so a focusable wrapper here would nest two targets.
            let container = UIStackView()
            container.axis = .vertical
            container.spacing = 12
            container.alignment = .fill
            // Visibility is owned by the `focusRow` wrapper below, NOT here.
            // Leaving this hidden while `redistribute` toggled only the wrapper
            // rendered an empty sheet and collapsed the content height.
            container.addArrangedSubview(PlayerInfoSheetStyle.sectionLabel(spec.name))

            // One pair row per two DECLARED rows, so the pool is always big
            // enough for however many turn out to be present.
            let grid = PlayerInfoSheetStyle.gridContainer()
            var pairRows: [InfoFocusRowView] = []
            for _ in stride(from: 0, to: spec.rows.count, by: 2) {
                let row = InfoFocusRowView()
                row.isFocusEnabled = false   // the SECTION is the focus target
                row.isHidden = true
                grid.addArrangedSubview(row)
                pairRows.append(row)
            }
            container.addArrangedSubview(grid)
            // The section's label and grid ride inside one focus target, so a
            // Down press steps section-to-section and the highlight covers the
            // whole block.
            let focusRow = InfoFocusRowView()
            focusRow.setFullWidth(container)
            focusRow.isHidden = true
            stack.addArrangedSubview(focusRow)
            sectionUIs.append(SectionUI(focusRow: focusRow, container: container, pairRows: pairRows))

            for rowSpec in spec.rows {
                rowLabels[rowSpec.title] = PlayerInfoSheetStyle.infoRow(rowSpec.title, "")
            }
        }

        let scrollHeight = scrollView.heightAnchor.constraint(
            equalTo: stack.heightAnchor, constant: 2 * InfoFocusRowView.Focus.outsetY)
        // ONE BELOW `.defaultHigh`, not AT it. At `.defaultHigh` this ties with
        // the content's own vertical compression resistance, and the solver
        // resolves the tie by SQUASHING the content to the viewport instead of
        // breaking this constraint. `contentSize` then reports the squashed
        // height, so the sheet believes it fits while part of it is unreachable:
        // measured on device at stackH=448 naturalH=468, contentSize==bounds==448.
        // That makes `InfoScrollView.needsFocusableRows` false, every row
        // unfocusable, and the Down crossing from the pills into the sheet dead.
        // One below, the cap wins, the content keeps its real height, and the
        // sheet is scrollable. Short content still hugs (hugging is only 250).
        scrollHeight.priority = .defaultHigh - 1

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollHeight,
        ])
        scrollView.pinContent(stack)
    }

    // MARK: - Active-tab lifecycle
    //
    // The container calls setActive(true) when Advanced becomes the visible
    // tab and setActive(false) when it leaves. The 1 Hz tick runs only while
    // active AND attached to a window, so a hidden or torn-down sheet never
    // ticks.

    func setActive(_ active: Bool) {
        isActiveTab = active
        if active {
            rebuild()
            startLiveTick()
        } else {
            stopLiveTick()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopLiveTick()
        } else if isActiveTab {
            rebuild()
            startLiveTick()
        }
    }

    private func startLiveTick() {
        guard isActiveTab, window != nil, liveTickTimer == nil else { return }
        // Scheduled in `.common` modes rather than through
        // `Timer.scheduledTimer`, which installs the timer in `.default` only.
        // This sheet scrolls, and while a scroll is tracking the main runloop
        // leaves `.default`, so a default-mode timer stops firing for the
        // duration. The rows stay on screen holding whatever values they last
        // received, which reads exactly like the engine has stopped reporting
        // telemetry when in fact nothing is asking it for a new snapshot.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveTickTimer = timer
    }

    private func stopLiveTick() {
        liveTickTimer?.invalidate()
        liveTickTimer = nil
    }

    // MARK: - Rendering

    private func snapshot() -> AetherAdvancedStats {
        provider() ?? AetherAdvancedStats()
    }

    /// Present row titles for a snapshot, in section/row declaration order.
    private func presentTitles(for stats: AetherAdvancedStats) -> [String] {
        Self.sections.flatMap { section in
            section.rows.compactMap { row in row.value(stats) == nil ? nil : row.title }
        }
    }

    private func refresh() {
        let stats = snapshot()
        let titles = presentTitles(for: stats)
        let gathering = stats.isEmpty
        if gathering != renderedGathering || Set(titles) != renderedSignature {
            redistribute(with: stats)
        } else {
            // Same shape as last tick: rewrite text only. No re-parenting, so
            // focus and scroll position are untouched.
            for title in renderedSignature {
                guard let value = Self.value(for: title, stats: stats),
                      let label = rowLabels[title],
                      renderedValues[title] != value else { continue }
                renderedValues[title] = value
                let text = PlayerInfoSheetStyle.infoRowText(title, value)
                // Crossfade the changed value. `.allowUserInteraction` so the
                // fade never eats a press, and the row is a focus target whose
                // frame is unchanged, so focus is unaffected.
                UIView.transition(with: label, duration: Self.valueFadeDuration,
                                  options: [.transitionCrossDissolve, .allowUserInteraction]) {
                    label.attributedText = text
                }
            }
        }
    }

    private static func value(for title: String, stats: AetherAdvancedStats) -> String? {
        for section in sections {
            for row in section.rows where row.title == title {
                return row.value(stats)
            }
        }
        return nil
    }

    private func rebuild() {
        redistribute(with: snapshot())
    }

    /// Re-pairs the persistent labels into the persistent pair rows for the
    /// current present-set, and toggles visibility. Runs only when the set of
    /// present rows CHANGES (a telemetry field appeared or disappeared), not on
    /// every tick. Nothing is created or destroyed here, so focus survives it.
    private func redistribute(with stats: AetherAdvancedStats) {
        if stats.isEmpty {
            gatheringLabel.isHidden = false
            sectionUIs.forEach { $0.focusRow.isHidden = true }
            renderedGathering = true
            renderedSignature = []
            renderedValues = [:]
            return
        }

        gatheringLabel.isHidden = true
        var present: Set<String> = []
        for (index, section) in Self.sections.enumerated() {
            let ui = sectionUIs[index]
            let visible: [UILabel] = section.rows.compactMap { row in
                guard let value = row.value(stats), let label = rowLabels[row.title] else { return nil }
                // No crossfade here: a redistribute is a structural change
                // (rows appearing or disappearing), not a value ticking over.
                label.attributedText = PlayerInfoSheetStyle.infoRowText(row.title, value)
                renderedValues[row.title] = value
                present.insert(row.title)
                return label
            }
            ui.focusRow.isHidden = visible.isEmpty
            for (rowIndex, pairRow) in ui.pairRows.enumerated() {
                let left = rowIndex * 2
                guard left < visible.count else {
                    pairRow.isHidden = true
                    continue
                }
                pairRow.setPair(visible[left], left + 1 < visible.count ? visible[left + 1] : nil)
                pairRow.isHidden = false
            }
        }

        renderedGathering = false
        renderedSignature = present
    }
}
