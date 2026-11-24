import UIKit

enum PreviewDeckMode: String {
    case abc
    case tools
    case emoji
    case numbers
}

@MainActor
final class SpritzKeyboardContainerView: UIView {
    let bridge: SpritzIosBridge
    weak var target: TextDocumentTarget?

    var onGlobePress: ((_ view: UIView, _ event: UIEvent) -> Void)?
    var onDocumentMutated: (() -> Void)?

    private let instrumentBar = InstrumentBarView()
    private let deckView = KeyboardDeckView()
    private let emojiDeck = EmojiDeckView()

    private var heightConstraint: NSLayoutConstraint!
    private var config: KeyboardConfigDTO
    private var isDark = false
    private var isEmojiGridVisible = false
    private var isEmojiSearchActive = false
    private var isToolsVisible = false
    private var isSnippetsVisible = false
    private var selectModeActive = false
    private var currentEmojiMode = "pinned"
    private var emojiSearchQuery = ""
    private var emojiSearchResults: [EmojiItemDTO] = []
    private var lastOutput: KeyboardOutputDTO?
    private var needsGlobeKey: Bool
    private var lastSelfMutationUptime: TimeInterval = 0

    init(bridge: SpritzIosBridge, needsGlobe: Bool) {
        self.bridge = bridge
        self.needsGlobeKey = needsGlobe
        self.config = bridge.loadConfig()
        super.init(frame: .zero)
        setupHierarchy()
        wireCallbacks()
        reloadConfiguration(needsGlobe: needsGlobe)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func preferredHeight(numberRow: Bool) -> CGFloat {
        InstrumentBarView.height + (numberRow ? 258 : 222)
    }

    var totalHeight: CGFloat {
        Self.preferredHeight(numberRow: config.numberRow)
    }

    private func setupHierarchy() {
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = false
        heightConstraint = heightAnchor.constraint(equalToConstant: totalHeight)
        heightConstraint.priority = UILayoutPriority(999)
        heightConstraint.isActive = true

        addSubview(instrumentBar)
        deckView.translatesAutoresizingMaskIntoConstraints = false
        emojiDeck.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emojiDeck)
        addSubview(deckView)
        emojiDeck.isHidden = true

        NSLayoutConstraint.activate([
            instrumentBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            instrumentBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            instrumentBar.topAnchor.constraint(equalTo: topAnchor),

            deckView.leadingAnchor.constraint(equalTo: leadingAnchor),
            deckView.trailingAnchor.constraint(equalTo: trailingAnchor),
            deckView.topAnchor.constraint(equalTo: instrumentBar.bottomAnchor),
            deckView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emojiDeck.leadingAnchor.constraint(equalTo: leadingAnchor),
            emojiDeck.trailingAnchor.constraint(equalTo: trailingAnchor),
            emojiDeck.topAnchor.constraint(equalTo: instrumentBar.bottomAnchor),
            emojiDeck.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func markSelfMutation() {
        lastSelfMutationUptime = ProcessInfo.processInfo.systemUptime
    }

    private func wireCallbacks() {
        instrumentBar.onSelectCandidate = { [weak self] idx in
            guard let self, let target = self.target else { return }
            self.markSelfMutation()
            self.lastOutput = self.bridge.acceptCandidate(index: idx, target: target)
            self.notifyStateChanged()
        }

        instrumentBar.onSelectEmojiHint = { [weak self] hint in
            guard let self, let target = self.target else { return }
            self.markSelfMutation()
            _ = self.bridge.emojiPick(hex: hint.hex, target: target)
            self.lastOutput = self.bridge.syncContext(target: target)
            self.notifyStateChanged()
        }

        instrumentBar.onTapUndoDelete = { [weak self] in
            guard let self, let target = self.target else { return }
            self.markSelfMutation()
            self.lastOutput = self.bridge.undoLastDelete(target: target)
            self.notifyStateChanged()
        }

        instrumentBar.onToggleTools = { [weak self] in
            guard let self else { return }
            if self.isSnippetsVisible {
                self.isSnippetsVisible = false
            } else {
                self.isToolsVisible.toggle()
            }
            self.isEmojiSearchActive = false
            self.isEmojiGridVisible = false
            self.updateDeckVisibility()
            self.refreshBar()
        }

        instrumentBar.onCloseEmojiSearch = { [weak self] in
            guard let self else { return }
            self.isEmojiSearchActive = false
            self.emojiSearchQuery = ""
            self.isEmojiGridVisible = true
            self.refreshEmojiGrid()
            self.updateDeckVisibility()
            self.refreshBar()
        }

        instrumentBar.onSelectEmojiResult = { [weak self] item in
            guard let self else { return }
            self.markSelfMutation()
            _ = self.bridge.emojiPick(hex: item.hex, target: self.target)
            self.isEmojiSearchActive = false
            self.emojiSearchQuery = ""
            self.isEmojiGridVisible = false
            self.updateDeckVisibility()
            if let target = self.target {
                self.lastOutput = self.bridge.syncContext(target: target)
            }
            self.notifyStateChanged()
        }

        instrumentBar.onToolAction = { [weak self] action in
            self?.handleToolAction(action)
        }

        instrumentBar.onSelectSnippet = { [weak self] body in
            guard let self, let target = self.target else { return }
            self.markSelfMutation()
            self.lastOutput = self.bridge.insertDirect(body, target: target)
            self.isSnippetsVisible = false
            self.isToolsVisible = false
            self.notifyStateChanged()
        }

        deckView.onTapCharacter = { [weak self] ch, pt in
            guard let self else { return }
            if self.isEmojiSearchActive {
                self.emojiSearchQuery.append(ch.lowercased())
                self.refreshEmojiSearch()
                return
            }
            guard let target = self.target else { return }
            self.markSelfMutation()
            self.lastOutput = self.bridge.tapKey(ch, normPoint: pt, target: target)
            self.notifyStateChanged()
        }

        deckView.onDirectInsert = { [weak self] text in
            guard let self else { return }
            if self.isEmojiSearchActive {
                self.emojiSearchQuery.append(text.lowercased())
                self.refreshEmojiSearch()
                return
            }
            guard let target = self.target else { return }
            self.markSelfMutation()
            self.lastOutput = self.bridge.insertDirect(text, target: target)
            self.notifyStateChanged()
        }

        deckView.onSpace = { [weak self] in
            guard let self else { return }
            if self.isEmojiSearchActive {
                self.emojiSearchQuery.append(" ")
                self.refreshEmojiSearch()
                return
            }
            guard let target = self.target else { return }
            self.markSelfMutation()
            self.lastOutput = self.bridge.tapSpace(target: target)
            self.notifyStateChanged()
        }

        deckView.onReturn = { [weak self] in
            guard let self else { return }
            if self.isEmojiSearchActive {
                if let first = self.emojiSearchResults.first {
                    self.markSelfMutation()
                    _ = self.bridge.emojiPick(hex: first.hex, target: self.target)
                }
                self.isEmojiSearchActive = false
                self.emojiSearchQuery = ""
                self.updateDeckVisibility()
                if let target = self.target {
                    self.lastOutput = self.bridge.syncContext(target: target)
                }
                self.notifyStateChanged()
                return
            }
            guard let target = self.target else { return }
            self.markSelfMutation()
            self.lastOutput = self.bridge.tapReturn(target: target)
            self.notifyStateChanged()
        }

        deckView.onBackspace = { [weak self] in
            guard let self else { return }
            if self.isEmojiSearchActive {
                if !self.emojiSearchQuery.isEmpty {
                    self.emojiSearchQuery.removeLast()
                    self.refreshEmojiSearch()
                }
                return
            }
            guard let target = self.target else { return }
            self.markSelfMutation()
            self.lastOutput = self.bridge.tapBackspace(target: target)
            self.notifyStateChanged()
        }

        deckView.onSwipeDeleteWord = { [weak self] in
            guard let self, let target = self.target else { return }
            self.markSelfMutation()
            self.lastOutput = self.bridge.swipeDeleteWord(target: target)
            self.notifyStateChanged()
        }

        deckView.onShiftChanged = { [weak self] st in
            self?.bridge.setShift(st)
        }

        deckView.onGlideComplete = { [weak self] pts in
            guard let self, let target = self.target else { return }
            if self.isEmojiSearchActive { return }
            self.markSelfMutation()
            self.lastOutput = self.bridge.finishGlide(points: pts, target: target)
            self.notifyStateChanged()
        }

        deckView.onTrackpadMove = { [weak self] offset in
            guard let self, let target = self.target else { return }
            self.markSelfMutation()
            if self.selectModeActive {
                target.extendSelection(byCharacterOffset: offset)
            } else {
                target.adjustTextPosition(byCharacterOffset: offset)
            }
            self.lastOutput = self.bridge.syncContext(target: target)
            self.notifyStateChanged()
        }

        deckView.onRequestEmoji = { [weak self] in
            guard let self else { return }
            self.isToolsVisible = false
            self.isSnippetsVisible = false
            self.isEmojiSearchActive = false
            self.isEmojiGridVisible.toggle()
            if self.isEmojiGridVisible {
                self.currentEmojiMode = "auto"
                self.refreshEmojiGrid()
            }
            self.updateDeckVisibility()
            self.refreshBar()
        }

        deckView.onGlobePress = { [weak self] view, event in
            self?.onGlobePress?(view, event)
        }

        emojiDeck.onPickEmoji = { [weak self] item in
            guard let self else { return }
            self.markSelfMutation()
            _ = self.bridge.emojiPick(hex: item.hex, target: self.target)
            if let target = self.target {
                self.lastOutput = self.bridge.syncContext(target: target)
            }
            self.notifyStateChanged()
        }

        emojiDeck.onReturnABC = { [weak self] in
            guard let self else { return }
            self.isEmojiGridVisible = false
            self.isEmojiSearchActive = false
            self.updateDeckVisibility()
            self.refreshBar()
        }

        emojiDeck.onBackspace = { [weak self] in
            guard let self, let target = self.target else { return }
            self.lastOutput = self.bridge.tapBackspace(target: target)
            self.notifyStateChanged()
        }

        emojiDeck.onRequestSearch = { [weak self] in
            guard let self else { return }
            self.isEmojiGridVisible = false
            self.isEmojiSearchActive = true
            self.emojiSearchQuery = ""
            self.refreshEmojiSearch()
            self.deckView.setConfiguration(layerKind: .letters, shiftState: .off)
            self.updateDeckVisibility()
            self.refreshBar()
        }

        emojiDeck.onSelectMode = { [weak self] mode in
            guard let self else { return }
            self.currentEmojiMode = mode
            self.refreshEmojiGrid()
        }
    }

    func reloadConfiguration(needsGlobe: Bool? = nil) {
        if let needsGlobe {
            self.needsGlobeKey = needsGlobe
        }
        config = bridge.loadConfig()
        heightConstraint.constant = totalHeight
        deckView.setConfiguration(
            showNumberRow: config.numberRow,
            showFlicks: config.keyFlicks,
            glideEnabled: config.glideTyping,
            hapticsEnabled: config.haptics,
            needsGlobe: needsGlobeKey,
            returnKeyType: target?.returnKeyType ?? .default
        )
        refreshContext()
    }

    func updateAppearance(dark: Bool) {
        isDark = dark
        let theme = KeyboardTheme.resolved(dark: dark)
        backgroundColor = theme.deckBackground
        instrumentBar.applyTheme(theme)
        deckView.applyTheme(theme)
        emojiDeck.applyTheme(theme)
    }

    func handleExternalTextDidChange() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSelfMutationUptime < 0.16 {
            return
        }
        refreshContext()
    }

    func refreshContext() {
        lastOutput = bridge.syncContext(target: target)
        deckView.setLikelyNextChars(lastOutput?.likelyNextChars ?? "")
        if let shift = lastOutput?.shiftState {
            deckView.setConfiguration(shiftState: shift, returnKeyType: target?.returnKeyType ?? .default)
        } else {
            deckView.setConfiguration(returnKeyType: target?.returnKeyType ?? .default)
        }
        if isEmojiGridVisible {
            refreshEmojiGrid()
        }
        refreshBar()
    }

    func applyPreviewDeckMode(_ mode: PreviewDeckMode) {
        switch mode {
        case .abc:
            isToolsVisible = false
            isSnippetsVisible = false
            isEmojiGridVisible = false
            isEmojiSearchActive = false
            deckView.setConfiguration(layerKind: .letters)
        case .tools:
            isToolsVisible = true
            isSnippetsVisible = false
            isEmojiGridVisible = false
            isEmojiSearchActive = false
        case .emoji:
            isToolsVisible = false
            isSnippetsVisible = false
            isEmojiGridVisible = true
            isEmojiSearchActive = false
            currentEmojiMode = "pinned"
            refreshEmojiGrid()
        case .numbers:
            isToolsVisible = false
            isSnippetsVisible = false
            isEmojiGridVisible = false
            isEmojiSearchActive = false
            deckView.setConfiguration(layerKind: .numbers)
        }
        updateDeckVisibility()
        refreshBar()
    }

    private func handleToolAction(_ action: InstrumentBarView.ToolAction) {
        guard let target else { return }
        switch action {
        case .moveLeft:
            if selectModeActive {
                target.extendSelection(byCharacterOffset: -1)
            } else {
                target.adjustTextPosition(byCharacterOffset: -1)
            }
            refreshContext()
        case .moveRight:
            if selectModeActive {
                target.extendSelection(byCharacterOffset: 1)
            } else {
                target.adjustTextPosition(byCharacterOffset: 1)
            }
            refreshContext()
        case .toggleSelect:
            selectModeActive.toggle()
            refreshBar()
        case .undo:
            markSelfMutation()
            if lastOutput?.undoWord != nil {
                lastOutput = bridge.undoLastDelete(target: target)
            } else {
                target.undoEdit()
                lastOutput = bridge.syncContext(target: target)
            }
            notifyStateChanged()
        case .copy:
            if let sel = target.selectedText, !sel.isEmpty {
                UIPasteboard.general.string = sel
            } else if let full = target.documentContextBeforeInput {
                UIPasteboard.general.string = full
            }
        case .paste:
            if let clip = UIPasteboard.general.string, !clip.isEmpty {
                markSelfMutation()
                lastOutput = bridge.insertDirect(clip, target: target)
                notifyStateChanged()
            }
        case .openSnippets:
            isSnippetsVisible = true
            refreshBar()
        }
    }

    private func updateDeckVisibility() {
        deckView.isHidden = isEmojiGridVisible
        emojiDeck.isHidden = !isEmojiGridVisible
        if !isEmojiGridVisible {
            bringSubviewToFront(deckView)
        }
    }

    private func refreshEmojiGrid() {
        let ctx = target?.documentContextBeforeInput ?? ""
        if let snap = bridge.emojiSnapshot(mode: currentEmojiMode, query: "", contextBefore: ctx) {
            currentEmojiMode = snap.mode
            emojiDeck.update(snapshot: snap)
        }
    }

    private func refreshEmojiSearch() {
        let ctx = target?.documentContextBeforeInput ?? ""
        let query = emojiSearchQuery.trimmingCharacters(in: .whitespaces)
        let effectiveQuery = query.isEmpty ? "smile" : query
        if let snap = bridge.emojiSnapshot(mode: "all", query: effectiveQuery, contextBefore: ctx) {
            emojiSearchResults = query.isEmpty ? snap.pinned + Array(snap.items.prefix(12)) : snap.items
        }
        refreshBar()
    }

    private func notifyStateChanged() {
        deckView.setLikelyNextChars(lastOutput?.likelyNextChars ?? "")
        if let shift = lastOutput?.shiftState {
            deckView.setConfiguration(shiftState: shift, returnKeyType: target?.returnKeyType ?? .default)
        }
        refreshBar()
        onDocumentMutated?()
    }

    private func refreshBar() {
        let barMode: InstrumentBarMode
        if isEmojiSearchActive {
            barMode = .emojiSearch
        } else if isSnippetsVisible {
            barMode = .snippets
        } else if isToolsVisible {
            barMode = .tools
        } else {
            barMode = .predict
        }

        instrumentBar.update(
            mode: barMode,
            candidates: lastOutput?.candidates ?? [],
            emojiHints: lastOutput?.emojiHints ?? [],
            undoWord: lastOutput?.undoWord,
            snippets: config.snippets,
            selectActive: selectModeActive,
            emojiSearchQuery: emojiSearchQuery,
            emojiSearchResults: emojiSearchResults
        )
    }
}
