/// Compatibility shell for the upstream consent call sites. The fork neither
/// collects usage stats nor presents a consent prompt.
@MainActor
enum TelemetryConsent {
    static var hasBeenSeen: Bool { true }
    static func presentIfNeeded() {}
}
