import Foundation

struct FnGesture {
    enum Action: Equatable { case tap, start, finish, cancel }
    enum State: Equatable { case idle, pending(Double), holding, interrupted }
    private(set) var state: State = .idle
    static let delay = 0.3
    mutating func press(at time: Double, modified: Bool) {
        guard state == .idle else { return }
        state = modified ? .interrupted : .pending(time)
    }
    mutating func advance(at time: Double) -> Action? {
        guard case .pending(let down) = state else { return nil }
        guard time >= down else { return interrupt() }
        guard time - down >= Self.delay else { return nil }
        state = .holding
        return .start
    }
    mutating func release(at time: Double) -> Action? {
        defer { state = .idle }
        switch state {
        case .pending(let down): return time >= down && time - down < Self.delay ? .tap : .cancel
        case .holding: return .finish
        default: return nil
        }
    }
    mutating func interrupt() -> Action? {
        switch state {
        case .pending, .holding: state = .interrupted; return .cancel
        default: return nil
        }
    }
    mutating func reset() -> Action? {
        defer { state = .idle }
        return interrupt()
    }
}
