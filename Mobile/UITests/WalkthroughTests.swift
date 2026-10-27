import XCTest

/// Walks through first use on iPad and saves screenshots (set SCREENSHOT_DIR to keep them).
final class WalkthroughTests: XCTestCase {
    func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }

    func drag(_ app: XCUIApplication, _ points: [CGVector]) {
        let canvas = app.windows.firstMatch
        var current = canvas.coordinate(withNormalizedOffset: points[0])
        for p in points.dropFirst() {
            let next = canvas.coordinate(withNormalizedOffset: p)
            current.press(forDuration: 0.05, thenDragTo: next, withVelocity: .slow, thenHoldForDuration: 0)
            current = next
        }
    }

    func testFirstUse() throws {
        let app = XCUIApplication()
        app.launch()
        let create = app.buttons["Create Document"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        let opened = app.staticTexts["New Diagram"].waitForExistence(timeout: 40)
        if !opened { shot("0-not-opened"); print(app.debugDescription) }
        XCTAssertTrue(opened)
        shot("1-new-diagram")
        app.buttons["new-c4"].tap()
        sleep(1)
        shot("2-blank-c4")

        // Draw a box as four strokes with a finger (a new diagram starts in Draw mode).
        let corners = [CGVector(dx: 0.35, dy: 0.3), CGVector(dx: 0.6, dy: 0.3), CGVector(dx: 0.6, dy: 0.42), CGVector(dx: 0.35, dy: 0.42)]
        for i in 0..<4 { drag(app, [corners[i], corners[(i + 1) % 4]]) }
        sleep(3)
        shot("3-recognised-asks-type")
        let system = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Software System'")).firstMatch
        XCTAssertTrue(system.waitForExistence(timeout: 5), "type question didn't appear")
        system.tap()
        sleep(1)
        shot("4-picked-system")

        // A connector that starts and ends on the same block opens rename.
        drag(app, [CGVector(dx: 0.45, dy: 0.34), CGVector(dx: 0.5, dy: 0.38)])
        sleep(3)
        shot("5-self-connector-renames")
        if app.alerts.firstMatch.exists { app.alerts.buttons["Cancel"].tap() }

        app.buttons["Add an element"].tap()
        sleep(1)
        shot("6-add-palette")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8)).tap()

        // Spec side by side, with completions while typing.
        app.buttons["Show spec"].tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.95)).tap()
        editor.typeText("\nPers")
        sleep(1)
        shot("7-spec-completion")
        let suggestion = app.buttons["Person("]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 3), "no completion offered")
        suggestion.tap()
        sleep(1)
        shot("8-completed")
    }
}
