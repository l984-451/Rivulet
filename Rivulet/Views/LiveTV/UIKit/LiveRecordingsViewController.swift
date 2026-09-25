// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveRecordingsViewController.swift
//  Rivulet
//
//  Recordings across every Live TV source that records: what is coming up (or
//  recording right now), and the standing rules behind them. Selecting a row
//  offers what can be done with it — cancel an airing, cancel a series,
//  remove a rule. Finished recordings are library content and live in the
//  library, not here.
//

import UIKit

final class LiveRecordingsViewController: UIViewController {

    private enum Row: Hashable {
        case recording(LiveTVScheduledRecording)
        case rule(LiveTVRecordingRule)
        case message(String)
    }

    private struct Section {
        let title: String
        let rows: [Row]
    }

    private var sections: [Section] = []
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let titleLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.06, alpha: 1)

        titleLabel.text = "Recordings"
        titleLabel.font = .systemFont(ofSize: 48, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.remembersLastFocusedIndexPath = true
        tableView.register(LiveRecordingCell.self, forCellReuseIdentifier: LiveRecordingCell.reuseID)
        tableView.register(LiveRecordingSectionHeader.self,
                           forHeaderFooterViewReuseIdentifier: LiveRecordingSectionHeader.reuseID)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 70),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 120),

            tableView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 30),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 100),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -100),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        reload()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [tableView] }

    private func reload() {
        spinner.startAnimating()
        Task { @MainActor [weak self] in
            let store = LiveTVDataStore.shared
            await store.refreshScheduledRecordings()
            let rules = await store.recordingRules()
            guard let self else { return }
            self.spinner.stopAnimating()

            let active = store.scheduledRecordings.filter { $0.status == .scheduled || $0.status == .recording }
            var sections: [Section] = []
            sections.append(Section(
                title: "Upcoming",
                rows: active.isEmpty
                    ? [.message("Nothing is scheduled. Long-press a programme in the guide to record it.")]
                    : active.map { .recording($0) }
            ))
            if !rules.isEmpty {
                sections.append(Section(title: "Series and Rules", rows: rules.map { .rule($0) }))
            }
            self.sections = sections
            self.tableView.reloadData()
            self.setNeedsFocusUpdate()
            self.updateFocusIfNeeded()
        }
    }

    // MARK: - Actions

    private func presentActions(for row: Row, from cell: UITableViewCell?) {
        let store = LiveTVDataStore.shared
        var actions: [TileMenuAction] = []
        let header: TileMenuHeader
        switch row {
        case .recording(let recording):
            header = TileMenuHeader(title: recording.title, detail: detailLine(for: recording))
            actions.append(TileMenuAction(
                title: recording.status == .recording ? "Stop Recording" : "Cancel Recording",
                systemImage: "stop.circle",
                destructive: true
            ) { [weak self] in
                self?.perform { try await store.cancel(recording) }
            })
            if recording.ruleIsSeries {
                actions.append(TileMenuAction(
                    title: "Cancel Series",
                    systemImage: "square.stack.3d.up.slash",
                    destructive: true
                ) { [weak self] in
                    self?.perform { try await store.cancelSeries(of: recording) }
                })
            }
        case .rule(let rule):
            header = TileMenuHeader(title: rule.title, detail: rule.detail)
            actions.append(TileMenuAction(
                title: "Delete Rule",
                systemImage: "trash",
                destructive: true
            ) { [weak self] in
                self?.perform { try await store.delete(rule) }
            })
        case .message:
            return
        }
        let frame = cell.map { $0.convert($0.bounds, to: nil) }
        let popup = TileMenuPopupViewController(sections: [actions], sourceFrame: frame, header: header)
        present(popup, animated: false)
    }

    private func perform(_ change: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor [weak self] in
            do {
                try await change()
                self?.reload()
            } catch {
                let alert = UIAlertController(title: "Recording Didn't Change",
                                              message: error.localizedDescription,
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self?.present(alert, animated: true)
            }
        }
    }

    fileprivate func detailLine(for recording: LiveTVScheduledRecording) -> String {
        var parts: [String] = []
        if let subtitle = recording.subtitle, !subtitle.isEmpty { parts.append(subtitle) }
        parts.append(Self.timeFormatter.string(from: recording.startTime))
        if let channel = recording.channelName, !channel.isEmpty { parts.append(channel) }
        return parts.joined(separator: " · ")
    }
}

extension LiveRecordingsViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: LiveRecordingCell.reuseID, for: indexPath)
            as! LiveRecordingCell
        switch sections[indexPath.section].rows[indexPath.row] {
        case .recording(let recording):
            cell.configure(title: recording.title, detail: detailLine(for: recording),
                           isRecordingNow: recording.status == .recording, selectable: true)
        case .rule(let rule):
            cell.configure(title: rule.title, detail: rule.detail, isRecordingNow: false, selectable: true)
        case .message(let text):
            cell.configure(title: text, detail: nil, isRecordingNow: false, selectable: false)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: LiveRecordingSectionHeader.reuseID)
            as? LiveRecordingSectionHeader
        header?.setTitle(sections[section].title)
        return header
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { 70 }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 104 }

    func tableView(_ tableView: UITableView, canFocusRowAt indexPath: IndexPath) -> Bool {
        if case .message = sections[indexPath.section].rows[indexPath.row] { return false }
        return true
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        presentActions(for: sections[indexPath.section].rows[indexPath.row],
                       from: tableView.cellForRow(at: indexPath))
    }
}

// MARK: - Cells

/// Glass row: the house focus treatment (fill 0.08 → 0.18, hairline border
/// 0.08 → 0.25, 1.02 scale on a spring).
private final class LiveRecordingCell: UITableViewCell {
    static let reuseID = "LiveRecordingCell"

    private let plate = UIView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let recDot = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        focusStyle = .custom
        selectionStyle = .none

        plate.layer.cornerRadius = 18
        plate.layer.cornerCurve = .continuous
        plate.layer.borderWidth = 1
        plate.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(plate)

        recDot.backgroundColor = .systemRed
        recDot.layer.cornerRadius = 7
        recDot.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(recDot)

        titleLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        titleLabel.textColor = .white
        detailLabel.font = .systemFont(ofSize: 21, weight: .regular)
        detailLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        let stack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(stack)

        NSLayoutConstraint.activate([
            plate.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            plate.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            plate.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            plate.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            recDot.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: 26),
            recDot.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
            recDot.widthAnchor.constraint(equalToConstant: 14),
            recDot.heightAnchor.constraint(equalToConstant: 14),
            stack.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: 56),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: plate.trailingAnchor, constant: -26),
            stack.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
        ])
        applyFocus(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, detail: String?, isRecordingNow: Bool, selectable: Bool) {
        titleLabel.text = title
        titleLabel.font = selectable
            ? .systemFont(ofSize: 28, weight: .semibold)
            : .systemFont(ofSize: 24, weight: .regular)
        titleLabel.numberOfLines = selectable ? 1 : 2
        detailLabel.text = detail
        detailLabel.isHidden = detail == nil
        recDot.isHidden = !isRecordingNow
        isSelectableRow = selectable
        applyFocus(isFocused)
    }

    /// A message row draws no plate: it is text, not something to select.
    private var isSelectableRow = true

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations {
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.7,
                           initialSpringVelocity: 0, options: [.allowUserInteraction]) {
                self.applyFocus(focused)
            }
        }
    }

    private func applyFocus(_ focused: Bool) {
        guard isSelectableRow else {
            plate.backgroundColor = .clear
            plate.layer.borderColor = UIColor.clear.cgColor
            transform = .identity
            return
        }
        plate.backgroundColor = UIColor.white.withAlphaComponent(focused ? 0.18 : 0.08)
        plate.layer.borderColor = UIColor.white.withAlphaComponent(focused ? 0.25 : 0.08).cgColor
        transform = focused ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
    }
}

private final class LiveRecordingSectionHeader: UITableViewHeaderFooterView {
    static let reuseID = "LiveRecordingSectionHeader"
    private let label = UILabel()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        label.font = .systemFont(ofSize: 24, weight: .semibold)
        label.textColor = UIColor.white.withAlphaComponent(0.55)
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTitle(_ title: String) { label.text = title.uppercased() }
}
