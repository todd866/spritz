import UIKit
import XCTest
@testable import SpritzMobile

@MainActor
final class KeyboardVisualAndLayoutTests: XCTestCase {
    private func makeContainer(
        dark: Bool,
        width: CGFloat = 393,
        numberRow: Bool = true,
        layer: DeckLayer = .letters
    ) -> SpritzKeyboardContainerView {
        let bridge = SpritzIosBridge()
        let container = SpritzKeyboardContainerView(bridge: bridge, needsGlobe: true)
        container.updateAppearance(dark: dark)
        container.debugDeckView.setConfiguration(
            layerKind: layer,
            showNumberRow: numberRow,
            showFlicks: true,
            glideEnabled: true,
            hapticsEnabled: false,
            needsGlobe: true,
            shiftState: .off,
            returnKeyType: .default
        )
        let height = SpritzKeyboardContainerView.preferredHeight(numberRow: numberRow)
        container.frame = CGRect(x: 0, y: 0, width: width, height: height)
        container.setNeedsLayout()
        container.layoutIfNeeded()
        container.debugDeckView.setNeedsLayout()
        container.debugDeckView.layoutIfNeeded()
        container.debugInstrumentBar.setNeedsLayout()
        container.debugInstrumentBar.layoutIfNeeded()
        return container
    }

    private func renderRGBA(view: UIView) -> (data: [UInt8], width: Int, height: Int, scale: CGFloat) {
        let scale: CGFloat = 2.0
        let w = Int((view.bounds.width * scale).rounded())
        let h = Int((view.bounds.height * scale).rounded())
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: cs,
                bitmapInfo: bitmapInfo
            ) else {
                XCTFail("Failed to allocate RGBA CGContext")
                return
            }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: scale, y: -scale)
            view.layer.render(in: ctx)
        }
        return (bytes, w, h, scale)
    }

    private func luminance(
        at pointInView: CGPoint,
        rgba: (data: [UInt8], width: Int, height: Int, scale: CGFloat)
    ) -> Double {
        let px = min(max(0, Int((pointInView.x * rgba.scale).rounded())), rgba.width - 1)
        let py = min(max(0, Int((pointInView.y * rgba.scale).rounded())), rgba.height - 1)
        let idx = (py * rgba.width + px) * 4
        let r = Double(rgba.data[idx]) / 255.0
        let g = Double(rgba.data[idx + 1]) / 255.0
        let b = Double(rgba.data[idx + 2]) / 255.0
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    func testKeycapContrastInDarkAndLightModes() {
        for isDark in [true, false] {
            let container = makeContainer(dark: isDark, width: 393, numberRow: true, layer: .letters)
            let deck = container.debugDeckView
            let rgba = renderRGBA(view: container)

            guard let aFrame = deck.debugTileFrame(id: "a"),
                  let qFrame = deck.debugTileFrame(id: "q"),
                  let mFrame = deck.debugTileFrame(id: "m"),
                  let shiftFrame = deck.debugTileFrame(id: "shift") else {
                XCTFail("Expected q, a, m, and shift tiles on letters layer")
                return
            }

            // Sample inter-key gap for true deck background luminance.
            let deckSample = container.convert(CGPoint(x: aFrame.maxX + 2.5, y: aFrame.midY), from: deck)
            let deckLuma = luminance(at: deckSample, rgba: rgba)

            // Sample upper-left interior corners of keycaps to avoid center glyph strokes and top-right flick hints.
            let letterSamples = [qFrame, aFrame, mFrame].map { frame in
                container.convert(CGPoint(x: frame.minX + 5, y: frame.minY + 7), from: deck)
            }
            let letterLumas = letterSamples.map { luminance(at: $0, rgba: rgba) }
            let minLetterLuma = letterLumas.min() ?? 0

            let utilSample = container.convert(CGPoint(x: shiftFrame.minX + 6, y: shiftFrame.minY + 7), from: deck)
            let utilLuma = luminance(at: utilSample, rgba: rgba)

            if isDark {
                XCTAssertGreaterThan(
                    minLetterLuma, utilLuma,
                    "Dark mode letter keycaps (\(minLetterLuma)) must be brighter than utility keycaps (\(utilLuma))"
                )
                XCTAssertGreaterThan(
                    utilLuma, deckLuma,
                    "Dark mode utility keycaps (\(utilLuma)) must be brighter than deck background (\(deckLuma))"
                )
                XCTAssertGreaterThanOrEqual(
                    minLetterLuma - deckLuma, 0.10,
                    "Dark mode keycap contrast delta too low: letter=\(minLetterLuma), deck=\(deckLuma)"
                )
            } else {
                XCTAssertGreaterThanOrEqual(
                    minLetterLuma, 0.94,
                    "Light mode letter keycaps should remain crisp white (\(minLetterLuma))"
                )
                XCTAssertGreaterThanOrEqual(
                    minLetterLuma - deckLuma, 0.05,
                    "Light mode keycap contrast delta too low: letter=\(minLetterLuma), deck=\(deckLuma)"
                )
            }
        }
    }

    func testAllLayersLayoutWithoutOverlapAcrossPhoneWidths() {
        let widths: [CGFloat] = [375, 393, 430]
        let layers: [DeckLayer] = [.letters, .numbers, .symbols]

        for width in widths {
            for showNumbers in [true, false] {
                for layer in layers {
                    let container = makeContainer(dark: true, width: width, numberRow: showNumbers, layer: layer)
                    let deck = container.debugDeckView
                    let tiles = deck.debugTiles
                    XCTAssertFalse(tiles.isEmpty, "Tiles missing for width=\(width) numbers=\(showNumbers) layer=\(layer)")

                    for tile in tiles {
                        XCTAssertTrue(
                            deck.bounds.contains(tile.frame),
                            "Tile '\(tile.id)' escaped deck bounds \(deck.bounds): \(tile.frame)"
                        )
                        XCTAssertGreaterThanOrEqual(tile.frame.width, 24, "Tile '\(tile.id)' too narrow at width \(width)")
                        XCTAssertGreaterThanOrEqual(tile.frame.height, 28, "Tile '\(tile.id)' too short")
                    }

                    for i in 0..<tiles.count {
                        for j in (i + 1)..<tiles.count {
                            XCTAssertFalse(
                                tiles[i].frame.intersects(tiles[j].frame),
                                "Tiles '\(tiles[i].id)' and '\(tiles[j].id)' overlap at width=\(width) layer=\(layer)"
                            )
                        }
                    }
                }
            }
        }
    }

    func testInputViewControllerSelfSizingAndPriority999() {
        let iv = UIInputView(frame: .zero, inputViewStyle: .keyboard)
        iv.allowsSelfSizing = true
        XCTAssertTrue(iv.allowsSelfSizing)

        let bridge = SpritzIosBridge()
        let container = SpritzKeyboardContainerView(bridge: bridge, needsGlobe: true)
        XCTAssertEqual(container.debugHeightConstraintPriority.rawValue, 999, accuracy: 0.1)

        // Verify a host view can freely apply an encapsulated height without layout ambiguity.
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 300))
        host.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            container.topAnchor.constraint(equalTo: host.topAnchor),
            container.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutIfNeeded()
        XCTAssertEqual(container.bounds.height, container.totalHeight, accuracy: 0.5)
        XCTAssertFalse(host.hasAmbiguousLayout)

        let compressed = host.heightAnchor.constraint(equalToConstant: 216)
        compressed.priority = .required
        compressed.isActive = true
        host.setNeedsLayout()
        host.layoutIfNeeded()
        XCTAssertEqual(container.bounds.height, 216, accuracy: 0.5)
        XCTAssertFalse(host.hasAmbiguousLayout)
    }

    func testTopRowPopupFloatsAboveKeyAndIsUnclipped() {
        for showNumberRow in [true, false] {
            let container = makeContainer(dark: true, width: 393, numberRow: showNumberRow, layer: .letters)
            let deck = container.debugDeckView
            XCTAssertFalse(deck.clipsToBounds)
            XCTAssertFalse(container.clipsToBounds)

            let targetID = showNumberRow ? "1" : "q"
            guard let keyFrame = deck.debugTileFrame(id: targetID) else {
                XCTFail("Missing top row key '\(targetID)'")
                return
            }
            let pt = CGPoint(x: keyFrame.midX, y: keyFrame.midY)
            deck.handleTouchDown(id: 1, at: pt, timestamp: 1.0)
            guard let popupFrame = deck.debugPopupFrame else {
                XCTFail("Popup did not appear for '\(targetID)'")
                return
            }
            XCTAssertLessThan(
                popupFrame.minY, keyFrame.minY,
                "Top row popup \(popupFrame) must rise above key \(keyFrame) over the bar instead of sitting on top of the thumb"
            )
            XCTAssertLessThan(popupFrame.minY, 0, "Top-row popup should float smoothly above deck top into InstrumentBar area")
            deck.handleTouchUp(id: 1, at: pt, timestamp: 1.04)
        }
    }

    func testInstrumentBarHasDividersAndNoDuplicateEmojiButton() {
        let container = makeContainer(dark: true, width: 393, numberRow: true, layer: .letters)
        let bar = container.debugInstrumentBar
        XCTAssertFalse(bar.debugHasDuplicateEmojiButton, "InstrumentBar must not duplicate the deck emoji button")

        let frames = bar.debugCandidateFrames
        XCTAssertEqual(frames.count, 3)
        XCTAssertGreaterThan(frames[0].width, 40)
        XCTAssertLessThan(abs(frames[1].width - frames[0].width), 1.5)
        XCTAssertLessThan(abs(frames[2].width - frames[0].width), 1.5)
        XCTAssertEqual(bar.debugVisibleDividerCount, 2)
    }
}
