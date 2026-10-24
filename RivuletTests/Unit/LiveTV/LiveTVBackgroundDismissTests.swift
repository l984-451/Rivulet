import XCTest
@testable import Rivulet

@MainActor
final class LiveTVBackgroundDismissTests: XCTestCase {
    func test_enteringBackground_dismissesLivePlayer() {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()

        let channel = UnifiedChannel(id: "test", sourceType: .dispatcharr, sourceId: "d", name: "Test",
                                     streamURL: URL(string: "http://127.0.0.1:1/x.ts"))
        let player = LiveTVAetherPlayerViewController(channel: channel)
        host.present(player, animated: false)
        XCTAssertNotNil(host.presentedViewController)

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        XCTAssertNil(host.presentedViewController)
    }
}
