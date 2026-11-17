import Testing
@testable import Mojito

struct SpeechSessionTests {
    @Test func cancelDuringPreparationRejectsLateReady() {
        var s = SpeechSession(); let id = s.begin(); s.cancel()
        #expect(s.ready(id) == false); #expect(s.release() == false); #expect(s.id == nil)
    }
    @Test func releaseBeforeReadyDoesNotFinalizeEmptyAudio() {
        var s = SpeechSession(); let id = s.begin()
        #expect(s.release() == false); s.cancel(); #expect(s.ready(id) == false)
    }
    @Test func restartInvalidatesOldCallbackAndFinishing() {
        var s = SpeechSession(); let old = s.begin()
        #expect(s.ready(old) == true); #expect(s.release() == true); #expect(s.finishing)
        s.cancel(); let next = s.begin()
        #expect(next != old); #expect(s.ready(old) == false); #expect(s.ready(next) == true)
        #expect(s.release() == true); #expect(s.release() == false); #expect(s.ready(next) == false)
    }
}
