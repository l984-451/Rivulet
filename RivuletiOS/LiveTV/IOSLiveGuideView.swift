// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI
import UIKit

/// The programme grid. A UICollectionView virtualizes both axes; the channel
/// column, time ruler and now line are pinned supplementary views.
/// The window runs from two hours ago to the loaded guide (72 h at most).
struct IOSLiveGuideView: UIViewRepresentable {
    struct Actions {
        let play: (UnifiedChannel) -> Void
        let details: (IOSLiveProgrammeSelection) -> Void
        let menu: (UnifiedChannel, UnifiedProgram?) -> UIMenu
        let needsMoreGuide: () -> Void
    }

    let channels: [UnifiedChannel]
    let epg: [String: [UnifiedProgram]]
    let loadedThrough: Date?
    let recordingIds: Set<String>
    let jumpToken: Int
    let actions: Actions

    func makeCoordinator() -> IOSLiveGuideCoordinator { IOSLiveGuideCoordinator() }

    func makeUIView(context: Context) -> IOSLiveGuideContainer {
        let container = IOSLiveGuideContainer(coordinator: context.coordinator)
        context.coordinator.update(self)
        return container
    }

    func updateUIView(_ container: IOSLiveGuideContainer, context: Context) {
        context.coordinator.update(self)
    }
}

// MARK: - Metrics

private struct GuideMetrics {
    let rowHeight: CGFloat
    let channelWidth: CGFloat
    let rulerHeight: CGFloat
    let pointsPerMinute: CGFloat
    let gap: CGFloat = 3
    let radius: CGFloat = 8

    /// Size class, not orientation: a wider screen simply shows more time.
    init(traits: UITraitCollection) {
        let regular = traits.horizontalSizeClass == .regular
        let scale = min(UIFontMetrics.default.scaledValue(for: 1, compatibleWith: traits), 1.6)
        rowHeight = ((regular ? 76 : 62) * scale).rounded()
        channelWidth = ((regular ? 112 : 84) * min(scale, 1.3)).rounded()
        rulerHeight = (30 * min(scale, 1.4)).rounded()
        pointsPerMinute = (regular ? 4.6 : 3.4) * min(scale, 1.4)
    }
}

private enum GuideFonts {
    static func font(_ style: UIFont.TextStyle, size: CGFloat, weight: UIFont.Weight) -> UIFont {
        UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight), maximumPointSize: size * 1.6)
    }
}

// MARK: - Coordinator

@MainActor
final class IOSLiveGuideCoordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
    fileprivate struct Span {
        let program: UnifiedProgram?
        let startMinute: CGFloat
        let minutes: CGFloat
    }

    private static let historyMinutes: TimeInterval = 120
    private static let maxHoursAhead: TimeInterval = 72

    fileprivate let layout = IOSLiveGuideLayout()
    fileprivate lazy var collectionView: UICollectionView = makeCollectionView()
    private var guide: IOSLiveGuideView?
    fileprivate private(set) var channels: [UnifiedChannel] = []
    fileprivate private(set) var rows: [[Span]] = []
    private var recordingIds: Set<String> = []
    private var signature = 0
    private var jumpToken = 0
    private var requestedMoreAt: Date?
    private var hasPositioned = false
    fileprivate private(set) var windowStart = Date()

    override init() {
        super.init()
        resetWindowStart()
    }

    private func makeCollectionView() -> UICollectionView {
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .systemBackground
        view.contentInsetAdjustmentBehavior = .never
        view.showsHorizontalScrollIndicator = false
        view.isDirectionalLockEnabled = true
        view.bouncesHorizontally = false
        view.dataSource = self
        view.delegate = self
        view.register(IOSLiveGuideProgramCell.self, forCellWithReuseIdentifier: IOSLiveGuideProgramCell.reuseID)
        for kind in IOSLiveGuideLayout.Kind.allCases {
            view.register(kind.viewClass, forSupplementaryViewOfKind: kind.rawValue, withReuseIdentifier: kind.rawValue)
        }
        layout.coordinator = self
        return view
    }

    // MARK: Data

    func update(_ guide: IOSLiveGuideView) {
        self.guide = guide
        var hasher = Hasher()
        hasher.combine(guide.loadedThrough)
        hasher.combine(guide.recordingIds)
        for channel in guide.channels {
            hasher.combine(channel.id)
            hasher.combine(channel.logoURL)
            let programs = guide.epg[channel.id]
            hasher.combine(programs?.count)
            hasher.combine(programs?.first?.id)
            hasher.combine(programs?.last?.id)
        }
        let newSignature = hasher.finalize()
        if newSignature != signature {
            signature = newSignature
            rebuild()
        }
        if guide.jumpToken != jumpToken {
            jumpToken = guide.jumpToken
            jumpToNow(animated: true)
        }
    }

    private var windowEnd: Date {
        let now = Date()
        let floor = Self.floorToHalfHour(now)
        let loaded = max(guide?.loadedThrough ?? floor, floor.addingTimeInterval(6 * 3600))
        return min(loaded, now.addingTimeInterval(Self.maxHoursAhead * 3600))
    }

    /// Spans clipped to the window. The store keeps each channel's guide sorted.
    private func rebuild() {
        guard let guide else { return }
        let start = windowStart
        let end = windowEnd
        let totalMinutes = CGFloat(end.timeIntervalSince(start) / 60)
        channels = guide.channels
        recordingIds = guide.recordingIds
        rows = guide.channels.map { channel in
            let spans = (guide.epg[channel.id] ?? []).compactMap { program -> Span? in
                guard program.endTime > start, program.startTime < end else { return nil }
                let from = max(program.startTime, start)
                let minutes = CGFloat(min(program.endTime, end).timeIntervalSince(from) / 60)
                return Span(program: program, startMinute: CGFloat(from.timeIntervalSince(start) / 60), minutes: minutes)
            }
            // No guide data: one block across the window, still tappable.
            return spans.isEmpty ? [Span(program: nil, startMinute: 0, minutes: totalMinutes)] : spans
        }
        layout.totalMinutes = totalMinutes
        layout.timelineStart = start
        layout.now = Date()
        layout.invalidateLayout()
        collectionView.reloadData()
    }

    // MARK: Time

    private func resetWindowStart() {
        windowStart = Self.floorToHalfHour(Date()).addingTimeInterval(-Self.historyMinutes * 60)
    }

    func tick() {
        layout.now = Date()
        layout.invalidateLayout()
        collectionView.reconfigureItems(at: collectionView.indexPathsForVisibleItems)
    }

    func jumpToNow(animated: Bool) {
        if Date().timeIntervalSince(windowStart) > (Self.historyMinutes + 30) * 60 {
            resetWindowStart()
            rebuild()
            collectionView.layoutIfNeeded()
        }
        setLeftEdge(to: Self.floorToHalfHour(Date()), animated: animated)
    }

    /// Back after hours: the old window starts in the past, so move to Now.
    func jumpToNowIfStale() {
        guard Date().timeIntervalSince(windowStart) > (Self.historyMinutes + 30) * 60 else { return }
        collectionView.layoutIfNeeded()
        jumpToNow(animated: false)
    }

    func containerDidLayout(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        guard !hasPositioned else { return }
        hasPositioned = true
        collectionView.layoutIfNeeded()
        jumpToNow(animated: false)
    }

    /// Dynamic Type or size class changed: new metrics, same time on the left.
    func metricsChanged() {
        let date = dateAtLeftEdge()
        layout.metrics = GuideMetrics(traits: collectionView.traitCollection)
        layout.invalidateLayout()
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
        setLeftEdge(to: date, animated: false)
    }

    private func dateAtLeftEdge() -> Date {
        windowStart.addingTimeInterval(TimeInterval(collectionView.contentOffset.x / layout.metrics.pointsPerMinute * 60))
    }

    private func setLeftEdge(to date: Date, animated: Bool) {
        let x = CGFloat(date.timeIntervalSince(windowStart) / 60) * layout.metrics.pointsPerMinute
        let maxX = max(0, collectionView.contentSize.width - collectionView.bounds.width)
        collectionView.setContentOffset(CGPoint(x: min(max(x, 0), maxX), y: collectionView.contentOffset.y), animated: animated)
    }

    static func floorToHalfHour(_ date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / 1800).rounded(.down) * 1800)
    }

    // MARK: Data source

    func numberOfSections(in collectionView: UICollectionView) -> Int { rows.count }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        rows[section].count
    }

    fileprivate func span(at indexPath: IndexPath) -> Span? {
        rows[safe: indexPath.section]?[safe: indexPath.item]
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: IOSLiveGuideProgramCell.reuseID, for: indexPath)
        if let cell = cell as? IOSLiveGuideProgramCell {
            let program = span(at: indexPath)?.program
            cell.configure(program: program, isRecording: program.map { recordingIds.contains($0.id) } ?? false)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> UICollectionReusableView {
        let view = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: kind, for: indexPath)
        switch view {
        case let view as IOSLiveGuideChannelView:
            if let channel = channels[safe: indexPath.section] {
                view.configure(channel: channel, nowTitle: currentTitle(for: indexPath.section)) { [weak self] in
                    self?.guide?.actions.play(channel)
                }
            }
        case let view as IOSLiveGuideRulerView:
            view.configure(time: windowStart.addingTimeInterval(TimeInterval(indexPath.item * 30 * 60)))
        case let view as IOSLiveGuideCornerView:
            view.configure(date: dateAtLeftEdge())
        default:
            break
        }
        return view
    }

    private func currentTitle(for section: Int) -> String? {
        let now = Date()
        return rows[section].first { ($0.program?.startTime ?? .distantFuture) <= now && ($0.program?.endTime ?? .distantPast) > now }?
            .program?.displayTitle
    }

    // MARK: Delegate

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let channel = channels[safe: indexPath.section], let guide else { return }
        let program = span(at: indexPath)?.program
        if program?.isCurrentlyAiring ?? true {
            guide.actions.play(channel)
        } else {
            guide.actions.details(IOSLiveProgrammeSelection(channel: channel, program: program))
        }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let channel = channels[safe: indexPath.section], let guide else { return nil }
        let program = span(at: indexPath)?.program
        return UIContextMenuConfiguration(actionProvider: { _ in guide.actions.menu(channel, program) })
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if let corner = collectionView.supplementaryView(forElementKind: IOSLiveGuideLayout.Kind.corner.rawValue,
                                                         at: IndexPath(item: 0, section: 0)) as? IOSLiveGuideCornerView {
            corner.configure(date: dateAtLeftEdge())
        }
        // Near the loaded end: ask for more, once per loaded window.
        let metrics = layout.metrics
        let rightMinute = (scrollView.contentOffset.x + scrollView.bounds.width - metrics.channelWidth) / metrics.pointsPerMinute
        guard layout.totalMinutes - rightMinute < 90,
              let through = guide?.loadedThrough, requestedMoreAt != through,
              through < Date().addingTimeInterval(Self.maxHoursAhead * 3600 - 60) else { return }
        requestedMoreAt = through
        guide?.actions.needsMoreGuide()
    }

    /// Settles on half-hour columns, like the ruler.
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let column = 30 * layout.metrics.pointsPerMinute
        let maxX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
        targetContentOffset.pointee.x = min((targetContentOffset.pointee.x / column).rounded() * column, maxX)
    }
}

// MARK: - Container

final class IOSLiveGuideContainer: UIView {
    private let coordinator: IOSLiveGuideCoordinator
    private var timer: Timer?
    private var foregroundObserver: NSObjectProtocol?
    private var bottomInset: CGFloat = 0

    init(coordinator: IOSLiveGuideCoordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        addSubview(coordinator.collectionView)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitHorizontalSizeClass.self]) {
            (self: IOSLiveGuideContainer, _: UITraitCollection) in
            self.coordinator.metricsChanged()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        coordinator.collectionView.frame = bounds
        adoptTabBar()
        coordinator.containerDidLayout(bounds.size)
    }

    /// The now line and past programmes move with the clock, only while on screen.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        timer?.invalidate()
        timer = nil
        foregroundObserver.map(NotificationCenter.default.removeObserver)
        foregroundObserver = nil
        guard window != nil else { return }
        coordinator.metricsChanged()
        coordinator.jumpToNowIfStale()
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.coordinator.jumpToNowIfStale() }
        }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.coordinator.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Scrolls under the floating tab bar and lets it minimize on scroll.
    private func adoptTabBar() {
        var responder: UIResponder? = self
        var tabBar: UITabBar?
        while let current = responder {
            if let controller = current as? UIViewController {
                controller.setContentScrollView(coordinator.collectionView, for: .bottom)
                tabBar = tabBar ?? controller.tabBarController?.tabBar
            }
            responder = current.next
        }
        guard let tabBar, !tabBar.isHidden else { return }
        let overlap = max(0, bounds.maxY - tabBar.convert(tabBar.bounds, to: self).minY)
        guard abs(overlap - bottomInset) > 0.5 else { return }
        bottomInset = overlap
        coordinator.collectionView.contentInset.bottom = overlap
        coordinator.collectionView.verticalScrollIndicatorInsets.bottom = overlap
    }
}

// MARK: - Layout

private final class IOSLiveGuideAttributes: UICollectionViewLayoutAttributes {
    /// How far the cell runs under the channel column, so its text can stay visible.
    var hiddenLeading: CGFloat = 0
    var isPast = false

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! IOSLiveGuideAttributes
        copy.hiddenLeading = hiddenLeading
        copy.isPast = isPast
        return copy
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? IOSLiveGuideAttributes else { return false }
        return super.isEqual(object) && hiddenLeading == other.hiddenLeading && isPast == other.isPast
    }
}

/// Content x runs from the channel column's right edge; y from below the ruler.
private final class IOSLiveGuideLayout: UICollectionViewLayout {
    enum Kind: String, CaseIterable {
        case channel = "guide-channel"
        case ruler = "guide-ruler"
        case corner = "guide-corner"
        case now = "guide-now"

        var viewClass: AnyClass {
            switch self {
            case .channel: return IOSLiveGuideChannelView.self
            case .ruler: return IOSLiveGuideRulerView.self
            case .corner: return IOSLiveGuideCornerView.self
            case .now: return IOSLiveGuideNowView.self
            }
        }
    }

    weak var coordinator: IOSLiveGuideCoordinator?
    var metrics = GuideMetrics(traits: .current)
    var totalMinutes: CGFloat = 0
    var timelineStart = Date()
    var now = Date()

    override class var layoutAttributesClass: AnyClass { IOSLiveGuideAttributes.self }

    private var rowCount: Int { coordinator?.rows.count ?? 0 }

    override var collectionViewContentSize: CGSize {
        CGSize(width: metrics.channelWidth + totalMinutes * metrics.pointsPerMinute,
               height: metrics.rulerHeight + CGFloat(rowCount) * metrics.rowHeight)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { true }

    private var offset: CGPoint { collectionView?.contentOffset ?? .zero }

    private func minuteX(_ minute: CGFloat) -> CGFloat { metrics.channelWidth + minute * metrics.pointsPerMinute }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let span = coordinator?.span(at: indexPath) else { return nil }
        let gap = metrics.gap
        let attributes = IOSLiveGuideAttributes(forCellWith: indexPath)
        attributes.frame = CGRect(
            x: minuteX(span.startMinute) + gap / 2,
            y: metrics.rulerHeight + CGFloat(indexPath.section) * metrics.rowHeight + gap / 2,
            width: max(2, span.minutes * metrics.pointsPerMinute - gap),
            height: metrics.rowHeight - gap
        )
        attributes.hiddenLeading = max(0, offset.x + metrics.channelWidth - attributes.frame.minX)
        attributes.isPast = (span.program?.endTime ?? .distantFuture) <= now
        return attributes
    }

    override func layoutAttributesForSupplementaryView(ofKind elementKind: String,
                                                       at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let kind = Kind(rawValue: elementKind), let collectionView else { return nil }
        let attributes = IOSLiveGuideAttributes(forSupplementaryViewOfKind: elementKind, with: indexPath)
        switch kind {
        case .channel:
            attributes.frame = CGRect(x: offset.x, y: metrics.rulerHeight + CGFloat(indexPath.section) * metrics.rowHeight,
                                      width: metrics.channelWidth, height: metrics.rowHeight)
            attributes.zIndex = 10
        case .ruler:
            let column = 30 * metrics.pointsPerMinute
            attributes.frame = CGRect(x: metrics.channelWidth + CGFloat(indexPath.item) * column, y: offset.y,
                                      width: column, height: metrics.rulerHeight)
            attributes.zIndex = 12
        case .corner:
            attributes.frame = CGRect(x: offset.x, y: offset.y, width: metrics.channelWidth, height: metrics.rulerHeight)
            attributes.zIndex = 20
        case .now:
            let x = minuteX(CGFloat(now.timeIntervalSince(timelineStart) / 60))
            attributes.frame = CGRect(x: x - 5, y: offset.y + metrics.rulerHeight - 5,
                                      width: 10, height: collectionView.bounds.height - metrics.rulerHeight + 5)
            attributes.zIndex = 13
            attributes.isHidden = x < offset.x + metrics.channelWidth
        }
        return attributes
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let coordinator, rowCount > 0 else { return [] }
        var result: [UICollectionViewLayoutAttributes] = []
        let first = max(0, Int(((rect.minY - metrics.rulerHeight) / metrics.rowHeight).rounded(.down)))
        let last = min(rowCount - 1, Int(((rect.maxY - metrics.rulerHeight) / metrics.rowHeight).rounded(.down)))
        if first <= last {
            for section in first...last {
                for (item, span) in coordinator.rows[section].enumerated() {
                    let minX = minuteX(span.startMinute)
                    guard minX <= rect.maxX, minX + span.minutes * metrics.pointsPerMinute >= rect.minX else { continue }
                    if let cell = layoutAttributesForItem(at: IndexPath(item: item, section: section)) { result.append(cell) }
                }
                if let channel = layoutAttributesForSupplementaryView(ofKind: Kind.channel.rawValue,
                                                                      at: IndexPath(item: 0, section: section)) {
                    result.append(channel)
                }
            }
        }
        // Only the ruler columns in view, never one per half hour of the whole window.
        let column = 30 * metrics.pointsPerMinute
        let columns = Int((totalMinutes / 30).rounded(.up))
        let firstColumn = max(0, Int(((rect.minX - metrics.channelWidth) / column).rounded(.down)))
        let lastColumn = min(columns - 1, Int(((rect.maxX - metrics.channelWidth) / column).rounded(.down)))
        if firstColumn <= lastColumn {
            for column in firstColumn...lastColumn {
                if let ruler = layoutAttributesForSupplementaryView(ofKind: Kind.ruler.rawValue,
                                                                    at: IndexPath(item: column, section: 0)) {
                    result.append(ruler)
                }
            }
        }
        for kind in [Kind.corner, .now] {
            if let view = layoutAttributesForSupplementaryView(ofKind: kind.rawValue, at: IndexPath(item: 0, section: 0)) {
                result.append(view)
            }
        }
        return result
    }
}

// MARK: - Views

private final class IOSLiveGuideProgramCell: UICollectionViewCell {
    static let reuseID = "guide-program"

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let recordingDot = UIView()
    private var textLeading: NSLayoutConstraint!
    private var program: UnifiedProgram?
    private var isRecording = false
    private var isPast = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 8
        contentView.layer.cornerCurve = .continuous

        titleLabel.font = GuideFonts.font(.footnote, size: 13, weight: .semibold)
        subtitleLabel.font = GuideFonts.font(.caption1, size: 11.5, weight: .regular)
        subtitleLabel.textColor = .secondaryLabel
        for label in [titleLabel, subtitleLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.lineBreakMode = .byTruncatingTail
        }
        let stack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        stack.axis = .vertical
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        recordingDot.backgroundColor = .systemRed
        recordingDot.layer.cornerRadius = 3.5
        recordingDot.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(recordingDot)

        textLeading = stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            textLeading,
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            recordingDot.widthAnchor.constraint(equalToConstant: 7),
            recordingDot.heightAnchor.constraint(equalToConstant: 7),
            recordingDot.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            recordingDot.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(program: UnifiedProgram?, isRecording: Bool) {
        self.program = program
        self.isRecording = isRecording
        titleLabel.text = program?.displayTitle ?? "No guide data"
        let subtitle = program?.subtitle.flatMap { $0.isEmpty || $0 == program?.title ? nil : $0 }
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle == nil
        recordingDot.isHidden = !isRecording

        let airing = program?.isCurrentlyAiring ?? true
        accessibilityLabel = titleLabel.text
        var value = program.map { [$0.timeRange] } ?? []
        if program?.isCurrentlyAiring == true { value.append("On now") }
        if isRecording { value.append("Recording") }
        accessibilityValue = value.joined(separator: ", ")
        accessibilityHint = airing ? "Plays the channel" : "Shows details"
    }

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        guard let attributes = layoutAttributes as? IOSLiveGuideAttributes else { return }
        textLeading.constant = 8 + min(attributes.hiddenLeading, max(0, bounds.width - 40))
        if attributes.isPast != isPast {
            isPast = attributes.isPast
            updateColors()
        }
    }

    override var isHighlighted: Bool { didSet { updateColors() } }

    private func updateColors() {
        contentView.backgroundColor = isHighlighted
            ? .systemGray4
            : (isPast ? UIColor.secondarySystemBackground.withAlphaComponent(0.45) : .secondarySystemBackground)
        titleLabel.textColor = isPast ? .secondaryLabel : .label
    }
}

private final class IOSLiveGuideChannelView: UICollectionReusableView {
    private let box = UIView()
    private let logoView = UIImageView()
    private let nameLabel = UILabel()
    private let numberLabel = UILabel()
    private var logoTask: Task<Void, Never>?
    private var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        box.backgroundColor = .secondarySystemBackground
        box.layer.cornerRadius = 8
        box.layer.cornerCurve = .continuous
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)

        logoView.contentMode = .scaleAspectFit
        nameLabel.font = GuideFonts.font(.caption1, size: 11.5, weight: .semibold)
        nameLabel.numberOfLines = 2
        nameLabel.textAlignment = .center
        numberLabel.font = GuideFonts.font(.caption2, size: 10.5, weight: .medium)
        numberLabel.textColor = .secondaryLabel
        numberLabel.textAlignment = .center
        for label in [nameLabel, numberLabel] { label.adjustsFontForContentSizeCategory = true }

        let stack = UIStackView(arrangedSubviews: [logoView, nameLabel, numberLabel])
        stack.axis = .vertical
        stack.spacing = 2
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)

        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            box.topAnchor.constraint(equalTo: topAnchor, constant: 1.5),
            box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1.5),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: box.topAnchor, constant: 4),
            logoView.heightAnchor.constraint(equalTo: box.heightAnchor, multiplier: 0.42),
            logoView.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        logoView.layer.shadowColor = UIColor.white.cgColor
        logoView.layer.shadowRadius = 1.5
        logoView.layer.shadowOffset = .zero
        updateHalo()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: IOSLiveGuideChannelView, _: UITraitCollection) in
            self.updateHalo()
        }

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = "Plays the channel"
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(channel: UnifiedChannel, nowTitle: String?, onTap: @escaping () -> Void) {
        self.onTap = onTap
        nameLabel.text = channel.name
        numberLabel.text = channel.channelNumber.map(String.init)
        numberLabel.isHidden = channel.channelNumber == nil
        accessibilityLabel = channel.numberAndName
        accessibilityValue = nowTitle

        logoTask?.cancel()
        let cached = channel.logoURL.flatMap(IOSArtworkCache.shared.cachedImage(for:))
        show(logo: cached)
        guard cached == nil, let url = channel.logoURL else { return }
        logoTask = Task { [weak self] in
            let image = await IOSArtworkCache.shared.image(for: url)
            guard !Task.isCancelled else { return }
            self?.show(logo: image)
        }
    }

    private func show(logo: UIImage?) {
        logoView.image = logo
        logoView.isHidden = logo == nil
        nameLabel.isHidden = logo != nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        logoTask?.cancel()
        show(logo: nil)
    }

    /// Keeps black wordmarks legible on the dark fill.
    private func updateHalo() {
        logoView.layer.shadowOpacity = traitCollection.userInterfaceStyle == .dark ? 0.6 : 0
    }

    @objc private func tapped() { onTap?() }

    override func accessibilityActivate() -> Bool {
        onTap?()
        return true
    }
}

private final class IOSLiveGuideRulerView: UICollectionReusableView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        label.font = GuideFonts.font(.footnote, size: 12, weight: .semibold)
        label.textColor = .secondaryLabel
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        let tick = UIView()
        tick.backgroundColor = .separator
        tick.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tick)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            tick.leadingAnchor.constraint(equalTo: leadingAnchor),
            tick.widthAnchor.constraint(equalToConstant: 1),
            tick.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.4),
            tick.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(time: Date) {
        label.text = time.formatted(.dateTime.hour().minute())
    }
}

private final class IOSLiveGuideCornerView: UICollectionReusableView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        label.font = GuideFonts.font(.footnote, size: 12, weight: .bold)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(date: Date) {
        label.text = Calendar.current.isDateInToday(date) ? "Today" : date.formatted(.dateTime.weekday(.abbreviated))
    }
}

/// The current time: a red line with a dot where it meets the ruler.
private final class IOSLiveGuideNowView: UICollectionReusableView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let dot = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        dot.backgroundColor = .systemRed
        dot.layer.cornerRadius = 5
        let line = UIView()
        line.backgroundColor = .systemRed
        addSubview(line)
        addSubview(dot)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        subviews.first?.frame = CGRect(x: 4, y: 5, width: 2, height: max(0, layoutAttributes.size.height - 5))
    }
}
