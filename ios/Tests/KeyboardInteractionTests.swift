import UIKit
import XCTest
@testable import SpritzMobile

@MainActor
final class KeyboardInteractionTests: XCTestCase {
    private func makeDeck(
        layer: DeckLayer = .letters,
        showNumberRow: Bool = false,
        showFlicks: Bool = true,
        glideEnabled: Bool = true
    ) -> KeyboardDeckView {
        let deck = KeyboardDeckView(frame: CGRect(x: 0, y: 0, width: 393, height: showNumberRow ? 258 : 222))
        deck.setConfiguration(
            layerKind: layer,
            showNumberRow: showNumberRow,
            showFlicks: showFlicks,
            glideEnabled: glideEnabled,
            hapticsEnabled: false,
            needsGlobe: true,
            shiftState: .off,
            returnKeyType: .default
        )
        deck.setNeedsLayout()
        deck.layoutIfNeeded()
        return deck
    }

    func testZeroDeadZonesAcrossEntireDeckAndMiddleRowGutters() {
        let deck = makeDeck(layer: .letters, showNumberRow: true)
        var y: CGFloat = 8
        while y <= deck.bounds.height - 8 {
            var x: CGFloat = 6
            while x <= deck.bounds.width - 6 {
                let hit = deck.debugHitTileID(at: CGPoint(x: x, y: y), applyBias: true)
                XCTAssertNotNil(hit, "Dead zone detected at (\(x), \(y))")
                x += 6
            }
            y += 6
        }

        guard let aFrame = deck.debugTileFrame(id: "a"),
              let lFrame = deck.debugTileFrame(id: "l") else {
            XCTFail("Missing a or l keys")
            return
        }
        XCTAssertEqual(deck.debugHitTileID(at: CGPoint(x: 2, y: aFrame.midY)), "a")
        XCTAssertEqual(deck.debugHitTileID(at: CGPoint(x: deck.bounds.width - 2, y: lFrame.midY)), "l")
    }

    func testLikelyNextCharsBiasOnlyInGapsNeverStealsInsideKey() {
        let deck = makeDeck(layer: .letters, showNumberRow: false)
        guard let wFrame = deck.debugTileFrame(id: "w"),
              let eFrame = deck.debugTileFrame(id: "e") else {
            XCTFail("Missing w or e tiles")
            return
        }
        deck.setLikelyNextChars("e")

        // Midpoint in the horizontal gap between 'w' and 'e' must favor likely next letter 'e'.
        let gapMid = CGPoint(x: (wFrame.maxX + eFrame.minX) * 0.5, y: wFrame.midY)
        XCTAssertEqual(deck.debugHitTileID(at: gapMid, applyBias: true), "e")

        // A tap strictly inside 'w' (even right near its edge) must still resolve to 'w'.
        let insideWRightEdge = CGPoint(x: wFrame.maxX - 0.5, y: wFrame.midY)
        XCTAssertEqual(deck.debugHitTileID(at: insideWRightEdge, applyBias: true), "w")
    }

    func testRealTouchCoordinatePassedNotTileCenter() {
        let deck = makeDeck(layer: .letters, showNumberRow: false)
        guard let wFrame = deck.debugTileFrame(id: "w") else {
            XCTFail("Missing w tile")
            return
        }

        var capturedNorms: [CGPoint] = []
        deck.onTapCharacter = { _, norm in
            capturedNorms.append(norm)
        }

        let leftPt = CGPoint(x: wFrame.minX + 4, y: wFrame.midY)
        let rightPt = CGPoint(x: wFrame.maxX - 4, y: wFrame.midY)

        deck.handleTouchDown(id: 1, at: leftPt, timestamp: 1.0)
        deck.handleTouchUp(id: 1, at: leftPt, timestamp: 1.04)

        deck.handleTouchDown(id: 2, at: rightPt, timestamp: 1.2)
        deck.handleTouchUp(id: 2, at: rightPt, timestamp: 1.24)

        XCTAssertEqual(capturedNorms.count, 2)
        XCTAssertGreaterThan(capturedNorms[1].x - capturedNorms[0].x, 0.04)
    }

    func testFastSpaceTapWithSmallDriftInsertsSpaceNotTrackpad() {
        let deck = makeDeck(layer: .letters, showNumberRow: false)
        guard let spaceFrame = deck.debugTileFrame(id: "space") else {
            XCTFail("Missing space tile")
            return
        }

        var spaceCount = 0
        var trackpadCount = 0
        deck.onSpace = { spaceCount += 1 }
        deck.onTrackpadMove = { _ in trackpadCount += 1 }

        let start = CGPoint(x: spaceFrame.midX, y: spaceFrame.midY)
        let drifted = CGPoint(x: spaceFrame.midX + 14, y: spaceFrame.midY)

        deck.handleTouchDown(id: 10, at: start, timestamp: 2.0)
        deck.handleTouchMove(id: 10, to: drifted, timestamp: 2.04)
        XCTAssertFalse(deck.debugIsTrackpadActive)
        deck.handleTouchUp(id: 10, at: drifted, timestamp: 2.05)

        XCTAssertEqual(spaceCount, 1)
        XCTAssertEqual(trackpadCount, 0)
    }

    func testDeliberateSpaceDragActivatesTrackpadAndDimsKeys() {
        let deck = makeDeck(layer: .letters, showNumberRow: false)
        guard let spaceFrame = deck.debugTileFrame(id: "space") else {
            XCTFail("Missing space tile")
            return
        }

        var spaceCount = 0
        var trackpadOffsets: [Int] = []
        deck.onSpace = { spaceCount += 1 }
        deck.onTrackpadMove = { trackpadOffsets.append($0) }

        let start = CGPoint(x: spaceFrame.midX, y: spaceFrame.midY)
        let engage = CGPoint(x: spaceFrame.midX + 28, y: spaceFrame.midY)
        let glideFurther = CGPoint(x: spaceFrame.midX + 52, y: spaceFrame.midY)

        deck.handleTouchDown(id: 11, at: start, timestamp: 3.0)
        deck.handleTouchMove(id: 11, to: engage, timestamp: 3.12)
        XCTAssertTrue(deck.debugIsTrackpadActive)
        XCTAssertLessThan(deck.debugNonSpaceAlpha, 0.5)

        deck.handleTouchMove(id: 11, to: glideFurther, timestamp: 3.20)
        XCTAssertGreaterThan(trackpadOffsets.reduce(0, +), 0)

        deck.handleTouchUp(id: 11, at: glideFurther, timestamp: 3.28)
        XCTAssertFalse(deck.debugIsTrackpadActive)
        XCTAssertEqual(deck.debugNonSpaceAlpha, 1.0, accuracy: 0.01)
        XCTAssertEqual(spaceCount, 0)
    }

    func testSloppyDownwardTapTypesLetterWhileDeliberateFlickInsertsSymbol() {
        let deck = makeDeck(layer: .letters, showNumberRow: false, showFlicks: true)
        guard let eFrame = deck.debugTileFrame(id: "e") else {
            XCTFail("Missing e tile")
            return
        }

        var tappedChars: [String] = []
        var directInserts: [String] = []
        deck.onTapCharacter = { ch, _ in tappedChars.append(ch) }
        deck.onDirectInsert = { directInserts.append($0) }

        let start = CGPoint(x: eFrame.midX, y: eFrame.midY)
        // Mild downward wobble (19 pt) must type letter 'e', NOT '#'.
        let mildSlip = CGPoint(x: start.x + 1, y: start.y + 19)
        deck.handleTouchDown(id: 20, at: start, timestamp: 4.0)
        deck.handleTouchMove(id: 20, to: mildSlip, timestamp: 4.05)
        deck.handleTouchUp(id: 20, at: mildSlip, timestamp: 4.08)

        // Deliberate downward flick (34 pt) on 'e' must emit '#'.
        let flickEnd = CGPoint(x: start.x + 2, y: start.y + 34)
        deck.handleTouchDown(id: 21, at: start, timestamp: 4.3)
        deck.handleTouchMove(id: 21, to: flickEnd, timestamp: 4.39)
        deck.handleTouchUp(id: 21, at: flickEnd, timestamp: 4.42)

        XCTAssertEqual(tappedChars, ["e"])
        XCTAssertEqual(directInserts, ["#"])
    }

    func testFastBrushDoesNotGlideWhileDeliberateSwipeDoes() {
        let deck = makeDeck(layer: .letters, showNumberRow: false, glideEnabled: true)
        guard let eFrame = deck.debugTileFrame(id: "e"),
              let rFrame = deck.debugTileFrame(id: "r"),
              let hFrame = deck.debugTileFrame(id: "h"),
              let lFrame = deck.debugTileFrame(id: "l"),
              let oFrame = deck.debugTileFrame(id: "o") else {
            XCTFail("Missing letter tiles")
            return
        }

        var taps: [String] = []
        var glides = 0
        deck.onTapCharacter = { ch, _ in taps.append(ch) }
        deck.onGlideComplete = { pts in
            XCTAssertGreaterThanOrEqual(pts.count, 2)
            glides += 1
        }

        // Fast 30ms brush from e -> r edge must remain a tap, not glide.
        let ePt = CGPoint(x: eFrame.midX, y: eFrame.midY)
        let rPt = CGPoint(x: rFrame.midX, y: rFrame.midY)
        deck.handleTouchDown(id: 30, at: ePt, timestamp: 5.0)
        deck.handleTouchMove(id: 30, to: rPt, timestamp: 5.025)
        deck.handleTouchUp(id: 30, at: rPt, timestamp: 5.03)
        XCTAssertEqual(taps, ["e"])
        XCTAssertEqual(glides, 0)

        // Deliberate multi-letter swipe h -> e -> l -> o over 200ms must trigger glide.
        let path = [hFrame, eFrame, lFrame, oFrame].map { CGPoint(x: $0.midX, y: $0.midY) }
        deck.handleTouchDown(id: 31, at: path[0], timestamp: 5.50)
        deck.handleTouchMove(id: 31, to: path[1], timestamp: 5.56)
        deck.handleTouchMove(id: 31, to: path[2], timestamp: 5.63)
        deck.handleTouchMove(id: 31, to: path[3], timestamp: 5.70)
        deck.handleTouchUp(id: 31, at: path[3], timestamp: 5.72)

        XCTAssertEqual(glides, 1)
        XCTAssertEqual(taps, ["e"])
    }

    func testShiftHoldChordingAndDoubleTapCapsLock() {
        let deck = makeDeck(layer: .letters, showNumberRow: false)
        guard let shiftFrame = deck.debugTileFrame(id: "shift"),
              let aFrame = deck.debugTileFrame(id: "a"),
              let bFrame = deck.debugTileFrame(id: "b"),
              let cFrame = deck.debugTileFrame(id: "c") else {
            XCTFail("Missing shift/a/b/c tiles")
            return
        }

        var emitted: [String] = []
        deck.onTapCharacter = { ch, _ in emitted.append(ch) }

        let shPt = CGPoint(x: shiftFrame.midX, y: shiftFrame.midY)
        // Left thumb holds Shift while right thumb taps a, b, c.
        deck.handleTouchDown(id: 40, at: shPt, timestamp: 6.0)
        for (i, frame) in [aFrame, bFrame, cFrame].enumerated() {
            let pt = CGPoint(x: frame.midX, y: frame.midY)
            let tid = UInt(41 + i)
            let t0 = 6.05 + Double(i) * 0.08
            deck.handleTouchDown(id: tid, at: pt, timestamp: t0)
            deck.handleTouchUp(id: tid, at: pt, timestamp: t0 + 0.03)
        }
        deck.handleTouchUp(id: 40, at: shPt, timestamp: 6.32)

        XCTAssertEqual(emitted, ["A", "B", "C"])
        XCTAssertEqual(deck.debugShiftState, .off)

        // Double tap shift within 0.32s engages CapsLock.
        deck.handleTouchDown(id: 50, at: shPt, timestamp: 10.0)
        deck.handleTouchUp(id: 50, at: shPt, timestamp: 10.02)
        deck.handleTouchDown(id: 51, at: shPt, timestamp: 10.12)
        deck.handleTouchUp(id: 51, at: shPt, timestamp: 10.14)
        XCTAssertEqual(deck.debugShiftState, .capsLock)
    }

    func testSpaceOnNumbersLayerAutoReturnsToLetters() {
        let deck = makeDeck(layer: .letters, showNumberRow: false)
        guard let numLayerFrame = deck.debugTileFrame(id: "layer:123") else {
            XCTFail("Missing 123 layer switch key")
            return
        }

        var layersSeen: [DeckLayer] = []
        var inserts: [String] = []
        deck.onLayerChanged = { layersSeen.append($0) }
        deck.onDirectInsert = { inserts.append($0) }

        let lPt = CGPoint(x: numLayerFrame.midX, y: numLayerFrame.midY)
        deck.handleTouchDown(id: 60, at: lPt, timestamp: 7.0)
        deck.handleTouchUp(id: 60, at: lPt, timestamp: 7.03)
        deck.layoutIfNeeded()
        XCTAssertEqual(deck.layerKind, .numbers)

        guard let fiveFrame = deck.debugTileFrame(id: "5"),
              let spaceFrame = deck.debugTileFrame(id: "space") else {
            XCTFail("Missing 5 or space key on numbers layer")
            return
        }
        let fivePt = CGPoint(x: fiveFrame.midX, y: fiveFrame.midY)
        deck.handleTouchDown(id: 61, at: fivePt, timestamp: 7.1)
        deck.handleTouchUp(id: 61, at: fivePt, timestamp: 7.13)

        let spPt = CGPoint(x: spaceFrame.midX, y: spaceFrame.midY)
        deck.handleTouchDown(id: 62, at: spPt, timestamp: 7.2)
        deck.handleTouchUp(id: 62, at: spPt, timestamp: 7.23)

        XCTAssertEqual(inserts, ["5"])
        XCTAssertEqual(deck.layerKind, .letters)
        XCTAssertEqual(layersSeen, [.numbers, .letters])
    }

    func testBackspaceSwipeDeletesMultipleWords() {
        let deck = makeDeck(layer: .letters, showNumberRow: false)
        guard let bkFrame = deck.debugTileFrame(id: "backspace") else {
            XCTFail("Missing backspace tile")
            return
        }

        var singleDeletes = 0
        var wordDeletes = 0
        deck.onBackspace = { singleDeletes += 1 }
        deck.onSwipeDeleteWord = { wordDeletes += 1 }

        let p0 = CGPoint(x: bkFrame.midX, y: bkFrame.midY)
        let p1 = CGPoint(x: p0.x - 34, y: p0.y)
        let p2 = CGPoint(x: p1.x - 48, y: p0.y)

        deck.handleTouchDown(id: 70, at: p0, timestamp: 8.0)
        deck.handleTouchMove(id: 70, to: p1, timestamp: 8.08)
        deck.handleTouchMove(id: 70, to: p2, timestamp: 8.16)
        deck.handleTouchUp(id: 70, at: p2, timestamp: 8.20)

        XCTAssertEqual(wordDeletes, 2)
        XCTAssertEqual(singleDeletes, 0)
    }
}
