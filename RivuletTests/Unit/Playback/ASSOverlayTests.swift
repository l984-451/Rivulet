import XCTest
@testable import Rivulet

@MainActor
final class ASSOverlayTests: XCTestCase {

    private static let header = """
    [Script Info]
    PlayResX: 1920
    PlayResY: 1080

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Helvetica Neue,60,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,40,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

    """

    private func cue(_ id: Int, _ lines: String, start: Double = 0, end: Double = 10) -> AetherSubtitleCue {
        AetherSubtitleCue(id: id, startTime: start, endTime: end, body: .assEvents(lines))
    }

    private func track(_ id: Int = 3) -> ASSTrackSource {
        ASSTrackSource(trackId: id, header: Self.header, fonts: [])
    }

    private func captionBoxes(in overlay: CaptionOverlayView) -> Int {
        overlay.subviews.filter { !($0 is ASSOverlayView) }.count
    }

    private func makeOverlay(style: CaptionStyle? = nil) -> (CaptionOverlayView, SubtitleModel) {
        let model = SubtitleModel()
        let overlay = CaptionOverlayView(model: model, style: style ?? .default,
                                         videoSize: CGSize(width: 1920, height: 1080))
        overlay.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        model.sourceTime = 5
        return (overlay, model)
    }

    func test_sameCuesFedTwice_addEachEventOnce() {
        let model = SubtitleModel()
        let view = ASSOverlayView(model: model)
        view.track = track()
        let cues = [cue(1, "0,0,Default,,0,0,0,,Hello\n0,0,Default,,0,0,0,,{\\pos(10,20)}Sign")]
        model.update(cues: cues)
        model.update(cues: cues)
        XCTAssertEqual(view.renderedEventCount, 2)
    }

    /// The engine trims an open-ended cue's end time on a later drain tick
    /// (alignCueEnds) and republishes it. The same line must not reach libass
    /// twice, or it draws doubled until the trim point.
    func test_sameLineWithEditedEnd_isAddedOnce() {
        let model = SubtitleModel()
        let view = ASSOverlayView(model: model)
        view.track = track()
        let line = "0,0,Sign,,0,0,0,,{\\pos(960,100)}Group logo"
        model.update(cues: [cue(1, line, start: 0, end: 36_000)])
        model.update(cues: [cue(1, line, start: 0, end: 12)])
        XCTAssertEqual(view.renderedEventCount, 1)
    }

    func test_newTrackInstance_startsEmptyAndRefeedsCurrentCues() {
        let model = SubtitleModel()
        let view = ASSOverlayView(model: model)
        view.track = track(3)
        model.update(cues: [cue(1, "0,0,Default,,0,0,0,,Old track line")])
        model.update(cues: [cue(2, "0,0,Default,,0,0,0,,New track line")])
        XCTAssertEqual(view.renderedEventCount, 2)
        view.track = track(4)
        XCTAssertEqual(view.renderedEventCount, 1, "only the cues the model holds now")
    }

    func test_libassMode_drawsNoPlainCaptions() {
        let (overlay, model) = makeOverlay()
        overlay.assTrack = track()
        model.update(cues: [cue(1, "0,0,Default,,0,0,0,,Hello")])
        XCTAssertEqual(captionBoxes(in: overlay), 0)
    }

    func test_pinned_drawsPlainCaptionWithSystemStyle() {
        var pinned = CaptionStyle.default
        pinned.allowsContentFont = false
        let (overlay, model) = makeOverlay(style: pinned)
        overlay.assTrack = track()
        model.update(cues: [cue(1, "0,0,Default,,0,0,0,,{\\i1}Hello")])
        XCTAssertEqual(captionBoxes(in: overlay), 1)
    }

    func test_pinned_dropsDrawingsAndKeepsText() {
        var pinned = CaptionStyle.default
        pinned.allowsContentColor = false
        let (overlay, model) = makeOverlay(style: pinned)
        overlay.assTrack = track()
        model.update(cues: [cue(1, "0,0,Sign,,0,0,0,,{\\p1}m 0 0 l 100 0{\\p0}\n0,0,Sign,,0,0,0,,{\\an8\\pos(960,100)}Station")])
        XCTAssertEqual(captionBoxes(in: overlay), 1)
    }

    func test_styleFlip_switchesBetweenLibassAndPlainCaptions() {
        let (overlay, model) = makeOverlay()
        overlay.assTrack = track()
        model.update(cues: [cue(1, "0,0,Default,,0,0,0,,Hello")])
        XCTAssertEqual(captionBoxes(in: overlay), 0)
        var pinned = CaptionStyle.default
        pinned.allowsContentFontSize = false
        overlay.style = pinned
        XCTAssertEqual(captionBoxes(in: overlay), 1)
        overlay.style = .default
        XCTAssertEqual(captionBoxes(in: overlay), 0)
    }
}
