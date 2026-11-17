import AppKit
import AVFoundation
import Speech
import Combine

/// External mode leaves the physical Fn events to ChatGPT's own configured
/// global Dictate shortcut. Spritz neither automates that app nor handles audio.
enum SpeechInputProvider: String, CaseIterable, Identifiable {
    case apple = "Apple", chatgpt = "ChatGPT Dictate"
    var id: String { rawValue }
    static let preferenceKey = "speechInputProvider"
    static var current: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "Apple") ?? .apple
    }
}

/// Serializes audio graph changes away from the keyboard event tap.
private final class SpeechCapture {
    private let queue = DispatchQueue(label: "Spritz.speechCapture", qos: .userInitiated)
    private var engine: AVAudioEngine?
    func start(request: SFSpeechAudioBufferRecognitionRequest, completion: @escaping (Bool) -> Void) {
        queue.async {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { completion(false); return }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            do {
                engine.prepare(); try engine.start(); self.engine = engine; completion(true)
            } catch { input.removeTap(onBus: 0); completion(false) }
        }
    }
    func stop(completion: @escaping () -> Void = {}) {
        queue.async {
            if let engine = self.engine { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
            self.engine = nil
            completion()
        }
    }
}

@MainActor
final class SpeechController: ObservableObject {
    static let shared = SpeechController()
    @Published private(set) var status = ""
    private(set) var isActive = false
    private(set) var isListening = false
    var onTranscript: ((String) -> Void)?
    var targetIsValid: (() -> Bool)?
    private var focusWatch: Task<Void, Never>?
    private var requestingPermissions = false
    private let capture = SpeechCapture()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lifecycle = SpeechSession()
    private var session: UUID? { lifecycle.id }
    private var finishing = false
    private var startedAt = 0.0
    private var releasedAt = 0.0
    private var timeout: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private init() {
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        })
    }
    func start() {
        guard !isActive, !requestingPermissions else { return }
        status = "Preparing speech"
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        let speech = SFSpeechRecognizer.authorizationStatus()
        guard microphone == .authorized, speech == .authorized else {
            // Permission dialogs may steal focus; never record automatically after them.
            if microphone == .notDetermined {
                requestingPermissions = true
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    SFSpeechRecognizer.requestAuthorization { _ in
                        Task { @MainActor in self.requestingPermissions = false; self.status = "Hold Fn again after granting speech permissions" }
                    }
                }
            } else if speech == .notDetermined {
                requestingPermissions = true
                SFSpeechRecognizer.requestAuthorization { _ in
                    Task { @MainActor in self.requestingPermissions = false; self.status = "Hold Fn again after granting speech permissions" }
                }
            } else { status = "Enable Spritz microphone and speech access in System Settings" }
            LocalTelemetry.shared.record(.speechPermissionRequired)
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-AU")), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            status = "On-device English (Australia) speech unavailable"
            LocalTelemetry.shared.record(.speechUnavailable); return
        }
        let id = lifecycle.begin(); isActive = true; finishing = false
        startedAt = ProcessInfo.processInfo.systemUptime
        focusWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled, let self, self.session == id else { return }
                if self.targetIsValid?() != true { self.cancel(); self.rejectInsertion(); return }
            }
        }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.session == id else { return }
                if let result, result.isFinal {
                    guard self.finishing else { self.fail("Speech ended early; hold Fn to retry"); return }
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    let callback = self.onTranscript
                    let latency = (ProcessInfo.processInfo.systemUptime - self.releasedAt) * 1000
                    self.cleanUp()
                    self.status = text.isEmpty ? "No speech detected" : ""
                    LocalTelemetry.shared.record(.speechFinish, durationMilliseconds: latency)
                    if !text.isEmpty { callback?(text) }
                } else if error != nil { self.fail("Speech recognition failed; hold Fn to retry") }
            }
        }
        capture.start(request: request) { [weak self] success in
            Task { @MainActor in
                guard let self, self.session == id, !self.finishing else { return }
                if success && self.lifecycle.ready(id) {
                    self.isListening = true; self.status = "Listening — release Fn to insert"
                    LocalTelemetry.shared.record(.speechStart, durationMilliseconds: (ProcessInfo.processInfo.systemUptime - self.startedAt) * 1000)
                } else { self.fail("Microphone unavailable") }
            }
        }
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled, let self, self.session == id else { return }
            self.fail("Speech timed out; hold Fn to retry")
        }
    }
    func finish() {
        guard isActive, !finishing, let id = session else { return }
        guard lifecycle.release() else {
            cancel(); status = "Hold Fn until Listening appears, then speak"; return
        }
        finishing = true; isListening = false; status = "Finishing speech"
        releasedAt = ProcessInfo.processInfo.systemUptime
        let request = self.request
        capture.stop { request?.endAudio() }
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, self.session == id else { return }
            self.fail("No final speech result; hold Fn to retry")
        }
    }
    func cancel() {
        guard isActive else { return }
        cleanUp(); status = ""
        LocalTelemetry.shared.record(.speechCancel)
    }
    func rejectInsertion() { status = "Focus changed; speech was not inserted" }
    private func fail(_ message: String) {
        cleanUp(); status = message
        LocalTelemetry.shared.record(.speechFailure)
    }
    private func cleanUp() {
        lifecycle.cancel(); isActive = false; isListening = false; finishing = false
        timeout?.cancel(); timeout = nil
        focusWatch?.cancel(); focusWatch = nil; targetIsValid = nil
        capture.stop(); task?.cancel(); task = nil; request = nil; recognizer = nil; onTranscript = nil
    }
}
