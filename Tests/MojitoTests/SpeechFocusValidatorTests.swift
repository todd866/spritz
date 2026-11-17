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
    @Test func capturesFreshLeafAndRejectsContainersOrSecureFields() async {
        let cachedContainer = AXUIElementCreateApplication(123)
        let freshLeaf = AXUIElementCreateApplication(456)
        for (role, secure, accepted) in [("AXTextArea", false, true), ("AXWindow", false, false), ("AXTextField", true, false)] {
            let captured: AXUIElement? = await withCheckedContinuation { continuation in
                SpeechFocusValidator.capture(pid: 456, read: { freshLeaf }, classify: { _ in (secure, true, role) }) {
                    continuation.resume(returning: $0)
                }
            }
            #expect((captured != nil) == accepted)
            if let captured {
                #expect(CFEqual(captured, freshLeaf))
                #expect(!CFEqual(captured, cachedContainer))
                let outcome = await withCheckedContinuation { continuation in
                    SpeechFocusValidator.validate(expected: captured, pid: 456, read: { freshLeaf }) { continuation.resume(returning: $0) }
                }
                #expect(outcome == .match)
            }
        }
    }
}
