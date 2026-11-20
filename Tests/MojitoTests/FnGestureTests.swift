import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import Mojito

struct FnGestureTests {
    @Test func tapAndHoldAreExclusive() {
        var g = FnGesture()
        g.press(at: 10, modified: false)
        #expect(g.release(at: 10.2) == .tap)
        g.press(at: 11, modified: false)
        #expect(g.advance(at: 11.4) == .start)
        #expect(g.advance(at: 12) == nil)
        #expect(g.release(at: 12) == .finish)
        #expect(g.release(at: 12) == nil)
    }
    @Test func lateTimerCannotStartAfterRelease() {
        var g = FnGesture(); g.press(at: 0, modified: false)
        #expect(g.release(at: 0.3) == .cancel)
        #expect(g.advance(at: 0.4) == nil)
    }
    @Test func chordAndPreheldModifiersNeverTap() {
        var g = FnGesture(); g.press(at: 0, modified: true)
        #expect(g.advance(at: 1) == nil); #expect(g.release(at: 1) == nil)
        g.press(at: 2, modified: false)
        #expect(g.interrupt() == .cancel); #expect(g.release(at: 2.1) == nil)
        g.press(at: 3, modified: false); #expect(g.advance(at: 4) == .start)
        #expect(g.interrupt() == .cancel); #expect(g.release(at: 4.1) == nil)
    }
    @Test func duplicatePressAndLostTap() {
        var g = FnGesture(); g.press(at: 0, modified: false); g.press(at: 0.2, modified: false)
        #expect(g.advance(at: 0.31) == .start)
        #expect(g.reset() == .cancel); #expect(g.release(at: 1) == nil)
        g.press(at: 2, modified: false); #expect(g.release(at: 1) == .cancel)
    }

    @Test func keyMonitorTranslatesBrowserShortcutsAndControls() throws {
        func makeKey(_ code: Int, unicode: String? = nil, flags: CGEventFlags = []) throws -> CGEvent {
            let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true))
            event.flags = flags
            if let unicode {
                let utf16 = Array(unicode.utf16)
                utf16.withUnsafeBufferPointer { buf in
                    event.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                }
            }
            return event
        }

        let one = try makeKey(kVK_ANSI_1, unicode: "1")
        if case .nameChar("1") = KeyMonitor.translate(event: one) {} else { Issue.record("Expected .nameChar(1)") }

        let zero = try makeKey(kVK_ANSI_0, unicode: "0")
        if case .nameChar("0") = KeyMonitor.translate(event: zero) {} else { Issue.record("Expected .nameChar(0)") }

        let esc = try makeKey(kVK_Escape)
        if case .escape = KeyMonitor.translate(event: esc) {} else { Issue.record("Expected .escape") }

        let shiftRet = try makeKey(kVK_Return, flags: .maskShift)
        if case .returnKey(shift: true) = KeyMonitor.translate(event: shiftRet) {} else { Issue.record("Expected shift return") }

        let cmdOne = try makeKey(kVK_ANSI_1, unicode: "1", flags: .maskCommand)
        #expect(KeyMonitor.translate(event: cmdOne) == nil)

        let cmdZ = try makeKey(kVK_ANSI_Z, unicode: "z", flags: .maskCommand)
        if case .cmdZ = KeyMonitor.translate(event: cmdZ) {} else { Issue.record("Expected .cmdZ") }
    }
}
