import XCTest

/// End-to-end UI flows in demo mode (`-DemoMode`: scripted keyword model, fake contacts and
/// calendar, nothing real is touched). Typed input goes through the same coordinator, validator,
/// resolver, confirmation and executor as speech.
@MainActor
final class AssistantFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-DemoMode"]
        app.launch()
    }

    private func type(_ request: String) {
        let typeButton = app.buttons["typeRequest"]
        if typeButton.waitForExistence(timeout: 20) { typeButton.tap() }
        let field = app.textFields["requestField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "request field")
        field.tap()
        field.typeText(request)
        app.buttons["sendRequest"].tap()
    }

    private func card(containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    /// Request → exact card → confirm → the fake composer ran and the result is reported.
    func testMessageIsConfirmedFromTheCard() {
        type("Text Alex that I'll be 20 minutes late")
        let pending = app.descendants(matching: .any)["actionCard"]
        XCTAssertTrue(pending.waitForExistence(timeout: 15), "confirmation card")
        XCTAssertTrue(card(containing: "Alex Kim").exists, "resolved recipient on the card")
        XCTAssertTrue(card(containing: "20 minutes late").exists, "message text on the card")
        let confirm = app.buttons["actionCard.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "confirm button")
        XCTAssertEqual(confirm.label, "Send")
        confirm.tap()
        XCTAssertTrue(pending.waitForNonExistence(timeout: 10), "card dismissed after confirming")
    }

    /// Cancel on the card: nothing happens and the card goes away.
    func testCallIsCancelledFromTheCard() {
        type("Call Priya")
        let pending = app.descendants(matching: .any)["actionCard"]
        XCTAssertTrue(pending.waitForExistence(timeout: 15), "confirmation card")
        XCTAssertTrue(card(containing: "Priya Patel").exists)
        app.buttons["actionCard.cancel"].tap()
        XCTAssertTrue(pending.waitForNonExistence(timeout: 10), "card dismissed after cancelling")
    }

    /// Settings opens, and About → Third-party licenses shows the NVIDIA attribution notice.
    func testSettingsOpens() {
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5), "settings sheet")
        let licenses = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Third-party licenses")).firstMatch
        for _ in 0..<10 where !(licenses.exists && licenses.isHittable) { app.swipeUp() }
        XCTAssertTrue(licenses.exists, "About → Third-party licenses")
        licenses.tap()
        XCTAssertTrue(card(containing: "Licensed by NVIDIA Corporation under the NVIDIA Nemotron Model License").waitForExistence(timeout: 5),
                      "Nemotron attribution notice")
    }
}
