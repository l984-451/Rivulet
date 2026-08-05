// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI
import UIKit

private enum IOSUIKitGuideMetrics {
    static let rowHeight: CGFloat = 70.5
    static let channelWidth: CGFloat = 96.75
    static let rulerHeight: CGFloat = 40.5
    static let rulerBoxHeight: CGFloat = 25.5
    static let spacing: CGFloat = 3
    static let cornerRadius: CGFloat = 6
    static let historyMinutes = 120
    static let initialMinutes = 360
    static let chunkMinutes = 240
}

/// UIKit-backed EPG. `UICollectionView` virtualizes in both axes while the
/// coordinator lazily grows the represented time window at either edge.
struct IOSGuideCollectionView: UIViewRepresentable {
    let channels: [IOSIPTVChannel]
    let programsByChannel: [String: [IOSEPGProgram]]
    let snapToken: Int
    let onSelect: (IOSIPTVChannel, IOSEPGProgram?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> IOSGuideCollectionContainer {
        let layout = IOSGuideCollectionLayout()
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset = UIEdgeInsets(
            top: IOSUIKitGuideMetrics.rulerHeight,
            left: IOSUIKitGuideMetrics.channelWidth,
            bottom: 0,
            right: 0
        )
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.bounces = false
        collectionView.isDirectionalLockEnabled = true
        collectionView.decelerationRate = .fast
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.register(
            IOSGuideProgramCollectionCell.self,
            forCellWithReuseIdentifier: IOSGuideProgramCollectionCell.reuseID
        )
        collectionView.register(
            IOSGuideChannelReusableView.self,
            forSupplementaryViewOfKind: IOSGuideCollectionLayout.channelKind,
            withReuseIdentifier: IOSGuideChannelReusableView.reuseID
        )
        collectionView.register(
            IOSGuideTimeReusableView.self,
            forSupplementaryViewOfKind: IOSGuideCollectionLayout.timeKind,
            withReuseIdentifier: IOSGuideTimeReusableView.reuseID
        )
        collectionView.register(
            IOSGuideCornerReusableView.self,
            forSupplementaryViewOfKind: IOSGuideCollectionLayout.cornerKind,
            withReuseIdentifier: IOSGuideCornerReusableView.reuseID
        )

        context.coordinator.collectionView = collectionView
        context.coordinator.layout = layout
        context.coordinator.resetWindow()

        let container = IOSGuideCollectionContainer(collectionView: collectionView)
        container.onSizeChange = { [weak coordinator = context.coordinator] size in
            coordinator?.containerSizeDidChange(size)
        }
        return container
    }

    func updateUIView(_ uiView: IOSGuideCollectionContainer, context: Context) {
        context.coordinator.update(parent: self)
    }

    static func dismantleUIView(
        _ uiView: IOSGuideCollectionContainer,
        coordinator: Coordinator
    ) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        private var parent: IOSGuideCollectionView
        weak var collectionView: UICollectionView?
        weak var layout: IOSGuideCollectionLayout?

        private var items: [[IOSEPGProgram?]] = []
        private var lastDataSignature = 0
        private var lastSnapToken: Int
        private var isChangingWindow = false
        private var lastViewportSize = CGSize.zero
        private var bottomBarInset: CGFloat = 0
        private var timer: Timer?

        private(set) var windowStart = Date()
        private(set) var totalMinutes = IOSUIKitGuideMetrics.initialMinutes

        init(parent: IOSGuideCollectionView) {
            self.parent = parent
            self.lastSnapToken = parent.snapToken
            super.init()
            timer = Timer.scheduledTimer(
                timeInterval: 30,
                target: self,
                selector: #selector(refreshCurrentTime),
                userInfo: nil,
                repeats: true
            )
        }

        deinit { timer?.invalidate() }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        @objc private func refreshCurrentTime() {
            layout?.now = Date()
            layout?.invalidateLayout()
        }

        func update(parent: IOSGuideCollectionView) {
            self.parent = parent
            if parent.snapToken != lastSnapToken {
                lastSnapToken = parent.snapToken
                resetWindow()
                return
            }

            let signature = dataSignature()
            guard signature != lastDataSignature else { return }
            lastDataSignature = signature
            rebuildData(reload: true)
        }

        func resetWindow() {
            let anchor = Self.floorToHalfHour(Date())
            windowStart = anchor.addingTimeInterval(
                -TimeInterval(IOSUIKitGuideMetrics.historyMinutes * 60)
            )
            totalMinutes = IOSUIKitGuideMetrics.initialMinutes
            rebuildData(reload: true)
            scrollTo(date: anchor, afterLayout: true)
        }

        func containerSizeDidChange(_ size: CGSize) {
            guard size.width > 0, size.height > 0, size != lastViewportSize,
                  let collectionView, let layout else { return }

            let isInitialLayout = lastViewportSize == .zero
            let visibleDate: Date
            if isInitialLayout {
                visibleDate = Self.floorToHalfHour(Date())
            } else {
                visibleDate = dateAtLeftEdge()
            }
            lastViewportSize = size
            layout.viewportSize = size
            layout.invalidateLayout()
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
            if isInitialLayout {
                collectionView.contentOffset.y = -collectionView.contentInset.top
            }
            setLeftEdge(to: visibleDate, animated: false)
            registerForNativeTabBarMinimisation(collectionView)
        }

        private func rebuildData(reload: Bool) {
            guard let layout else { return }
            let end = windowStart.addingTimeInterval(TimeInterval(totalMinutes * 60))
            var layoutRows: [[IOSGuideCollectionLayout.Span]] = []
            var newItems: [[IOSEPGProgram?]] = []

            for channel in parent.channels {
                let candidates = (parent.programsByChannel[channel.id] ?? [])
                    .filter { $0.end > windowStart && $0.start < end }
                    .sorted { $0.start < $1.start }

                if candidates.isEmpty {
                    layoutRows.append([
                        .init(startMinute: 0, durationMinutes: CGFloat(totalMinutes))
                    ])
                    newItems.append([nil])
                    continue
                }

                var spans: [IOSGuideCollectionLayout.Span] = []
                var rowItems: [IOSEPGProgram?] = []
                for program in candidates {
                    let clippedStart = max(program.start, windowStart)
                    let clippedEnd = min(program.end, end)
                    let startMinute = CGFloat(clippedStart.timeIntervalSince(windowStart) / 60)
                    let duration = CGFloat(clippedEnd.timeIntervalSince(clippedStart) / 60)
                    guard duration > 0 else { continue }
                    spans.append(.init(startMinute: startMinute, durationMinutes: duration))
                    rowItems.append(program)
                }
                layoutRows.append(spans)
                newItems.append(rowItems)
            }

            items = newItems
            layout.configure(
                rows: layoutRows,
                channelCount: parent.channels.count,
                totalMinutes: totalMinutes,
                timelineStart: windowStart,
                now: Date()
            )
            if reload { collectionView?.reloadData() }
        }

        private func dataSignature() -> Int {
            var hasher = Hasher()
            hasher.combine(parent.channels.count)
            for channel in parent.channels {
                hasher.combine(channel.id)
                hasher.combine(channel.logoURL)
                let programs = parent.programsByChannel[channel.id] ?? []
                hasher.combine(programs.count)
                hasher.combine(programs.first?.id)
                hasher.combine(programs.last?.id)
            }
            return hasher.finalize()
        }

        func numberOfSections(in collectionView: UICollectionView) -> Int {
            parent.channels.count
        }

        func collectionView(
            _ collectionView: UICollectionView,
            numberOfItemsInSection section: Int
        ) -> Int {
            items[safe: section]?.count ?? 0
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: IOSGuideProgramCollectionCell.reuseID,
                for: indexPath
            ) as! IOSGuideProgramCollectionCell
            cell.configure(program: items[safe: indexPath.section]?[safe: indexPath.item] ?? nil)
            return cell
        }

        func collectionView(
            _ collectionView: UICollectionView,
            viewForSupplementaryElementOfKind kind: String,
            at indexPath: IndexPath
        ) -> UICollectionReusableView {
            switch kind {
            case IOSGuideCollectionLayout.channelKind:
                let view = collectionView.dequeueReusableSupplementaryView(
                    ofKind: kind,
                    withReuseIdentifier: IOSGuideChannelReusableView.reuseID,
                    for: indexPath
                ) as! IOSGuideChannelReusableView
                if let channel = parent.channels[safe: indexPath.section] {
                    view.configure(channel: channel)
                }
                return view
            case IOSGuideCollectionLayout.timeKind:
                let view = collectionView.dequeueReusableSupplementaryView(
                    ofKind: kind,
                    withReuseIdentifier: IOSGuideTimeReusableView.reuseID,
                    for: indexPath
                ) as! IOSGuideTimeReusableView
                view.configure(
                    start: windowStart,
                    totalMinutes: totalMinutes,
                    pointsPerMinute: layout?.pointsPerMinute ?? 1
                )
                return view
            default:
                let view = collectionView.dequeueReusableSupplementaryView(
                    ofKind: kind,
                    withReuseIdentifier: IOSGuideCornerReusableView.reuseID,
                    for: indexPath
                ) as! IOSGuideCornerReusableView
                view.configure(date: dateAtLeftEdge())
                return view
            }
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard let channel = parent.channels[safe: indexPath.section] else { return }
            let program = items[safe: indexPath.section]?[safe: indexPath.item] ?? nil
            parent.onSelect(channel, program)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            updateCornerDate()
            requestWindowExtensionIfNeeded()
        }

        func scrollViewWillEndDragging(
            _ scrollView: UIScrollView,
            withVelocity velocity: CGPoint,
            targetContentOffset: UnsafeMutablePointer<CGPoint>
        ) {
            guard let layout else { return }
            let ppm = layout.pointsPerMinute
            let leftMinute = (targetContentOffset.pointee.x + scrollView.contentInset.left) / ppm
            let snappedMinute = (leftMinute / 30).rounded() * 30
            targetContentOffset.pointee.x = snappedMinute * ppm - scrollView.contentInset.left

            let topRow = (
                (targetContentOffset.pointee.y + scrollView.contentInset.top)
                    / IOSUIKitGuideMetrics.rowHeight
            ).rounded()
            targetContentOffset.pointee.y = topRow * IOSUIKitGuideMetrics.rowHeight
                - scrollView.contentInset.top
            let maximumY = max(
                -scrollView.contentInset.top,
                scrollView.contentSize.height - scrollView.bounds.height
                    + scrollView.contentInset.bottom
            )
            targetContentOffset.pointee.y = min(
                targetContentOffset.pointee.y,
                maximumY
            )
        }

        private func requestWindowExtensionIfNeeded() {
            guard !isChangingWindow, let collectionView, let layout else { return }
            let ppm = layout.pointsPerMinute
            let leftMinute = max(
                0,
                (collectionView.contentOffset.x + collectionView.contentInset.left) / ppm
            )
            let visibleMinutes = layout.visibleMinutes

            if leftMinute < 30 {
                isChangingWindow = true
                let preservedDate = dateAtLeftEdge()
                windowStart = windowStart.addingTimeInterval(
                    -TimeInterval(IOSUIKitGuideMetrics.chunkMinutes * 60)
                )
                totalMinutes += IOSUIKitGuideMetrics.chunkMinutes
                rebuildData(reload: true)
                collectionView.layoutIfNeeded()
                setLeftEdge(to: preservedDate, animated: false)
                isChangingWindow = false
            } else if CGFloat(totalMinutes) - leftMinute < visibleMinutes + 60 {
                isChangingWindow = true
                totalMinutes += IOSUIKitGuideMetrics.chunkMinutes
                rebuildData(reload: true)
                collectionView.layoutIfNeeded()
                isChangingWindow = false
            }
        }

        private func updateCornerDate() {
            guard let collectionView,
                  let corner = collectionView.supplementaryView(
                    forElementKind: IOSGuideCollectionLayout.cornerKind,
                    at: IndexPath(item: 0, section: 0)
                  ) as? IOSGuideCornerReusableView else { return }
            corner.configure(date: dateAtLeftEdge())
        }

        private func dateAtLeftEdge() -> Date {
            guard let collectionView, let layout else { return windowStart }
            let minute = (
                collectionView.contentOffset.x + collectionView.contentInset.left
            ) / layout.pointsPerMinute
            return windowStart.addingTimeInterval(TimeInterval(minute * 60))
        }

        private func scrollTo(date: Date, afterLayout: Bool) {
            guard let collectionView else { return }
            if afterLayout { collectionView.layoutIfNeeded() }
            setLeftEdge(to: date, animated: false)
        }

        private func setLeftEdge(to date: Date, animated: Bool) {
            guard let collectionView, let layout else { return }
            let minute = CGFloat(date.timeIntervalSince(windowStart) / 60)
            let x = minute * layout.pointsPerMinute - collectionView.contentInset.left
            let minimumX = -collectionView.contentInset.left
            let maximumX = max(
                minimumX,
                collectionView.contentSize.width - collectionView.bounds.width
                    + collectionView.contentInset.right
            )
            collectionView.setContentOffset(
                CGPoint(
                    x: min(max(x, minimumX), maximumX),
                    y: collectionView.contentOffset.y
                ),
                animated: animated
            )
        }

        private func registerForNativeTabBarMinimisation(_ scrollView: UIScrollView) {
            var responder: UIResponder? = scrollView
            var tabBar: UITabBar?
            while let current = responder {
                if let controller = current as? UIViewController {
                    controller.setContentScrollView(scrollView, for: .bottom)
                    tabBar = tabBar ?? controller.tabBarController?.tabBar
                }
                responder = current.next
            }

            guard let tabBar, let container = scrollView.superview else { return }
            let tabBarFrame = tabBar.convert(tabBar.bounds, to: container)
            let overlap = max(0, container.bounds.maxY - tabBarFrame.minY)
            let desiredInset = overlap > 0
                ? overlap + IOSUIKitGuideMetrics.spacing
                : 0
            guard abs(desiredInset - bottomBarInset) > 0.5 else { return }

            bottomBarInset = desiredInset
            var contentInset = scrollView.contentInset
            contentInset.bottom = desiredInset
            scrollView.contentInset = contentInset
            var indicatorInsets = scrollView.verticalScrollIndicatorInsets
            indicatorInsets.bottom = desiredInset
            scrollView.verticalScrollIndicatorInsets = indicatorInsets
        }

        private static func floorToHalfHour(_ date: Date) -> Date {
            let calendar = Calendar.current
            let minute = calendar.component(.minute, from: date)
            var components = calendar.dateComponents(
                [.calendar, .timeZone, .year, .month, .day, .hour],
                from: date
            )
            components.minute = minute < 30 ? 0 : 30
            components.second = 0
            components.nanosecond = 0
            return calendar.date(from: components) ?? date
        }
    }
}

final class IOSGuideCollectionContainer: UIView {
    let collectionView: UICollectionView
    var onSizeChange: ((CGSize) -> Void)?
    private var lastSize = CGSize.zero

    init(collectionView: UICollectionView) {
        self.collectionView = collectionView
        super.init(frame: .zero)
        backgroundColor = .clear
        addSubview(collectionView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        collectionView.frame = bounds
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onSizeChange?(self.bounds.size)
        }
    }
}

private final class IOSGuideCollectionAttributes: UICollectionViewLayoutAttributes {
    var elapsedWidth: CGFloat = 0
    var clippedLeading: CGFloat = 0
    var clippedTop: CGFloat = 0
    var pinnedLeadingBoundary: CGFloat = 0

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! IOSGuideCollectionAttributes
        copy.elapsedWidth = elapsedWidth
        copy.clippedLeading = clippedLeading
        copy.clippedTop = clippedTop
        copy.pinnedLeadingBoundary = pinnedLeadingBoundary
        return copy
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? IOSGuideCollectionAttributes else { return false }
        return super.isEqual(object)
            && elapsedWidth == other.elapsedWidth
            && clippedLeading == other.clippedLeading
            && clippedTop == other.clippedTop
            && pinnedLeadingBoundary == other.pinnedLeadingBoundary
    }
}

final class IOSGuideCollectionLayout: UICollectionViewLayout {
    struct Span {
        let startMinute: CGFloat
        let durationMinutes: CGFloat
    }

    static let channelKind = "ios-guide-channel"
    static let timeKind = "ios-guide-time"
    static let cornerKind = "ios-guide-corner"

    override class var layoutAttributesClass: AnyClass { IOSGuideCollectionAttributes.self }

    var viewportSize = CGSize.zero
    var now = Date()
    private var rows: [[Span]] = []
    private var channelCount = 0
    private var totalMinutes = 0
    private var timelineStart = Date()

    var visibleMinutes: CGFloat {
        viewportSize.width > viewportSize.height ? 120 : 60
    }

    var pointsPerMinute: CGFloat {
        max(
            1,
            (max(viewportSize.width, 1) - IOSUIKitGuideMetrics.channelWidth)
                / visibleMinutes
        )
    }

    func configure(
        rows: [[Span]],
        channelCount: Int,
        totalMinutes: Int,
        timelineStart: Date,
        now: Date
    ) {
        self.rows = rows
        self.channelCount = channelCount
        self.totalMinutes = totalMinutes
        self.timelineStart = timelineStart
        self.now = now
        invalidateLayout()
    }

    override var collectionViewContentSize: CGSize {
        CGSize(
            width: CGFloat(totalMinutes) * pointsPerMinute,
            height: CGFloat(channelCount) * IOSUIKitGuideMetrics.rowHeight
        )
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { true }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let span = rows[safe: indexPath.section]?[safe: indexPath.item] else { return nil }
        let gap = IOSUIKitGuideMetrics.spacing
        let x = span.startMinute * pointsPerMinute + gap
        let width = max(2, span.durationMinutes * pointsPerMinute - gap * 2)
        let attributes = IOSGuideCollectionAttributes(forCellWith: indexPath)
        attributes.frame = CGRect(
            x: x,
            y: CGFloat(indexPath.section) * IOSUIKitGuideMetrics.rowHeight + gap,
            width: width,
            height: IOSUIKitGuideMetrics.rowHeight - gap * 2
        )
        if let collectionView {
            attributes.clippedLeading = max(
                0,
                collectionView.contentOffset.x
                    + IOSUIKitGuideMetrics.channelWidth
                    + gap
                    - attributes.frame.minX
            )
            attributes.clippedTop = max(
                0,
                collectionView.contentOffset.y
                    + IOSUIKitGuideMetrics.rulerHeight
                    + gap
                    - attributes.frame.minY
            )
        }
        let nowX = CGFloat(now.timeIntervalSince(timelineStart) / 60) * pointsPerMinute
        attributes.elapsedWidth = min(max(nowX - x, 0), width)
        return attributes
    }

    override func layoutAttributesForSupplementaryView(
        ofKind elementKind: String,
        at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        guard let collectionView else { return nil }
        let offset = collectionView.contentOffset
        let attributes = IOSGuideCollectionAttributes(
            forSupplementaryViewOfKind: elementKind,
            with: indexPath
        )
        switch elementKind {
        case Self.channelKind:
            let rowY = CGFloat(indexPath.section) * IOSUIKitGuideMetrics.rowHeight
            attributes.frame = CGRect(
                x: offset.x,
                y: rowY,
                width: IOSUIKitGuideMetrics.channelWidth,
                height: IOSUIKitGuideMetrics.rowHeight
            )
            // This value is relative to the inner logo box: both its own top
            // inset and the desired header gutter are the standard spacing.
            attributes.clippedTop = max(
                0,
                offset.y + IOSUIKitGuideMetrics.rulerHeight - rowY
            )
            attributes.zIndex = 10
        case Self.timeKind:
            attributes.frame = CGRect(
                x: 0,
                y: offset.y,
                width: CGFloat(totalMinutes) * pointsPerMinute,
                height: IOSUIKitGuideMetrics.rulerHeight
            )
            attributes.pinnedLeadingBoundary = offset.x
                + IOSUIKitGuideMetrics.channelWidth
                + IOSUIKitGuideMetrics.spacing
            attributes.zIndex = 12
        case Self.cornerKind:
            attributes.frame = CGRect(
                x: offset.x,
                y: offset.y,
                width: IOSUIKitGuideMetrics.channelWidth,
                height: IOSUIKitGuideMetrics.rulerHeight
            )
            attributes.zIndex = 20
        default:
            return nil
        }
        return attributes
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard channelCount > 0 else { return [] }
        var result: [UICollectionViewLayoutAttributes] = []
        let rowHeight = IOSUIKitGuideMetrics.rowHeight
        let firstSection = max(0, Int(floor(rect.minY / rowHeight)))
        let lastSection = min(channelCount - 1, Int(floor(rect.maxY / rowHeight)))

        if firstSection <= lastSection {
            for section in firstSection...lastSection {
                for (item, span) in (rows[safe: section] ?? []).enumerated() {
                    let minX = span.startMinute * pointsPerMinute
                    let maxX = minX + span.durationMinutes * pointsPerMinute
                    guard maxX >= rect.minX, minX <= rect.maxX else { continue }
                    if let attributes = layoutAttributesForItem(
                        at: IndexPath(item: item, section: section)
                    ) {
                        result.append(attributes)
                    }
                }
                if let channel = layoutAttributesForSupplementaryView(
                    ofKind: Self.channelKind,
                    at: IndexPath(item: 0, section: section)
                ) {
                    result.append(channel)
                }
            }
        }

        if let time = layoutAttributesForSupplementaryView(
            ofKind: Self.timeKind,
            at: IndexPath(item: 0, section: 0)
        ) { result.append(time) }
        if let corner = layoutAttributesForSupplementaryView(
            ofKind: Self.cornerKind,
            at: IndexPath(item: 0, section: 0)
        ) { result.append(corner) }
        return result
    }
}

private func iosUpdateGuideRoundedMask(
    _ mask: CAShapeLayer,
    bounds: CGRect,
    clippedLeading: CGFloat = 0,
    clippedTop: CGFloat = 0
) {
    let leading = min(max(clippedLeading, 0), bounds.width)
    let top = min(max(clippedTop, 0), bounds.height)
    let visibleRect = CGRect(
        x: leading,
        y: top,
        width: max(0, bounds.width - leading),
        height: max(0, bounds.height - top)
    )

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    mask.frame = bounds
    mask.fillColor = UIColor.white.cgColor
    mask.path = visibleRect.isEmpty
        ? UIBezierPath().cgPath
        : UIBezierPath(
            roundedRect: visibleRect,
            cornerRadius: IOSUIKitGuideMetrics.cornerRadius
        ).cgPath
    CATransaction.commit()
}

private final class IOSGuideProgramCollectionCell: UICollectionViewCell {
    static let reuseID = "ios-guide-program"

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let textStack = UIStackView()
    private let elapsedLayer = CALayer()
    private let visibleMask = CAShapeLayer()
    private var textLeadingConstraint: NSLayoutConstraint!
    private var elapsedWidth: CGFloat = 0
    private var clippedLeading: CGFloat = 0
    private var clippedTop: CGFloat = 0
    private let baseTextInset: CGFloat = 8

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor(white: 0, alpha: 0.32)
        contentView.layer.cornerRadius = IOSUIKitGuideMetrics.cornerRadius
        contentView.layer.cornerCurve = .continuous
        contentView.layer.masksToBounds = true

        elapsedLayer.backgroundColor = UIColor(white: 1, alpha: 0.22).cgColor
        contentView.layer.insertSublayer(elapsedLayer, at: 0)

        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 10)
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        subtitleLabel.numberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail

        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)
        textStack.axis = .vertical
        textStack.spacing = 1.5
        textStack.alignment = .leading
        textStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(textStack)
        textLeadingConstraint = textStack.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor,
            constant: baseTextInset
        )
        NSLayoutConstraint.activate([
            textLeadingConstraint,
            textStack.trailingAnchor.constraint(
                lessThanOrEqualTo: contentView.trailingAnchor,
                constant: -6
            ),
            textStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(program: IOSEPGProgram?) {
        titleLabel.text = program?.title ?? "No guide data available."
        subtitleLabel.text = program?.subtitle
        subtitleLabel.isHidden = (program?.subtitle?.isEmpty ?? true)
    }

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        if let attributes = layoutAttributes as? IOSGuideCollectionAttributes {
            elapsedWidth = attributes.elapsedWidth
            clippedLeading = attributes.clippedLeading
            clippedTop = attributes.clippedTop
        } else {
            elapsedWidth = 0
            clippedLeading = 0
            clippedTop = 0
        }
        updateLayers()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateLayers()
    }

    private func updateLayers() {
        // Match the tvOS guide: once a programme starts passing beneath the
        // pinned logo column, keep its title attached to the newly-visible
        // leading edge. Auto Layout continuously reduces the remaining label
        // width, so UIKit supplies the trailing ellipsis until the cell has
        // completely left the viewport.
        let leading = min(
            max(baseTextInset, clippedLeading + baseTextInset),
            bounds.width
        )
        textLeadingConstraint.constant = leading
        textStack.isHidden = bounds.width - leading - 6 <= 1

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        elapsedLayer.frame = CGRect(
            x: 0,
            y: 0,
            width: min(elapsedWidth, bounds.width),
            height: bounds.height
        )
        elapsedLayer.isHidden = elapsedWidth <= 0.5
        CATransaction.commit()
        if clippedLeading > 0 || clippedTop > 0 {
            contentView.layer.mask = visibleMask
            iosUpdateGuideRoundedMask(
                visibleMask,
                bounds: contentView.bounds,
                clippedLeading: clippedLeading,
                clippedTop: clippedTop
            )
        } else {
            contentView.layer.mask = nil
        }
    }

    override var isHighlighted: Bool {
        didSet {
            contentView.backgroundColor = isHighlighted
                ? UIColor(white: 0.96, alpha: 1)
                : UIColor(white: 0, alpha: 0.32)
            titleLabel.textColor = isHighlighted ? UIColor(white: 0.08, alpha: 1) : .white
            subtitleLabel.textColor = isHighlighted
                ? UIColor(white: 0.08, alpha: 0.65)
                : UIColor.white.withAlphaComponent(0.7)
        }
    }
}

private final class IOSGuideChannelReusableView: UICollectionReusableView {
    static let reuseID = "ios-guide-channel"

    private let box = UIView()
    private let imageView = UIImageView()
    private let fallbackLabel = UILabel()
    private let boxMask = CAShapeLayer()
    private var imageTask: Task<Void, Never>?
    private var representedURL: URL?
    private var clippedTop: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Pinned channel cells mask programme text as it scrolls beneath them;
        // the inner rounded box then preserves the same gutter as every cell.
        backgroundColor = .clear
        box.backgroundColor = UIColor(white: 0, alpha: 0.28)
        box.layer.cornerRadius = IOSUIKitGuideMetrics.cornerRadius
        box.layer.cornerCurve = .continuous
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)

        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(imageView)
        fallbackLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        fallbackLabel.textColor = .white
        fallbackLabel.textAlignment = .center
        fallbackLabel.numberOfLines = 2
        fallbackLabel.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(fallbackLabel)

        let gap = IOSUIKitGuideMetrics.spacing
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gap),
            box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -gap),
            box.topAnchor.constraint(equalTo: topAnchor, constant: gap),
            box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -gap),
            imageView.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            imageView.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            imageView.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            imageView.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
            fallbackLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
            fallbackLabel.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
            fallbackLabel.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        let newClippedTop = (
            layoutAttributes as? IOSGuideCollectionAttributes
        )?.clippedTop ?? 0
        guard newClippedTop != clippedTop else { return }
        clippedTop = newClippedTop
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if clippedTop > 0 {
            box.layer.mask = boxMask
            iosUpdateGuideRoundedMask(
                boxMask,
                bounds: box.bounds,
                clippedTop: clippedTop
            )
        } else {
            box.layer.mask = nil
        }
    }

    func configure(channel: IOSIPTVChannel) {
        fallbackLabel.text = channel.name
        representedURL = channel.logoURL
        imageTask?.cancel()
        imageView.image = nil
        fallbackLabel.isHidden = false
        guard let url = channel.logoURL else { return }

        imageTask = Task { [weak self] in
            let image = await IOSArtworkCache.shared.image(for: url)
            guard let self, !Task.isCancelled, representedURL == url else { return }
            imageView.image = image
            fallbackLabel.isHidden = image != nil
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        imageTask = nil
        representedURL = nil
        imageView.image = nil
    }
}

private final class IOSGuideTimeReusableView: UICollectionReusableView {
    static let reuseID = "ios-guide-time"
    private var configuration: (Date, Int, CGFloat)?
    private var boxes: [UIView] = []
    private var pinnedLeadingBoundary: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        pinnedLeadingBoundary = (
            layoutAttributes as? IOSGuideCollectionAttributes
        )?.pinnedLeadingBoundary ?? 0
        updateBoxMasks()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateBoxMasks()
    }

    func configure(start: Date, totalMinutes: Int, pointsPerMinute: CGFloat) {
        if let configuration,
           configuration.0 == start,
           configuration.1 == totalMinutes,
           abs(configuration.2 - pointsPerMinute) < 0.001 { return }
        self.configuration = (start, totalMinutes, pointsPerMinute)
        subviews.forEach { $0.removeFromSuperview() }
        boxes.removeAll(keepingCapacity: true)

        let gap = IOSUIKitGuideMetrics.spacing
        for minute in stride(from: 0, to: totalMinutes, by: 30) {
            let box = UIView(frame: CGRect(
                x: CGFloat(minute) * pointsPerMinute + gap,
                y: IOSUIKitGuideMetrics.rulerHeight
                    - IOSUIKitGuideMetrics.rulerBoxHeight - gap,
                width: CGFloat(30) * pointsPerMinute - gap * 2,
                height: IOSUIKitGuideMetrics.rulerBoxHeight
            ))
            box.backgroundColor = UIColor(white: 0, alpha: 0.28)
            box.layer.cornerRadius = IOSUIKitGuideMetrics.cornerRadius
            box.layer.cornerCurve = .continuous

            let label = UILabel(frame: box.bounds.insetBy(dx: 8, dy: 0))
            label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .white
            label.text = start.addingTimeInterval(TimeInterval(minute * 60))
                .formatted(.dateTime.hour().minute())
            box.addSubview(label)
            addSubview(box)
            boxes.append(box)
        }
        updateBoxMasks()
    }

    private func updateBoxMasks() {
        for box in boxes {
            let clippedLeading = pinnedLeadingBoundary - box.frame.minX
            if clippedLeading > 0 {
                let mask = (box.layer.mask as? CAShapeLayer) ?? CAShapeLayer()
                box.layer.mask = mask
                iosUpdateGuideRoundedMask(
                    mask,
                    bounds: box.bounds,
                    clippedLeading: clippedLeading
                )
            } else {
                box.layer.mask = nil
            }
        }
    }
}

private final class IOSGuideCornerReusableView: UICollectionReusableView {
    static let reuseID = "ios-guide-corner"
    private let box = UIView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        box.backgroundColor = UIColor(white: 0, alpha: 0.28)
        box.layer.cornerRadius = IOSUIKitGuideMetrics.cornerRadius
        box.layer.cornerCurve = .continuous
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        label.font = .systemFont(ofSize: 11.5, weight: .bold)
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)

        let gap = IOSUIKitGuideMetrics.spacing
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gap),
            box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -gap),
            box.topAnchor.constraint(
                equalTo: topAnchor,
                constant: IOSUIKitGuideMetrics.rulerHeight
                    - IOSUIKitGuideMetrics.rulerBoxHeight - gap
            ),
            box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -gap),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(date: Date) {
        label.text = Calendar.current.isDateInToday(date)
            ? "TODAY"
            : date.formatted(.dateTime.weekday(.abbreviated)).uppercased()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
