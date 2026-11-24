import UIKit
import XCTest
@testable import SpritzMobile

@MainActor
final class KeyboardBridgeIntegrationTests: XCTestCase {
    private func makeHarness(initialText: String = "") -> (
        bridge: SpritzIosBridge,
        tv: UITextView,
        target: TextViewDocumentTarget,
        container: SpritzKeyboardContainerView
    ) {
        let bridge = SpritzIosBridge()
        let savedConfig = bridge.loadConfig()
        var testConfig = savedConfig
        testConfig.rejectedCorrections = [:]
        testConfig.autocorrect = .gentle
        testConfig.autoCaps = true
        testConfig.englishVariant = .au
        bridge.saveConfig(testConfig)

        addTeardownBlock {
            bridge.saveConfig(savedConfig)
        }

        let tv = UITextView(frame: CGRect(x: 0, y: 0, width: 350, height: 120))
        tv.text = initialText
        tv.selectedRange = NSRange(location: (initialText as NSString).length, length: 0)
        let target = TextViewDocumentTarget(textView: tv)

        let container = SpritzKeyboardContainerView(bridge: bridge, needsGlobe: true)
        container.target = target
        container.reloadConfiguration(needsGlobe: true)
        return (bridge, tv, target, container)
    }

    private func typeWord(_ word: String, bridge: SpritzIosBridge, target: TextViewDocumentTarget) {
        for ch in word {
            _ = bridge.tapKey(String(ch), normPoint: CGPoint(x: 0.5, y: 0.5), target: target)
        }
    }

    func testTypingAutocorrectContractionsReturnCommitAndBackspaceUndo() {
        let h = makeHarness(initialText: "fix ")

        // Autocorrect 'teh' on space, undo on immediate backspace, and respect learned rejection.
        typeWord("teh", bridge: h.bridge, target: h.target)
        _ = h.bridge.tapSpace(target: h.target)
        XCTAssertEqual(h.tv.text, "fix the ")

        _ = h.bridge.tapBackspace(target: h.target)
        XCTAssertEqual(h.tv.text, "fix teh ")

        typeWord("teh", bridge: h.bridge, target: h.target)
        _ = h.bridge.tapSpace(target: h.target)
        XCTAssertEqual(h.tv.text, "fix teh teh ")

        // Standalone 'i' -> 'I', contractions, and snippets.
        typeWord("i", bridge: h.bridge, target: h.target)
        _ = h.bridge.tapSpace(target: h.target)
        XCTAssertTrue(h.tv.text.hasSuffix("I "))

        typeWord("dont", bridge: h.bridge, target: h.target)
        _ = h.bridge.tapSpace(target: h.target)
        XCTAssertTrue(h.tv.text.hasSuffix("don't "))

        typeWord("/shrug", bridge: h.bridge, target: h.target)
        _ = h.bridge.tapSpace(target: h.target)
        XCTAssertTrue(h.tv.text.hasSuffix("¯\\_(ツ)_/¯ "))

        // Unrejected word commits on Return too.
        typeWord("becuase", bridge: h.bridge, target: h.target)
        _ = h.bridge.tapReturn(target: h.target)
        XCTAssertTrue(h.tv.text.hasSuffix("because\n"))
    }

    func testUITextCheckerShieldsValidOutOfLexiconWords() {
        let h = makeHarness(initialText: "review ")
        let candidate = "pharmacokinetics"
        XCTAssertTrue(
            h.bridge.isSystemKnownWord(candidate),
            "UITextChecker should recognize '\(candidate)'"
        )
        typeWord(candidate, bridge: h.bridge, target: h.target)
        _ = h.bridge.tapSpace(target: h.target)
        XCTAssertEqual(h.tv.text, "review \(candidate) ")
    }

    func testExternalTextDidChangeDebouncePreservesGlideCandidates() {
        let h = makeHarness(initialText: "")
        let deck = h.container.debugDeckView
        let height = SpritzKeyboardContainerView.preferredHeight(numberRow: h.bridge.loadConfig().numberRow)
        h.container.frame = CGRect(x: 0, y: 0, width: 393, height: height)
        h.container.layoutIfNeeded()
        deck.layoutIfNeeded()

        guard let hFrame = deck.debugTileFrame(id: "h"),
              let eFrame = deck.debugTileFrame(id: "e"),
              let lFrame = deck.debugTileFrame(id: "l"),
              let oFrame = deck.debugTileFrame(id: "o") else {
            XCTFail("Missing glide letters")
            return
        }

        let pts = [hFrame, eFrame, lFrame, oFrame].map { CGPoint(x: $0.midX, y: $0.midY) }
        deck.handleTouchDown(id: 1, at: pts[0], timestamp: 1.0)
        deck.handleTouchMove(id: 1, to: pts[1], timestamp: 1.06)
        deck.handleTouchMove(id: 1, to: pts[2], timestamp: 1.12)
        deck.handleTouchMove(id: 1, to: pts[3], timestamp: 1.18)
        deck.handleTouchUp(id: 1, at: pts[3], timestamp: 1.22)

        guard let beforeRefresh = h.container.debugLastOutput else {
            XCTFail("Expected glide output")
            return
        }
        XCTAssertTrue(beforeRefresh.autoSpaceActive)
        XCTAssertEqual(beforeRefresh.candidates.first?.kind, "glide")

        // Asynchronous UIKit textDidChange firing immediately after our own edit must not clobber glide candidates.
        h.container.handleExternalTextDidChange()

        XCTAssertEqual(h.container.debugLastOutput?.candidates, beforeRefresh.candidates)
        XCTAssertEqual(h.container.debugLastOutput?.autoSpaceActive, true)
    }

    func testEmojiGridToggleAndPickInsertsEmoji() {
        let h = makeHarness(initialText: "cheers ")
        XCTAssertFalse(h.container.debugIsEmojiGridVisible)

        h.container.debugDeckView.onRequestEmoji?()
        XCTAssertTrue(h.container.debugIsEmojiGridVisible)

        _ = h.bridge.emojiPick(hex: "1F525", target: h.target)
        XCTAssertTrue(h.tv.text.hasSuffix("🔥"))
    }
}
