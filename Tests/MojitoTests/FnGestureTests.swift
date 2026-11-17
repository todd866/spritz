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
}
