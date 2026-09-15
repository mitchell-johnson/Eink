import XCTest

final class StudioUITests: XCTestCase {
    func testCreationAndPrivateConnectionFlow() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Label Studio"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Generate label"].isEnabled)
        XCTAssertFalse(app.buttons["Choose label & write"].isEnabled)
        attach(app, name: "Create")

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.textFields["Server address"].waitForExistence(timeout: 5))
        app.buttons["Save & test connection"].tap()
        XCTAssertTrue(app.staticTexts["Enter your private connection code. It must have at least 32 characters and no spaces."].waitForExistence(timeout: 5))
        let saveLabelKey = app.buttons["Save label key"]
        for _ in 0..<3 where !saveLabelKey.isHittable { app.swipeUp() }
        XCTAssertTrue(app.secureTextFields["Label authentication key"].exists)
        saveLabelKey.tap()
        XCTAssertTrue(app.staticTexts["Enter the label authentication key as exactly 32 hexadecimal characters (0–9, A–F)."].waitForExistence(timeout: 5))
        attach(app, name: "Private server settings")
        app.buttons["Done"].tap()

        let prompt = app.textViews["Design prompt"]
        prompt.tap()
        prompt.typeText("Fresh lemons")
        app.swipeUp()
        app.buttons["Generate label"].tap()
        XCTAssertTrue(app.alerts.staticTexts["Connect your private server in Settings first."].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.staticTexts["Your little collection"].waitForExistence(timeout: 5))
        attach(app, name: "Library")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
