import Foundation

/// Identity and release policy, independent of microphone/recognizer callbacks.
struct SpeechSession {
    private(set) var id: UUID?
    private(set) var listening = false
    private(set) var finishing = false
    mutating func begin() -> UUID {
        let next = UUID(); id = next; listening = false; finishing = false; return next
    }
    mutating func ready(_ token: UUID) -> Bool {
        guard id == token, !finishing else { return false }
        listening = true; return true
    }
    mutating func release() -> Bool {
        guard id != nil, listening, !finishing else { return false }
        listening = false; finishing = true; return true
    }
    mutating func cancel() { id = nil; listening = false; finishing = false }
}
