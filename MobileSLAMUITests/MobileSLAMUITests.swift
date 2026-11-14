import XCTest

/// UI checks run on the simulator:
///   xcodebuild test -scheme MobileSLAMUITests -destination 'platform=iOS Simulator,name=…'
/// Screenshots are attached to the result bundle (and written to $SCREENSHOT_DIR when set).
/// testMid360Network needs a fake Mid-360 answering on 127.0.0.1:56100 (tools/fake_mid360.py).
final class MobileSLAMUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    /// Main screen in landscape while mapping the demo room: the status card and the controls sit side by side,
    /// stay inside the window and do not overlap.
    func testLandscapeMapping() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-autoStartMapping"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(10)

        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(window.width, window.height, "not landscape")
        let settings = app.buttons["設定"], stop = app.buttons["■  停止"], maps = app.buttons["保存済みマップ"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "mapping did not start")
        for e in [settings, stop, maps, app.buttons["マップ作成"], app.buttons["自己位置推定"]] {
            XCTAssertTrue(e.isHittable, "\(e) not hittable")
            XCTAssertTrue(window.contains(e.frame), "\(e) outside the window")
        }
        // status card on the left half, start / stop on the right half
        XCTAssertLessThan(settings.frame.maxX, window.midX + 20)
        XCTAssertGreaterThan(stop.frame.minX, window.midX - 20)
        save("landscape-mapping")

        // the settings and network screens in landscape too
        settings.tap()
        let link = app.staticTexts["IP アドレスと送信先"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        save("landscape-settings")
        link.tap()
        XCTAssertTrue(app.buttons["Mid-360 に書き込む"].waitForExistence(timeout: 5))
        save("landscape-network")
    }

    /// Reads the settings of the fake Mid-360, then changes its IP and destination (and reboots it).
    func testMid360Network() {
        let app = XCUIApplication()
        app.launchArguments = ["-openMid360Network"]
        app.launch()
        let fields = app.textFields
        XCTAssertTrue(fields.element(boundBy: 0).waitForExistence(timeout: 5))

        replace(fields.element(boundBy: 0), with: "127.0.0.1", in: app)       // current Mid-360
        app.buttons["現在の設定を読み込む"].tap()
        XCTAssertTrue(text(app, containing: "読み込みました").waitForExistence(timeout: 8), "read failed")
        XCTAssertEqual(fields.element(boundBy: 1).value as? String, "192.168.1.123")
        XCTAssertEqual(fields.element(boundBy: 2).value as? String, "255.255.255.0")
        XCTAssertEqual(fields.element(boundBy: 3).value as? String, "192.168.1.1")
        save("network-loaded")

        replace(fields.element(boundBy: 1), with: "192.168.1.124", in: app)   // new Mid-360 IP
        replace(fields.element(boundBy: 4), with: "192.168.1.60", in: app)    // destination
        let write = app.buttons["Mid-360 に書き込む"]
        if !write.isHittable { app.swipeUp() }
        write.tap()
        let confirm = app.buttons["書き込む"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no confirmation")
        save("network-confirm")
        confirm.tap()
        XCTAssertTrue(text(app, containing: "Mid-360 を再起動しています").waitForExistence(timeout: 8), "write failed")
        save("network-written")
    }

    // ------------------------------------------------------------------ helpers

    private func replace(_ field: XCUIElement, with s: String, in app: XCUIApplication) {
        if !field.isHittable { app.swipeUp() }
        field.tap()
        let old = (field.value as? String) ?? ""
        if !old.isEmpty && old != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        field.typeText(s)
        // iPad has no decimal pad: commit a (possibly IME-composed) entry with Return
        if UIDevice.current.userInterfaceIdiom == .pad { field.typeText("\n") }
    }

    private func text(_ app: XCUIApplication, containing s: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }

    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            let dev = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(dev)-\(name).png"))
        }
    }
}
