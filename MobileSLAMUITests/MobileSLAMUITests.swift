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
        let settings = app.buttons["設定"], stop = app.buttons["■  停止"], maps = app.buttons["PCD ビューア"]
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

    /// Maps the demo room, saves it, then opens it from the PCD viewer list and shares it from there.
    func testPcdViewerShare() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-autoStartMapping"]
        app.launch()
        let stop = app.buttons["■  停止"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "mapping did not start")
        sleep(8)
        stop.tap()
        app.buttons["PCD保存"].tap()

        app.buttons["PCD ビューア"].tap()
        XCTAssertTrue(app.navigationBars["PCD ビューア"].waitForExistence(timeout: 5))
        let first = app.cells.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5), "saved map not listed")
        save("viewer-list")

        // long press: share / delete menu
        first.press(forDuration: 1.0)
        let share = app.buttons["共有"]
        XCTAssertTrue(share.waitForExistence(timeout: 5), "no share in the context menu")
        XCTAssertTrue(app.buttons["削除"].exists)
        save("viewer-list-menu")
        share.tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 10), "share sheet did not open")
        save("viewer-list-share")
        // the share sheet cannot be dismissed reliably from UI tests: start over in the list
        app.terminate()
        app.launchArguments = []
        app.launch()
        app.buttons["PCD ビューア"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))

        // swipe left: share next to delete
        first.swipeLeft()
        XCTAssertTrue(app.buttons["共有"].waitForExistence(timeout: 5), "no share in the swipe actions")
        save("viewer-list-swipe")

        // tap: the 3D viewer
        first.swipeRight()
        first.tap()
        XCTAssertTrue(app.buttons["全体表示"].waitForExistence(timeout: 10), "viewer did not open")
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

    /// Records the demo sensor as a ROS 2 bag, then maps from that bag until it ends and saves the PCD.
    func testRosbagRecordAndReplay() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()
        let record = app.buttons["● 記録"]
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        sleep(2)
        record.tap()
        let recording = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '■ ' AND NOT (label CONTAINS '停止')")).firstMatch
        XCTAssertTrue(recording.waitForExistence(timeout: 5), "recording did not start")
        sleep(10)
        save("rosbag-recording")
        recording.tap()
        XCTAssertTrue(text(app, containing: "rosbag 保存").waitForExistence(timeout: 5), "no save toast")
        save("rosbag-saved")

        app.buttons["rosbag"].tap()
        XCTAssertTrue(app.navigationBars["rosbag を選択"].waitForExistence(timeout: 5))
        let first = app.cells.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5), "recorded bag not listed")
        save("rosbag-list")
        first.tap()
        let bagButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '📼'")).firstMatch
        XCTAssertTrue(bagButton.waitForExistence(timeout: 10), "bag not selected")
        XCTAssertTrue(app.buttons["実機に戻る"].exists)
        save("rosbag-selected")

        app.buttons["▶  マップ作成 開始"].tap()
        XCTAssertTrue(app.buttons["■  停止"].waitForExistence(timeout: 5), "mapping did not start")
        sleep(6)
        XCTAssertTrue(text(app, containing: "rosbag").exists)
        save("rosbag-mapping")
        // the bag is ~10 s: SLAM stops by itself at the end and the map can be saved
        let savePcd = app.buttons["PCD保存"]
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: savePcd)
        wait(for: [enabled], timeout: 30)
        XCTAssertTrue(app.buttons["▶  マップ作成 開始"].exists, "SLAM did not stop at the end of the bag")
        save("rosbag-finished")
        savePcd.tap()
        XCTAssertTrue(text(app, containing: "保存しました").waitForExistence(timeout: 5))

        app.buttons["実機に戻る"].tap()
        XCTAssertFalse(bagButton.waitForExistence(timeout: 2))
    }

    /// Records a rosbag while localizing against a freshly made map (recording works in every SLAM state).
    func testRecordDuringLocalization() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-autoStartMapping"]
        app.launch()
        let stop = app.buttons["■  停止"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "mapping did not start")
        sleep(8)
        stop.tap()
        app.buttons["PCD保存"].tap()

        app.buttons["自己位置推定"].tap()
        let confirm = app.alerts.buttons["切り替える"]
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }
        let map = app.cells.firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 5), "map picker did not open")
        map.tap()
        XCTAssertTrue(text(app, containing: "マップ読み込み").waitForExistence(timeout: 15), "map not loaded")
        let start = app.buttons["▶  自己位置推定 開始"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "localization did not start")

        app.buttons["● 記録"].tap()
        let recording = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '■ ' AND NOT (label CONTAINS '停止')")).firstMatch
        XCTAssertTrue(recording.waitForExistence(timeout: 5), "recording did not start")
        sleep(6)
        save("record-during-localization")
        recording.tap()
        XCTAssertTrue(text(app, containing: "rosbag 保存").waitForExistence(timeout: 5), "no save toast")
        XCTAssertTrue(stop.exists, "recording stopped localization")
    }

    /// Settings: rosbag options and the advanced SLAM parameters (change one, then reset all).
    func testSlamParams() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["設定"].tap()
        XCTAssertTrue(app.buttons["ROS 2 (MCAP)"].waitForExistence(timeout: 5))
        save("settings-rosbag")
        let link = app.staticTexts["詳細パラメータ"]
        link.tap()
        XCTAssertTrue(app.navigationBars["詳細パラメータ"].waitForExistence(timeout: 5))
        save("params-top")
        let slider = app.sliders.firstMatch
        slider.adjust(toNormalizedSliderPosition: 0.9)
        let resetOne = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '規定 '")).firstMatch
        XCTAssertTrue(resetOne.waitForExistence(timeout: 3), "changed value not marked")
        save("params-changed")
        for _ in 0..<6 where !app.buttons["すべて規定値に戻す"].isHittable { app.swipeUp() }
        save("params-bottom")
        app.buttons["すべて規定値に戻す"].tap()
        app.alerts.buttons["戻す"].tap()
        for _ in 0..<6 { app.swipeDown() }
        XCTAssertFalse(resetOne.exists, "reset all did not restore the default")
    }

    /// Creates a key pair, registers the public key with a test SFTP server, then sends a PCD and a rosbag.
    /// Needs tools started by the caller: SFTP_PORT (server on 127.0.0.1, user "tester") and SFTP_KEY_FILE
    /// (the host writes the simulator clipboard there, e.g. `xcrun simctl pbpaste booted`, for the server to read).
    func testSftpUpload() throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["SFTP_PORT"], let keyFile = env["SFTP_KEY_FILE"] else {
            throw XCTSkip("SFTP_PORT / SFTP_KEY_FILE not set")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-autoStartMapping", "-resetSftpHosts"]
        app.launch()

        // a map and a bag to send
        let record = app.buttons["● 記録"]
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        record.tap()
        sleep(8)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '■ ' AND NOT (label CONTAINS '停止')")).firstMatch.tap()
        app.buttons["■  停止"].tap()
        app.buttons["PCD保存"].tap()

        // key pair + copy the public key
        app.buttons["設定"].tap()
        let sftpLink = app.staticTexts["キーペアと送信先"]
        for _ in 0..<6 where !sftpLink.isHittable { app.swipeUp() }
        sftpLink.tap()
        let create = app.buttons["キーペアを作成"]
        if create.waitForExistence(timeout: 3) { create.tap() }
        let copy = app.buttons["公開鍵をコピー"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        XCTAssertTrue(app.buttons["コピーしました"].waitForExistence(timeout: 3))
        // the runner may not read the pasteboard: the host side copies it into keyFile (`simctl pbpaste`)
        var line = ""
        for _ in 0..<30 where !line.hasPrefix("ssh-ed25519 ") {
            sleep(1)
            line = (try? String(contentsOfFile: keyFile, encoding: .utf8)) ?? ""
        }
        XCTAssertTrue(line.hasPrefix("ssh-ed25519 "), "public key did not reach the clipboard")
        save("sftp-settings")

        // destination
        app.buttons["送信先を追加"].tap()
        let fields = ["sftp.name": "test server", "sftp.host": "127.0.0.1", "sftp.port": port,
                      "sftp.user": "tester", "sftp.path": "upload/mobile_slam"]
        for (id, value) in fields {
            let f = app.textFields[id]
            XCTAssertTrue(f.waitForExistence(timeout: 5), id)
            if id == "sftp.port" {
                // prefilled "22" reads like the placeholder to replace(): clear it explicitly
                f.tap()
                f.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + value)
            } else {
                replace(f, with: value, in: app)
            }
        }
        save("sftp-host-edit")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.textFields["sftp.host"].waitForNonExistence(timeout: 5), "destination not saved")
        XCTAssertTrue(app.staticTexts["test server"].waitForExistence(timeout: 5))
        // back to the main screen; the destination must survive a relaunch (let UserDefaults persist first)
        sleep(2)
        app.terminate()
        app.launchArguments = []
        app.launch()

        // PCD
        app.buttons["PCD ビューア"].tap()
        let pcd = app.cells.firstMatch
        XCTAssertTrue(pcd.waitForExistence(timeout: 5))
        pcd.press(forDuration: 1.0)
        app.buttons["SFTP で送信"].tap()
        let dest = app.buttons.matching(NSPredicate(format: "label CONTAINS 'test server'")).firstMatch
        XCTAssertTrue(dest.waitForExistence(timeout: 5), "destination not listed")
        dest.tap()
        XCTAssertTrue(text(app, containing: "送信しました").waitForExistence(timeout: 30), "PCD upload failed")
        save("sftp-pcd-sent")
        app.buttons["閉じる"].tap()
        app.terminate()
        app.launch()

        // rosbag
        app.buttons["rosbag"].tap()
        let bag = app.cells.firstMatch
        XCTAssertTrue(bag.waitForExistence(timeout: 5))
        bag.press(forDuration: 1.0)
        app.buttons["SFTP で送信"].tap()
        let bagDest = app.buttons.matching(NSPredicate(format: "label CONTAINS 'test server'")).firstMatch
        XCTAssertTrue(bagDest.waitForExistence(timeout: 5), "destination not listed")
        bagDest.tap()
        XCTAssertTrue(text(app, containing: "送信しました").waitForExistence(timeout: 60), "rosbag upload failed")
        save("sftp-bag-sent")
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
