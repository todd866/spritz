import XCTest

final class SpritzMobileUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLiveDeckTypingInputSwitchAndCompanionTabs() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--preview-tab", "keyboard",
            "--preview-deck", "abc",
            "--preview-text", "",
        ]
        app.launch()

        let testPad = app.textViews["spritz.testPad"]
        XCTAssertTrue(testPad.waitForExistence(timeout: 5))

        let embedded = app.otherElements["spritz.embeddedDeck"]
        XCTAssertTrue(embedded.waitForExistence(timeout: 5))

        // Tap keys on the live embedded deck: top 42 pt is InstrumentBar; below that:
        // row 0: 1..0 (30 pt), row 1: q..p, row 2: a..l, row 3: shift z..m backspace, row 4: utility + space.
        let deckOrigin = CGPoint(x: embedded.frame.minX, y: embedded.frame.minY + 42)
        let deckSize = CGSize(width: embedded.frame.width, height: embedded.frame.height - 42)
        let numRowH: CGFloat = 30
        let keyRowH = (deckSize.height - numRowH - 12 - 20) / 4.0
        let letterRow1Y = deckOrigin.y + 6 + numRowH + 5 + keyRowH * 0.5
        let bottomRowY = deckOrigin.y + deckSize.height - 6 - keyRowH * 0.5

        func normX(_ col: CGFloat) -> CGPoint {
            let x = deckOrigin.x + (col / 10.0) * deckSize.width
            return CGPoint(x: x, y: letterRow1Y)
        }

        // Tap 't' (col 4.5), 'e' (col 2.5), 'h' (middle row y), space.
        let middleRowY = letterRow1Y + keyRowH + 5
        let tapT = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: normX(4.5).x, dy: letterRow1Y))
        let tapE = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: normX(2.5).x, dy: letterRow1Y))
        let tapH = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: deckOrigin.x + deckSize.width * 0.60, dy: middleRowY))
        let tapSpace = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: deckOrigin.x + deckSize.width * 0.52, dy: bottomRowY))

        tapT.tap()
        tapE.tap()
        tapH.tap()
        tapSpace.tap()

        let typedText = (testPad.value as? String) ?? ""
        XCTAssertFalse(typedText.isEmpty, "Expected Test Pad to reflect taps on the embedded keyboard")

        // Switch Deck -> System -> Deck using header segmented picker.
        let sysBtn = app.buttons["System"].firstMatch
        XCTAssertTrue(sysBtn.waitForExistence(timeout: 3))
        sysBtn.tap()
        XCTAssertFalse(embedded.waitForExistence(timeout: 1))

        let deckBtn = app.buttons["Deck"].firstMatch
        XCTAssertTrue(deckBtn.waitForExistence(timeout: 3))
        deckBtn.tap()
        XCTAssertTrue(embedded.waitForExistence(timeout: 3))

        // Switch to Typing tab and check live dictionary readout.
        let typingTab = app.buttons["Typing"].firstMatch
        XCTAssertTrue(typingTab.waitForExistence(timeout: 3))
        typingTab.tap()
        let countLabel = app.staticTexts["spritz.lexiconCount"].firstMatch
        XCTAssertTrue(countLabel.waitForExistence(timeout: 3))
        XCTAssertTrue(countLabel.label.contains("learned"), "Unexpected lexicon label: \(countLabel.label)")

        // Switch to Emoji tab and verify companion configuration sections render.
        let emojiTab = app.buttons["Emoji"].firstMatch
        XCTAssertTrue(emojiTab.waitForExistence(timeout: 3))
        emojiTab.tap()
        XCTAssertTrue(app.staticTexts["Pinned slots"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Snippets"].waitForExistence(timeout: 3))
    }
}
