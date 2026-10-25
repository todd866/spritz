import CoreGraphics
import Foundation
import Testing
@testable import Mojito

/// Choosing the caret rect from an app's `AXBoundsForRange` answers. The
/// fixtures are what TextEdit returned for a document holding `:::bees` with
/// the caret at the end (AX top-left coordinates).
@MainActor
struct CaretLocatorTests {

    private struct FakeText {
        var text: String
        var rects: [String: CGRect]

        func bounds(_ range: CFRange) -> CGRect? { rects["\(range.location),\(range.length)"] }
        func character(_ index: Int) -> String? {
            guard index >= 0, index < text.count else { return nil }
            return String(text[text.index(text.startIndex, offsetBy: index)])
        }
    }

    private func resolve(_ fake: FakeText, caret: Int, length: Int = 0) -> CGRect? {
        CaretLocator.resolveCaret(
            selection: CFRange(location: caret, length: length),
            bounds: fake.bounds,
            character: fake.character
        )
    }

    @Test func endOfTextAnchorsOnPrecedingGlyphNotZeroLengthRange() {
        let fake = FakeText(text: ":::bees", rects: [
            "7,0": CGRect(x: 475.0234375, y: 244, width: 0, height: 14),   // one line too high
            "6,1": CGRect(x: 469.0234375, y: 258, width: 6, height: 14),
        ])
        #expect(resolve(fake, caret: 7) == CGRect(x: 475.0234375, y: 258, width: 0, height: 14))
    }

    @Test func midTextUsesTheNextGlyph() {
        let next = CGRect(x: 449, y: 258, width: 6, height: 14)
        let fake = FakeText(text: ":::bees", rects: [
            "3,1": next,
            "2,1": CGRect(x: 443, y: 258, width: 6, height: 14),
        ])
        #expect(resolve(fake, caret: 3) == next)
    }

    @Test func caretAfterLineBreakDoesNotJumpToPreviousLine() {
        let zeroLength = CGRect(x: 439, y: 272, width: 0, height: 14)
        let fake = FakeText(text: "hi\n", rects: [
            "3,0": zeroLength,
            "2,1": CGRect(x: 451, y: 258, width: 4, height: 14),   // the newline, on line 1
        ])
        #expect(resolve(fake, caret: 3) == zeroLength)
    }

    @Test func unreadablePrecedingCharacterFallsBackToZeroLengthRange() {
        let zeroLength = CGRect(x: 475, y: 244, width: 0, height: 14)
        let fake = FakeText(text: "", rects: [
            "7,0": zeroLength,
            "6,1": CGRect(x: 469, y: 258, width: 6, height: 14),
        ])
        #expect(resolve(fake, caret: 7) == zeroLength)
    }

    @Test func emptyFieldUsesZeroLengthRange() {
        let zeroLength = CGRect(x: 439, y: 258, width: 0, height: 14)
        let fake = FakeText(text: "", rects: ["0,0": zeroLength])
        #expect(resolve(fake, caret: 0) == zeroLength)
    }

    @Test func selectionMeasuresTheSelectedRange() {
        let selected = CGRect(x: 443, y: 258, width: 18, height: 14)
        let fake = FakeText(text: ":::bees", rects: ["2,3": selected])
        #expect(resolve(fake, caret: 2, length: 3) == selected)
    }

    @Test func windowRoleIsNeverTreatedAsTextCaret() {
        #expect(!CaretLocator.isTextInputRole("AXWindow"))
        #expect(!CaretLocator.isTextInputRole(nil))
    }

    @Test func normalTextFieldRoleAllowsElementFallback() {
        #expect(CaretLocator.isTextInputRole("AXTextField"))
        #expect(CaretLocator.isTextInputRole("AXTextArea"))
        #expect(CaretLocator.isTextInputRole("AXSearchField"))
    }

    @Test func usableWindowAnchorSitsInLowerPortion() {
        let window = CGRect(x: 100, y: 100, width: 1_000, height: 800)
        let anchor = CaretLocator.windowFallbackRect(windowFrame: window, screenFrames: [CGRect(x: 0, y: 0, width: 1_600, height: 1_000)])
        #expect(anchor != nil)
        #expect(anchor!.midX == window.midX)
        #expect(anchor!.minY > window.minY)
        #expect(anchor!.maxY < window.minY + window.height * 0.3)
    }

    @Test func tinyWindowDoesNotProduceFallbackAnchor() {
        #expect(CaretLocator.windowFallbackRect(windowFrame: CGRect(x: 0, y: 0, width: 64, height: 64), screenFrames: [CGRect(x: 0, y: 0, width: 1_600, height: 1_000)]) == nil)
    }

    @Test func offScreenWindowDoesNotProduceFallbackAnchor() {
        #expect(CaretLocator.windowFallbackRect(windowFrame: CGRect(x: 2_000, y: 2_000, width: 800, height: 600), screenFrames: [CGRect(x: 0, y: 0, width: 1_600, height: 1_000)]) == nil)
    }
}
