import XCTest

/// Drives the narrated demo. Each scene lasts at least as long as its narration (audio/durations.json in
/// DEMO_DIR) and its start time is logged to DEMO_DIR/scenes.txt so the screen recording can be cut to match.
final class DemoTests: XCTestCase {
    var dir = ""
    var durations: [String: Double] = [:]
    var current: String?
    var started = Date()

    func scene(_ id: String?) {
        if let prev = current {
            let remaining = (durations[prev] ?? 3) + 0.7 - Date().timeIntervalSince(started)
            if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
        }
        current = id
        started = Date()
        let line = "\(id ?? "end") \(started.timeIntervalSince1970)\n"
        let url = URL(fileURLWithPath: dir + "/scenes.txt")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: url) }
    }

    func drag(_ app: XCUIApplication, _ a: CGVector, _ b: CGVector) {
        let w = app.windows.firstMatch
        w.coordinate(withNormalizedOffset: a).press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: b), withVelocity: .slow, thenHoldForDuration: 0)
    }

    func box(_ app: XCUIApplication, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) {
        let c = [CGVector(dx: x0, dy: y0), CGVector(dx: x1, dy: y0), CGVector(dx: x1, dy: y1), CGVector(dx: x0, dy: y1)]
        for i in 0..<4 { drag(app, c[i], c[(i + 1) % 4]) }
    }

    func name(_ app: XCUIApplication, _ text: String) {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.textFields.firstMatch.typeText(text)
        sleep(1)
        alert.buttons["OK"].tap()
    }

    func testDemo() throws {
        dir = ProcessInfo.processInfo.environment["DEMO_DIR"] ?? NSTemporaryDirectory()
        if let data = try? Data(contentsOf: URL(fileURLWithPath: dir + "/audio/durations.json")),
           let d = try? JSONSerialization.jsonObject(with: data) as? [String: Double] { durations = d }

        let app = XCUIApplication()
        app.launch()
        let create = app.buttons["Create Document"]
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        sleep(2)
        create.tap()
        XCTAssertTrue(app.staticTexts["New Diagram"].waitForExistence(timeout: 40))
        sleep(1)

        scene("s01_intro")
        scene("s02_type")
        sleep(3)
        app.buttons["new-c4"].tap()

        scene("s03_draw")
        box(app, 0.2, 0.32, 0.42, 0.46)
        let system = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Software System'")).firstMatch
        XCTAssertTrue(system.waitForExistence(timeout: 6))

        scene("s04_name")
        system.tap()
        name(app, "Online Shop")

        scene("s05_more")
        box(app, 0.6, 0.32, 0.82, 0.46)
        let db = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Container Database'")).firstMatch
        XCTAssertTrue(db.waitForExistence(timeout: 6))
        sleep(1)
        db.tap()
        name(app, "Orders DB")

        scene("s06_connect")
        drag(app, CGVector(dx: 0.425, dy: 0.39), CGVector(dx: 0.595, dy: 0.39))

        scene("s07_spec")
        app.buttons["Show spec"].tap()
        sleep(2)
        // End of the Rel(...) line, the last one before @enduml.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 340, dy: 242)).tap()
        sleep(1)
        app.textViews.firstMatch.typeText("\nPers")
        let person = app.buttons["Person("]
        if person.waitForExistence(timeout: 3) { sleep(1); person.tap() }
        app.textViews.firstMatch.typeText("customer, \"Customer\")")
        sleep(1)

        scene("s08_tidy")
        app.buttons["Hide spec"].tap()
        sleep(1)
        app.buttons["Add an element"].tap()
        sleep(3)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.85)).tap()
        sleep(1)
        app.buttons["More"].tap()
        if app.buttons["Auto Layout"].waitForExistence(timeout: 3) { app.buttons["Auto Layout"].tap() }
        sleep(2)
        app.buttons["More"].tap()
        sleep(3)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()

        scene("s09_outro")
        sleep(1)
        app.buttons["More"].tap()
        if app.buttons["Zoom to Fit"].waitForExistence(timeout: 3) { app.buttons["Zoom to Fit"].tap() }
        scene(nil)
    }
}
