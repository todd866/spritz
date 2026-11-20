import AppKit
import Combine
import SwiftUI

@MainActor
final class DictationAlternatives: ObservableObject {
    static let shared = DictationAlternatives()
    @Published var embedded = false
    @Published var choices: [String] = []
    @Published var labels: [String] = ["Original", "Corrected", "Clearer"]
    @Published var reviewNotes = ""
    private var appleTranscript: String?
    private var sourceChoices: [String] = []
    private var sourceLabels: [String] = []
    private var sourceText = ""
    private var nativeSource = false
    @Published var selected = 0
    @Published var textPreviewActive = false
    @Published var status = ""
    @Published var busy = false
    @Published var copyOnly = false
    @Published var provider: RefinementProvider {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: "speechRefinementProvider")
            runner.cancel(); busy = false
            if provider != .off, !choices.isEmpty { refine() }
        }
    }
    var onEmoji: (() -> Void)?
    private let runner = RefinementRunner()
    private var panel: NSPanel?
    private var element: AXUIElement?
    private var pid: pid_t?
    private var focusGeneration = 0
    private var receipt: DictationReceipt?
    private var currentText = ""
    private var session = UUID()
    private var revision = 0
    private var applying = false
    private var appliedIndex = 0
    private var expiry: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var clickMonitor: Any?
    private(set) var visible = false

    init(preview: Bool = false) {
        provider = preview ? .codex : RefinementProvider(rawValue: UserDefaults.standard.string(forKey: "speechRefinementProvider") ?? "Codex") ?? .codex
        guard !preview else { return }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.clear() }
            })
        }
    }
    func clear() {
        let preserveEmbedded = embedded
        if busy { LocalTelemetry.shared.record(.refinementCancel) }
        session = UUID(); revision &+= 1; runner.cancel(); expiry?.cancel(); expiry = nil
        applying = false; textPreviewActive = false
        hide(); embedded = preserveEmbedded; visible = preserveEmbedded; appleTranscript = nil; choices = []; sourceChoices = []; sourceLabels = []; sourceText = ""; reviewNotes = ""; receipt = nil; element = nil; pid = nil; currentText = ""; busy = false; status = ""
    }
    func prepareNative() { clear(); appleTranscript = nil; status = "Waiting for dictation" }
    func receiveApple(_ text: String) { NativeDictationCapture.shared.receiveApple(text) }
    func begin(text: String, element: AXUIElement?, pid: pid_t?, native: Bool = false, apple: String? = nil) {
        let wasEmbedded = embedded
        clear()
        embedded = wasEmbedded; visible = wasEmbedded
        appleTranscript = apple
        focusGeneration = FocusedElementCache.shared.bridgeFocusGeneration
        self.element = element; self.pid = pid; currentText = text; sourceText = text; nativeSource = native
        sourceChoices = native ? (appleTranscript.map { [$0, text] } ?? [text]) : [text]
        sourceLabels = native ? (appleTranscript == nil ? ["GPT"] : ["Apple", "GPT"]) : ["Apple"]
        choices = sourceChoices; labels = sourceLabels
        selected = sourceChoices.count - 1; appliedIndex = selected
        copyOnly = (element == nil || pid == nil)
        if copyOnly { status = "Copy to use" } else { captureReceipt() }
        refine()
        let id = session
        expiry = Task { @MainActor in
            try? await Task.sleep(for: .seconds(120))
            if !Task.isCancelled, self.session == id { self.clear() }
        }
    }
    func analyseFocusedText() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let id = session
        SpeechFocusValidator.capture(pid: pid) { [weak self] element in
            MainActor.assumeIsolated {
                guard let self, self.session == id, let element else { return }
                DictationFieldReader.read(element: element, pid: pid) { [weak self] value, range in
                    MainActor.assumeIsolated {
                        guard let self, self.session == id, self.embedded, let value, !value.isEmpty, value.utf8.count <= 24_000 else { return }
                        self.begin(text: value, element: element, pid: pid, native: SpeechInputProvider.current != .apple)
                    }
                }
            }
        }
    }

    func refine() {
        guard !sourceText.isEmpty, provider != .off else { return }
        let original = sourceText
        choices = sourceChoices; labels = sourceLabels
        selected = min(appliedIndex, max(0, choices.count - 1)); busy = true; status = ""; reviewNotes = ""
        let id = session, started = Date()
        LocalTelemetry.shared.record(.refinementStart)
        runner.run(original, provider: provider, reference: nativeSource ? appleTranscript : nil) { [weak self] result in
            guard let self, self.session == id else { return }
            self.busy = false
            if let result {
                // Keep the labels stable, including when a model considers the original already good.
                self.choices = self.sourceChoices + (self.nativeSource ? [result.cleaned] : [result.cleaned, result.clearer])
                self.labels = self.sourceLabels + (self.nativeSource ? ["Reviewed"] : ["Corrected", "Clearer"])
                self.reviewNotes = result.notes ?? ""
                LocalTelemetry.shared.record(.refinementReady, durationMilliseconds: Date().timeIntervalSince(started) * 1000)
            } else {
                self.status = "Unavailable"; LocalTelemetry.shared.record(.refinementFailure)
            }
        }
    }
    private func targetMatches() -> Bool {
        let cache = FocusedElementCache.shared
        guard element != nil, let pid, cache.haveFieldInfo, cache.focusedIsEditable, !cache.focusedIsSecure,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              cache.bridgeFocusGeneration == focusGeneration else { return false }
        return true
    }
    private func captureReceipt() {
        let id = session, version = revision
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.session == id, self.revision == version, self.targetMatches(), let element = self.element, let pid = self.pid else { return }
            DictationFieldReader.read(element: element, pid: pid) { [weak self] value, range in
                MainActor.assumeIsolated {
                    guard let self, self.session == id, self.revision == version, self.targetMatches() else { return }
                    self.receipt = value.flatMap { value in range.flatMap { DictationReceipt.capture(value: value, selection: $0, text: self.currentText) } }
                    self.copyOnly = self.receipt == nil
                }
            }
        }
    }
    func toggle(emoji: @escaping () -> Void) -> Bool {
        guard !choices.isEmpty, targetMatches() else { clear(); return false }
        onEmoji = { [weak self] in self?.hide(); emoji() }
        if visible { hide(); return true }
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = true; panel.level = .popUpMenu; panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true; panel.hasShadow = true
            panel.isOpaque = false; panel.backgroundColor = .clear
            panel.collectionBehavior = [.fullScreenAuxiliary, .transient]
            panel.contentView = NSHostingView(rootView: DictationAlternativesView(model: self))
            self.panel = panel
        }
        guard let panel else { return false }
        panel.appearance = NSApp.effectiveAppearance
        let anchor = PanelPositioner.mouseAnchor()
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        let size = NSSize(width: min(520, (screen?.visibleFrame.width ?? 528) - 8), height: min(420, (screen?.visibleFrame.height ?? 428) - 8))
        panel.setFrame(PanelPositioner.frame(anchor: anchor, size: size, probe: .anchorCenter, clampMinY: true), display: true)
        panel.orderFrontRegardless(); visible = true
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.revision &+= 1; self?.hide() }
        }
        return true
    }
    static func nextIndex(current: Int, count: Int, backward: Bool) -> Int? {
        guard count > 1 else { return nil }
        return (current + (backward ? count - 1 : 1)) % count
    }
    func cycle(backward: Bool, emoji: @escaping () -> Void) -> Bool {
        guard !choices.isEmpty, targetMatches() else { return false }
        LocalTelemetry.shared.record(.refinementCycle)
        if !visible { _ = toggle(emoji: emoji) }
        guard !busy, !applying, let next = Self.nextIndex(current: appliedIndex, count: choices.count, backward: backward) else { return true }
        selected = next
        // A chord must never silently copy, or invalidate a receipt that is
        // still being captured just after the previous replacement.
        guard !copyOnly else { status = "Text changed · copy to use"; return true }
        guard receipt != nil else { return true }
        choose(next)
        return true
    }

    func hide() {
        embedded = false
        panel?.orderOut(nil); visible = false
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }; clickMonitor = nil
    }
    func showEmbedded() { embedded = true; visible = true; textPreviewActive = false }
    func handle(_ input: TriggerInput) -> Bool {
        if embedded {
            if case .tabKey(let backward) = input {
                guard !applying else { return true }
                if let next = Self.nextIndex(current: selected, count: choices.count, backward: backward) {
                    selected = next
                    textPreviewActive = true
                }
                return true
            }
            if case .returnKey = input, textPreviewActive, !choices.isEmpty {
                choose(selected, keepOpen: true); return true
            }
            // Typing or navigating emojis returns Enter to the emoji browser.
            textPreviewActive = false
            return false
        }
        if case .focusChange = input { clear(); return false }
        if visible {
            switch input {
            case .escape: hide(); return true
            case .arrowDown: selected = min(selected + 1, choices.count - 1); return true
            case .arrowUp: selected = max(selected - 1, 0); return true
            case .returnKey: choose(selected); return true
            case .nameChar(let c) where ["1", "2", "3"].contains(c):
                if let number = Int(String(c)), number <= choices.count { choose(number - 1) }; return true
            default: break
            }
        }
        revision &+= 1; receipt = nil; copyOnly = true; hide()
        return false
    }
    func copy(_ index: Int) {
        guard choices.indices.contains(index) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(choices[index], forType: .string)
        LocalTelemetry.shared.record(.refinementCopy); hide()
    }
    func choose(_ index: Int, keepOpen: Bool = false) {
        guard choices.indices.contains(index), !applying else { return }
        if copyOnly { copy(index); return }
        guard let receipt, targetMatches(), let element, let pid else { copyOnly = true; status = "Copy to use"; return }
        applying = true
        let text = choices[index], id = session, version = revision
        DictationFieldReader.read(element: element, pid: pid) { [weak self] value, range in
            MainActor.assumeIsolated {
                guard let self, self.session == id else { return }
                self.applying = false
                guard self.revision == version else { return }
                guard self.visible, self.targetMatches(), let value, let range, receipt.matches(value: value, selection: range) else {
                    self.copyOnly = true; self.status = "Text changed · copy to use"; return
                }
                TextInserter.replace(charactersToDelete: receipt.text.count, with: text)
                self.revision &+= 1; self.receipt = nil; self.currentText = text; self.appliedIndex = index; if !keepOpen { self.hide() }; self.captureReceipt()
                LocalTelemetry.shared.record(.refinementChosen)
            }
        }
    }
}

struct DictationAlternativesView: View {
    @ObservedObject var model: DictationAlternatives
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("AI", selection: $model.provider) {
                    ForEach(RefinementProvider.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 130)
                if model.busy { ProgressView().controlSize(.small).accessibilityLabel("Preparing alternatives") }
                if !model.status.isEmpty { Text(model.status).font(.caption).fixedSize(horizontal: false, vertical: true) }
                Spacer(minLength: 0)
                if !model.busy && model.choices.count == 1 && model.provider != .off { Button("Retry") { model.refine() } }
                Button("Emoji") { model.onEmoji?() }
                Button { model.hide() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close")
            }.padding(12)
            Divider()
            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(model.choices.enumerated()), id: \.offset) { index, text in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("\(index + 1) · \(model.labels.indices.contains(index) ? model.labels[index] : "Option")").font(.system(size: 12, weight: .semibold))
                                Spacer()
                                if !model.copyOnly { Button("Copy") { model.copy(index) } }
                                Button(model.copyOnly ? "Copy" : "Use") { model.choose(index) }
                            }
                            Text(text).font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .id(index)
                        .background(model.selected == index ? Color.accentColor.opacity(0.10) : Color.clear)
                        .contentShape(Rectangle()).onTapGesture { model.selected = index }
                        Divider()
                    }
                }
            }
            .onChange(of: model.selected) { _, value in proxy.scrollTo(value, anchor: .top) }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }
}

/// Fixed controls with a scrolling full-text preview under the emoji browser.
struct DictationSwapStrip: View {
    @ObservedObject var model: DictationAlternatives
    var body: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(spacing: 8) {
                if model.choices.isEmpty {
                    Text("Text alternatives").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button("Analyse text") { model.analyseFocusedText() }
                } else {
                    Picker("Text", selection: $model.selected) {
                        ForEach(Array(model.choices.indices), id: \.self) { index in
                            Text(model.labels.indices.contains(index) ? model.labels[index] : "Option").tag(index)
                        }
                    }.labelsHidden().onChange(of: model.selected) { _, _ in model.textPreviewActive = true }
                    Text(model.textPreviewActive ? "⇧⇥ / ⇥ · ↵" : "⇧⇥ / ⇥").font(.system(size: 12)).foregroundStyle(.secondary)
                    if model.busy { ProgressView().controlSize(.small) }
                    Spacer(minLength: 0)
                    Button(model.copyOnly ? "Copy" : "Use") { model.choose(model.selected, keepOpen: true) }
                }
            }.padding(.horizontal, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.choices.indices.contains(model.selected) ? model.choices[model.selected] : "Dictate, then review the complete passage here.")
                        .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    if !model.reviewNotes.isEmpty, model.selected >= model.choices.count - 1 {
                        Divider()
                        Text(model.reviewNotes).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
            }
            if !model.status.isEmpty { Text(model.status).font(.caption).padding(.horizontal, 10) }
        }.padding(.bottom, 10).frame(height: 180)
    }
}
