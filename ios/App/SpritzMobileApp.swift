import SwiftUI
import UIKit

enum AppTab: String, Hashable {
    case keyboard
    case typing
    case emoji
}

@MainActor
final class MobileAppModel: ObservableObject {
    let bridge = SpritzIosBridge()
    let testPadTarget = TextViewDocumentTarget()

    @Published var config: KeyboardConfigDTO
    @Published var emojiSnapshot: EmojiSnapshotDTO?
    @Published var keyboardEnabled: Bool
    @Published var selectedTab: AppTab = .keyboard
    @Published var previewDeckMode: PreviewDeckMode?
    @Published var useSystemKeyboard: Bool = false
    @Published var sampleText: String
    @Published var configVersion: Int = 0
    let lexiconWordCount: Int

    init() {
        let cfg = bridge.loadConfig()
        self.config = cfg
        self.keyboardEnabled = SpritzIosBridge.isKeyboardEnabledInSettings()
        self.lexiconWordCount = bridge.lexiconCount()
        self.sampleText = "Hey mate, grabbing coffee soon — don't worry about the colour, I'm on my way "
        self.emojiSnapshot = bridge.emojiSnapshot(mode: "pinned", query: "", contextBefore: "")

        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "--preview-tab"), args.indices.contains(idx + 1) {
            self.selectedTab = AppTab(rawValue: args[idx + 1]) ?? .keyboard
        }
        if let idx = args.firstIndex(of: "--preview-deck"), args.indices.contains(idx + 1) {
            self.previewDeckMode = PreviewDeckMode(rawValue: args[idx + 1])
            self.useSystemKeyboard = false
        }
        if let idx = args.firstIndex(of: "--preview-text"), args.indices.contains(idx + 1) {
            self.sampleText = args[idx + 1]
        }
    }

    func refreshStatus() {
        keyboardEnabled = SpritzIosBridge.isKeyboardEnabledInSettings()
        config = bridge.loadConfig()
        refreshEmoji()
        configVersion &+= 1
    }

    func persistConfig() {
        bridge.saveConfig(config)
        refreshEmoji()
        configVersion &+= 1
    }

    func refreshEmoji() {
        emojiSnapshot = bridge.emojiSnapshot(mode: "all", query: "", contextBefore: "")
    }

    func pinSlot(_ slotIndex: Int, hex: String) {
        _ = bridge.emojiPin(slotIndex: slotIndex, hex: hex)
        refreshEmoji()
    }
}

@main
struct SpritzMobileApp: App {
    @StateObject private var model = MobileAppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView(selection: $model.selectedTab) {
                KeyboardTabView(model: model)
                    .tabItem { Label("Keyboard", systemImage: "keyboard") }
                    .tag(AppTab.keyboard)

                TypingTabView(model: model)
                    .tabItem { Label("Typing", systemImage: "slider.horizontal.3") }
                    .tag(AppTab.typing)

                EmojiTabView(model: model)
                    .tabItem { Label("Emoji", systemImage: "face.smiling") }
                    .tag(AppTab.emoji)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    model.refreshStatus()
                }
            }
        }
    }
}

private struct KeyboardTabView: View {
    @ObservedObject var model: MobileAppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            statusHeader
            Divider()
            testPadArea
            if !model.useSystemKeyboard {
                GeometryReader { geo in
                    EmbeddedDeckRepresentable(
                        bridge: model.bridge,
                        target: model.testPadTarget,
                        configVersion: model.configVersion,
                        previewMode: model.previewDeckMode,
                        isDark: colorScheme == .dark,
                        deckWidth: geo.size.width,
                        onMutated: {
                            if let tv = model.testPadTarget.textView {
                                model.sampleText = tv.text ?? ""
                            }
                        },
                        onSwitchToSystem: {
                            model.useSystemKeyboard = true
                        }
                    )
                    .frame(width: geo.size.width, height: deckHeight)
                }
                .frame(height: deckHeight)
                .zIndex(5)
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    private var deckHeight: CGFloat {
        SpritzKeyboardContainerView.preferredHeight(numberRow: model.config.numberRow)
    }

    private var statusHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.keyboardEnabled ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text("Spritz")
                .font(.subheadline.weight(.semibold))
            Text(model.keyboardEnabled ? "Enabled" : "Off")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Picker("Input", selection: $model.useSystemKeyboard) {
                Text("Deck").tag(false)
                Text("System").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 126)
            .accessibilityIdentifier("spritz.inputModePicker")
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.caption.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .background(Color(.tertiarySystemFill), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Keyboard Settings")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var testPadArea: some View {
        ZStack(alignment: .topTrailing) {
            TestPadRepresentable(
                text: $model.sampleText,
                target: model.testPadTarget,
                useSystemKeyboard: model.useSystemKeyboard,
                isDark: colorScheme == .dark
            )
            .padding(12)

            if !model.sampleText.isEmpty {
                Button {
                    model.sampleText = ""
                    model.testPadTarget.textView?.text = ""
                    model.testPadTarget.onDidMutate?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }
                .padding(18)
                .accessibilityLabel("Clear test pad")
                .accessibilityIdentifier("spritz.clearPad")
            }
        }
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .padding(12)
        .frame(maxHeight: .infinity)
    }
}

private struct TypingTabView: View {
    @ObservedObject var model: MobileAppModel

    var body: some View {
        VStack(spacing: 12) {
            GroupBox {
                VStack(spacing: 0) {
                    toggleRow("Number row", systemImage: "number", isOn: binding(\.numberRow))
                    Divider()
                    toggleRow("Key flicks", systemImage: "arrow.down.to.line", isOn: binding(\.keyFlicks))
                    Divider()
                    toggleRow("Glide typing", systemImage: "scribble.variable", isOn: binding(\.glideTyping))
                    Divider()
                    toggleRow("Haptics", systemImage: "iphone.radiowaves.left.and.right", isOn: binding(\.haptics))
                }
            }

            GroupBox {
                VStack(spacing: 0) {
                    toggleRow("Auto-capitalise", systemImage: "textformat.size", isOn: binding(\.autoCaps))
                    Divider()
                    toggleRow("Double-space period", systemImage: "circle.fill", isOn: binding(\.doubleSpacePeriod))
                    Divider()
                    HStack {
                        Label("Autocorrect", systemImage: "wand.and.stars")
                            .font(.subheadline)
                        Spacer()
                        Picker("Autocorrect", selection: binding(\.autocorrect)) {
                            ForEach(AutocorrectModeDTO.allCases) { m in
                                Text(m.title).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 175)
                    }
                    .frame(height: 44)
                    Divider()
                    HStack {
                        Label("Spelling", systemImage: "text.book.closed")
                            .font(.subheadline)
                        Spacer()
                        Picker("Spelling", selection: binding(\.englishVariant)) {
                            ForEach(EnglishVariantDTO.allCases) { v in
                                Text(v.title).tag(v)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 145)
                    }
                    .frame(height: 44)
                }
            }

            GroupBox {
                HStack {
                    Label("On-device dictionary", systemImage: "lock.shield")
                        .font(.subheadline)
                    Spacer()
                    Text("\(model.lexiconWordCount.formatted()) · \(model.config.personalWords.count) learned")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("spritz.lexiconCount")
                }
                .frame(height: 36)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .background(Color(.systemGroupedBackground))
    }

    private func toggleRow(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
        }
        .frame(height: 42)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<KeyboardConfigDTO, T>) -> Binding<T> {
        Binding(
            get: { model.config[keyPath: keyPath] },
            set: { val in
                model.config[keyPath: keyPath] = val
                model.persistConfig()
            }
        )
    }
}

private struct EmojiTabView: View {
    @ObservedObject var model: MobileAppModel
    @State private var editingSlot: Int?
    @State private var showingAddSnippet = false
    @State private var newTrigger = ""
    @State private var newBody = ""

    private let skinTones: [(id: String, glyph: String, label: String)] = [
        ("default", "🖐️", "Default"),
        ("light", "🖐🏻", "Light"),
        ("mediumLight", "🖐🏼", "Medium-light"),
        ("medium", "🖐🏽", "Medium"),
        ("mediumDark", "🖐🏾", "Medium-dark"),
        ("dark", "🖐🏿", "Dark"),
    ]

    var body: some View {
        VStack(spacing: 12) {
            GroupBox {
                HStack(spacing: 8) {
                    Text("Skin tone")
                        .font(.subheadline)
                    Spacer()
                    ForEach(skinTones, id: \.id) { tone in
                        let selected = model.config.skinTone == tone.id
                        Button {
                            model.config.skinTone = tone.id
                            model.persistConfig()
                        } label: {
                            Text(tone.glyph)
                                .font(.system(size: 20))
                                .frame(width: 30, height: 30)
                                .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: Circle())
                                .overlay(
                                    Circle().strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tone.label)
                    }
                }
                .frame(height: 36)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pinned slots")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    let pinned = model.emojiSnapshot?.pinned ?? []
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                        ForEach(0..<min(10, pinned.count), id: \.self) { idx in
                            let keyNum = idx == 9 ? "0" : "\(idx + 1)"
                            Button {
                                editingSlot = idx
                            } label: {
                                ZStack(alignment: .topLeading) {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color(.tertiarySystemFill))
                                        .frame(height: 44)
                                    Text(keyNum)
                                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .padding(4)
                                    Text(pinned[idx].glyph)
                                        .font(.system(size: 24))
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            GroupBox {
                VStack(spacing: 0) {
                    HStack {
                        Text("Snippets")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            newTrigger = "/"
                            newBody = ""
                            showingAddSnippet = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.caption.weight(.bold))
                        }
                    }
                    .padding(.bottom, 6)

                    let pairs = model.config.snippets.sorted { $0.key < $1.key }.prefix(5)
                    ForEach(Array(pairs.enumerated()), id: \.element.key) { idx, pair in
                        if idx > 0 { Divider() }
                        HStack {
                            Text(pair.key)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(pair.value)
                                .font(.subheadline)
                                .lineLimit(1)
                            Button {
                                model.config.snippets.removeValue(forKey: pair.key)
                                model.persistConfig()
                            } label: {
                                Image(systemName: "minus.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(height: 32)
                    }
                }
            }

            GroupBox {
                HStack {
                    Text("Custom words & overrides")
                        .font(.subheadline)
                    Spacer()
                    Text("\(model.config.personalWords.count) · \(model.config.rejectedCorrections.count) muted")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("Reset") {
                        model.config.personalWords.removeAll()
                        model.config.rejectedCorrections.removeAll()
                        model.persistConfig()
                    }
                    .font(.caption.weight(.semibold))
                    .disabled(model.config.personalWords.isEmpty && model.config.rejectedCorrections.isEmpty)
                }
                .frame(height: 32)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: Binding(get: { editingSlot != nil }, set: { if !$0 { editingSlot = nil } })) {
            if let slot = editingSlot {
                EmojiPinPickerSheet(
                    items: model.emojiSnapshot?.items ?? [],
                    onPick: { hex in
                        model.pinSlot(slot, hex: hex)
                        editingSlot = nil
                    }
                )
            }
        }
        .sheet(isPresented: $showingAddSnippet) {
            NavigationStack {
                Form {
                    TextField("Trigger (e.g. /sig)", text: $newTrigger)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Expansion text", text: $newBody)
                }
                .navigationTitle("New Snippet")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingAddSnippet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let trig = newTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trig.isEmpty && !newBody.isEmpty {
                                model.config.snippets[trig] = newBody
                                model.persistConfig()
                            }
                            showingAddSnippet = false
                        }
                    }
                }
            }
        }
    }
}

private struct EmojiPinPickerSheet: View {
    let items: [EmojiItemDTO]
    let onPick: (String) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var filtered: [EmojiItemDTO] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return Array(items.prefix(120)) }
        return items.filter { $0.label.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 10) {
                    ForEach(Array(filtered.prefix(120).enumerated()), id: \.offset) { _, item in
                        Button {
                            onPick(item.hex)
                        } label: {
                            Text(item.glyph).font(.system(size: 28))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .searchable(text: $query, prompt: "Search emoji")
            .navigationTitle("Choose Emoji")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct TestPadRepresentable: UIViewRepresentable {
    @Binding var text: String
    let target: TextViewDocumentTarget
    let useSystemKeyboard: Bool
    let isDark: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.accessibilityIdentifier = "spritz.testPad"
        tv.backgroundColor = .clear
        tv.font = .systemFont(ofSize: 16.5)
        tv.textColor = isDark ? .white : .label
        tv.text = text
        tv.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        tv.inputView = useSystemKeyboard ? nil : context.coordinator.dummyInputView
        context.coordinator.lastUseSystemKeyboard = useSystemKeyboard
        tv.delegate = context.coordinator
        target.textView = tv
        target.onDidMutate = { [weak tv] in
            guard let tv else { return }
            let val = tv.text ?? ""
            if text != val {
                text = val
            }
        }
        DispatchQueue.main.async {
            tv.becomeFirstResponder()
        }
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        tv.textColor = isDark ? .white : .label
        if context.coordinator.lastUseSystemKeyboard != useSystemKeyboard {
            context.coordinator.lastUseSystemKeyboard = useSystemKeyboard
            tv.inputView = useSystemKeyboard ? nil : context.coordinator.dummyInputView
            tv.reloadInputViews()
            if !tv.isFirstResponder {
                DispatchQueue.main.async {
                    tv.becomeFirstResponder()
                }
            }
        }
        if tv.text != text {
            tv.text = text
            tv.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: TestPadRepresentable
        let dummyInputView = UIView()
        var lastUseSystemKeyboard: Bool?
        init(parent: TestPadRepresentable) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) {
            let val = textView.text ?? ""
            if parent.text != val {
                parent.text = val
            }
        }
    }
}

private struct EmbeddedDeckRepresentable: UIViewRepresentable {
    let bridge: SpritzIosBridge
    let target: TextViewDocumentTarget
    let configVersion: Int
    let previewMode: PreviewDeckMode?
    let isDark: Bool
    let deckWidth: CGFloat
    let onMutated: () -> Void
    let onSwitchToSystem: () -> Void

    final class HostWrapperView: UIView {
        let deck: SpritzKeyboardContainerView
        init(deck: SpritzKeyboardContainerView) {
            self.deck = deck
            super.init(frame: .zero)
            accessibilityIdentifier = "spritz.embeddedDeck"
            clipsToBounds = false
            deck.translatesAutoresizingMaskIntoConstraints = false
            deck.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(deck)
            NSLayoutConstraint.activate([
                deck.leadingAnchor.constraint(equalTo: leadingAnchor),
                deck.trailingAnchor.constraint(equalTo: trailingAnchor),
                deck.topAnchor.constraint(equalTo: topAnchor),
                deck.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }

    final class Coordinator {
        var lastConfigVersion: Int = -1
        var appliedPreview: PreviewDeckMode?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> HostWrapperView {
        let container = SpritzKeyboardContainerView(bridge: bridge, needsGlobe: true)
        container.target = target
        container.onDocumentMutated = onMutated
        container.onGlobePress = { _, _ in
            onSwitchToSystem()
        }
        container.updateAppearance(dark: isDark)
        container.reloadConfiguration(needsGlobe: true)
        if let previewMode {
            container.applyPreviewDeckMode(previewMode)
            context.coordinator.appliedPreview = previewMode
        }
        context.coordinator.lastConfigVersion = configVersion
        DispatchQueue.main.async {
            container.refreshContext()
        }
        return HostWrapperView(deck: container)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: HostWrapperView, context: Context) -> CGSize? {
        let w = deckWidth > 10 ? deckWidth : (proposal.width ?? 390)
        return CGSize(width: w, height: uiView.deck.totalHeight)
    }

    func updateUIView(_ uiView: HostWrapperView, context: Context) {
        let container = uiView.deck
        container.updateAppearance(dark: isDark)
        if context.coordinator.lastConfigVersion != configVersion {
            context.coordinator.lastConfigVersion = configVersion
            container.reloadConfiguration(needsGlobe: true)
        }
        if let previewMode, context.coordinator.appliedPreview != previewMode {
            context.coordinator.appliedPreview = previewMode
            container.applyPreviewDeckMode(previewMode)
        }
    }
}
