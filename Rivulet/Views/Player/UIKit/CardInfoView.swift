// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit

// MARK: - StreamingModeInfo

/// Per-category delivery mode (Direct Play / Direct Stream / Transcode)
/// shown at the top of each section, so users can confirm playback status
/// without opening the Plex server dashboard.
struct StreamingModeInfo {
    enum Mode: String {
        case directPlay = "Direct Play"
        case directStream = "Direct Stream"
        case transcode = "Transcode"
    }
    let video: Mode
    let audio: Mode
    let subtitles: Mode
}

// MARK: - CardInfoView (Info tab)

/// Static media/tech sheet — the Info tab of the player's Now Playing popup.
/// Pure metadata (title, then VIDEO, AUDIO, SUBTITLES, FILE sections, each laid
/// out in two columns); no live rows and no timer. Live playback telemetry now
/// lives on the sibling Advanced tab (`CardStatsView`). Rows are built through
/// `PlayerInfoSheetStyle` so the two sheets stay visually identical.
final class CardInfoView: UIView, InfoTabSheet {

    private let metadata: PlexMetadata
    private let modes: StreamingModeInfo
    private let scrollView = InfoScrollView()
    private let stack = UIStackView()

    /// Fires when focus enters/leaves the sheet's sections, so the hosting
    /// panel can show a focus treatment the sheet itself can't draw.
    var onFocusChange: ((Bool) -> Void)? {
        didSet { scrollView.onFocusChange = onFocusChange }
    }

    var infoScrollView: InfoScrollView { scrollView }

    init(metadata: PlexMetadata, modes: StreamingModeInfo) {
        self.metadata = metadata
        self.modes = modes
        super.init(frame: .zero)
        setupViews()
        populate()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        stack.axis = .vertical
        stack.spacing = 12
        // .fill (not .leading) so the two-column section grids stretch to the
        // full sheet width and their columns split it evenly.
        stack.alignment = .fill
        scrollView.addSubview(stack)
        addSubview(scrollView)

        [scrollView, stack].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        // The scroll view grows with content up to the panel's own height
        // cap, so a short info sheet hugs its rows instead of collapsing
        // to zero height — same idiom as CardTrackListView.
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

    // MARK: - Content

    private var primaryVideoStream: PlexStream? {
        metadata.Media?.first?.Part?.first?.Stream?.first { $0.isVideo }
    }

    private var audioStreams: [PlexStream] {
        metadata.Media?.first?.Part?.first?.Stream?.filter { $0.isAudio } ?? []
    }

    private var subtitleStreams: [PlexStream] {
        metadata.Media?.first?.Part?.first?.Stream?.filter { $0.isSubtitle } ?? []
    }

    private func populate() {
        // No "Media Info" header (the popup's tab bar already names the sheet)
        // and no title: the Description tab carries the title now, and this
        // sheet's sections overflow the panel as it is.
        var video: [UIView] = [PlayerInfoSheetStyle.infoRow("Mode", modes.video.rawValue)]
        if let videoStream = primaryVideoStream {
            if let displayTitle = videoStream.displayTitle ?? videoStream.extendedDisplayTitle {
                video.append(PlayerInfoSheetStyle.infoRow("Format", displayTitle))
            }
            if videoStream.isDolbyVision {
                var dvInfo = "Profile \(videoStream.DOVIProfile ?? 0)"
                if let compatID = videoStream.DOVIBLCompatID {
                    dvInfo += " (CompatID \(compatID))"
                }
                video.append(PlayerInfoSheetStyle.infoRow("Dolby Vision", dvInfo))
            } else if videoStream.isHDR {
                video.append(PlayerInfoSheetStyle.infoRow("HDR", "HDR10"))
            }
            if let bitDepth = videoStream.bitDepth {
                video.append(PlayerInfoSheetStyle.infoRow("Bit Depth", "\(bitDepth)-bit"))
            }
            if let colorSpace = videoStream.colorSpace {
                video.append(PlayerInfoSheetStyle.infoRow("Color Space", colorSpace))
            }
        } else if let media = metadata.Media?.first {
            if let codec = media.videoCodec {
                video.append(PlayerInfoSheetStyle.infoRow("Codec", codec.uppercased()))
            }
            if let res = media.videoResolution {
                video.append(PlayerInfoSheetStyle.infoRow("Resolution", res))
            }
        }
        if let media = metadata.Media?.first {
            if let width = media.width, let height = media.height {
                video.append(PlayerInfoSheetStyle.infoRow("Dimensions", "\(width) × \(height)"))
            }
            if let frameRate = media.videoFrameRate {
                video.append(PlayerInfoSheetStyle.infoRow("Frame Rate", frameRate))
            }
            if let bitrate = media.bitrate {
                // Plex reports bitrate in kbps; the formatter takes bits/sec
                // (same conversion PlexMediaMapper applies).
                video.append(PlayerInfoSheetStyle.infoRow("Bitrate", PlayerInfoSheetStyle.bitrate(bitrate * 1000)))
            }
        }
        addSection("VIDEO", rows: video)

        if !audioStreams.isEmpty {
            var audio: [UIView] = [PlayerInfoSheetStyle.infoRow("Mode", modes.audio.rawValue)]
            for (index, stream) in audioStreams.enumerated() {
                let title = stream.displayTitle ?? stream.extendedDisplayTitle ?? "Track \(index + 1)"
                var detail = title
                // Plex reports stream bitrate in kbps; the formatter takes
                // bits/sec. Often absent for lossless/embedded tracks — the
                // segment is then simply omitted rather than printing a zero.
                if let bitrate = stream.bitrate, bitrate > 0 {
                    detail += " · \(PlayerInfoSheetStyle.bitrate(bitrate * 1000))"
                }
                if let sampleRate = stream.samplingRate {
                    detail += " · \(sampleRate / 1000) kHz"
                }
                audio.append(PlayerInfoSheetStyle.bodyLabel(detail, secondary: false))
            }
            addSection("AUDIO", rows: audio)
        }

        if !subtitleStreams.isEmpty {
            var subs: [UIView] = [PlayerInfoSheetStyle.infoRow("Mode", modes.subtitles.rawValue)]
            for stream in subtitleStreams {
                var title = stream.extendedDisplayTitle ?? stream.displayTitle ?? "Unknown"
                var badges: [String] = []
                if stream.forced == true { badges.append("Forced") }
                if stream.hearingImpaired == true { badges.append("SDH") }
                if stream.default == true { badges.append("Default") }
                if !badges.isEmpty {
                    title += " (\(badges.joined(separator: ", ")))"
                }
                subs.append(PlayerInfoSheetStyle.bodyLabel(title, secondary: false))
            }
            addSection("SUBTITLES", rows: subs)
        }

        if let part = metadata.Media?.first?.Part?.first {
            var file: [UIView] = []
            if let path = part.file {
                let filename = (path as NSString).lastPathComponent
                file.append(PlayerInfoSheetStyle.infoRow("Name", filename))
            }
            if let container = part.container ?? metadata.Media?.first?.container {
                file.append(PlayerInfoSheetStyle.infoRow("Container", container.uppercased()))
            }
            if let size = part.size {
                file.append(PlayerInfoSheetStyle.infoRow("Size", PlayerInfoSheetStyle.fileSize(Int64(size))))
            }
            if let duration = metadata.duration ?? part.duration {
                file.append(PlayerInfoSheetStyle.infoRow("Duration", PlayerInfoSheetStyle.duration(duration)))
            }
            addSection("FILE", rows: file)
        }
    }

    /// Adds a section: a label plus rows in two equal columns, wrapped in ONE
    /// `InfoFocusRowView` so focus steps section-to-section. Per-line focus gave
    /// a dozen indistinguishable stops with no sense of position; the section is
    /// the unit a reader actually moves between.
    private func addSection(_ title: String, rows: [UIView]) {
        guard !rows.isEmpty else { return }
        let section = UIStackView()
        section.axis = .vertical
        section.spacing = 12
        section.alignment = .fill
        section.addArrangedSubview(PlayerInfoSheetStyle.sectionLabel(title))
        section.addArrangedSubview(PlayerInfoSheetStyle.twoColumnGrid(rows))
        let focusRow = InfoFocusRowView()
        focusRow.setFullWidth(section)
        stack.addArrangedSubview(focusRow)
    }
}
