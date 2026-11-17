import ApplicationServices
import Testing
@testable import Mojito

struct SpeechFocusValidatorTests {
    @Test func matchesIdentityAndRejectsMissingOrDifferentFocus() async {
        let original = AXUIElementCreateApplication(123)
        let other = AXUIElementCreateApplication(456)
        for (actual, expected) in [(Optional(original), SpeechFocusValidator.Outcome.match),
                                   (Optional(other), .changed), (nil, .lookupFailed)] {
            let outcome = await withCheckedContinuation { continuation in
                SpeechFocusValidator.validate(expected: original, pid: 123, read: { actual }) {
                    continuation.resume(returning: $0)
                }
            }
            #expect(outcome == expected)
        }
    }
}
