import UIKit

enum InstrumentBarMode: Equatable {
    case predict
    case tools
    case snippets
    case emojiSearch
}

@MainActor
final class InstrumentBarView: UIView {
    static let height: CGFloat = 42

    var onSelectCandidate: ((Int) -> Void)?
    var onSelectEmojiHint: ((EmojiHintDTO) -> Void)?
    var onTapUndoDelete: (() -> Void)?
    var onToggleTools: (() -> Void)?
    var onCloseEmojiSearch: (() -> Void)?
    var onSelectEmojiResult: ((EmojiItemDTO) -> Void)?
    var onToolAction: ((ToolAction) -> Void)?
    var onSelectSnippet: ((String) -> Void)?

    enum ToolAction {
        case moveLeft
        case moveRight
        case toggleSelect
        case undo
        case copy
        case paste
        case openSnippets
    }

    private var theme = KeyboardTheme.resolved(dark: false)
    private var mode: InstrumentBarMode = .predict
    private var candidates: [CandidateDTO] = []
    private var emojiHints: [EmojiHintDTO] = []
    private var emojiSearchQuery = ""
    private var emojiSearchResults: [EmojiItemDTO] = []
    private var snippets: [(trigger: String, body: String)] = []
    private var undoWord: String?
    private var selectModeActive = false

    private let bottomHairline = UIView()

    // Predict strip views
    private let predictStack = UIStackView()
    private var candidateButtons: [UIButton] = []
    private let divider1 = UIView()
    private let divider2 = UIView()
    private let hintOrUndoButton = UIButton(type: .system)
    private let toolsButton = UIButton(type: .system)

    // Tools strip views
    private let toolsStack = UIStackView()
    private var toolButtons: [UIButton] = []
    private let selectButton = UIButton(type: .system)

    // Snippets horizontal strip
    private let snippetsRow = UIStackView()
    private let snippetsBackBtn = UIButton(type: .system)
    private let snippetsScroll = UIScrollView()
    private let snippetsStack = UIStackView()

    // Emoji Search horizontal strip
    private let emojiSearchRow = UIStackView()
    private let searchQueryPill = UIButton(type: .system)
    private let searchResultsScroll = UIScrollView()
    private let searchResultsStack = UIStackView()
    private let searchGridBtn = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
        applyTheme(theme)
        refreshUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true

        bottomHairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomHairline)
        NSLayoutConstraint.activate([
            bottomHairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomHairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomHairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomHairline.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
        ])

        setupPredictRow()
        setupToolsRow()
        setupSnippetsRow()
        setupEmojiSearchRow()
    }

    private func setupPredictRow() {
        predictStack.translatesAutoresizingMaskIntoConstraints = false
        predictStack.axis = .horizontal
        predictStack.alignment = .center
        predictStack.spacing = 4
        addSubview(predictStack)
        NSLayoutConstraint.activate([
            predictStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            predictStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            predictStack.topAnchor.constraint(equalTo: topAnchor),
            predictStack.bottomAnchor.constraint(equalTo: bottomHairline.topAnchor),
        ])

        let candsContainer = UIStackView()
        candsContainer.axis = .horizontal
        candsContainer.alignment = .center
        candsContainer.distribution = .fill
        candsContainer.spacing = 4

        for i in 0..<3 {
            let btn = UIButton(type: .system)
            btn.tag = i
            btn.titleLabel?.font = .systemFont(ofSize: 15, weight: .regular)
            btn.titleLabel?.lineBreakMode = .byTruncatingTail
            btn.layer.cornerRadius = 6
            btn.heightAnchor.constraint(equalToConstant: 32).isActive = true
            btn.addTarget(self, action: #selector(handleCandidateTap(_:)), for: .touchUpInside)
            candidateButtons.append(btn)
        }

        divider1.translatesAutoresizingMaskIntoConstraints = false
        divider2.translatesAutoresizingMaskIntoConstraints = false
        for div in [divider1, divider2] {
            div.widthAnchor.constraint(equalToConstant: 1).isActive = true
            div.heightAnchor.constraint(equalToConstant: 16).isActive = true
        }

        candsContainer.addArrangedSubview(candidateButtons[0])
        candsContainer.addArrangedSubview(divider1)
        candsContainer.addArrangedSubview(candidateButtons[1])
        candsContainer.addArrangedSubview(divider2)
        candsContainer.addArrangedSubview(candidateButtons[2])

        NSLayoutConstraint.activate([
            candidateButtons[1].widthAnchor.constraint(equalTo: candidateButtons[0].widthAnchor),
            candidateButtons[2].widthAnchor.constraint(equalTo: candidateButtons[0].widthAnchor),
        ])

        hintOrUndoButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        hintOrUndoButton.layer.cornerRadius = 6
        hintOrUndoButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 7, bottom: 0, right: 7)
        hintOrUndoButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        hintOrUndoButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        hintOrUndoButton.setContentHuggingPriority(.required, for: .horizontal)
        hintOrUndoButton.addTarget(self, action: #selector(handleHintOrUndoTap), for: .touchUpInside)

        toolsButton.setImage(UIImage(systemName: "slider.horizontal.3"), for: .normal)
        toolsButton.setPreferredSymbolConfiguration(.init(pointSize: 13.5, weight: .medium), forImageIn: .normal)
        toolsButton.layer.cornerRadius = 6
        toolsButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        toolsButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        toolsButton.accessibilityLabel = "Editing tools"
        toolsButton.addTarget(self, action: #selector(handleToolsToggle), for: .touchUpInside)

        predictStack.addArrangedSubview(candsContainer)
        predictStack.addArrangedSubview(hintOrUndoButton)
        predictStack.addArrangedSubview(toolsButton)
    }

    private func setupToolsRow() {
        toolsStack.translatesAutoresizingMaskIntoConstraints = false
        toolsStack.axis = .horizontal
        toolsStack.alignment = .center
        toolsStack.spacing = 4
        addSubview(toolsStack)
        NSLayoutConstraint.activate([
            toolsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            toolsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            toolsStack.topAnchor.constraint(equalTo: topAnchor),
            toolsStack.bottomAnchor.constraint(equalTo: bottomHairline.topAnchor),
        ])

        let specs: [(String?, String, Int, String)] = [
            ("chevron.left", "", 0, "Move cursor left"),
            ("chevron.right", "", 1, "Move cursor right"),
            (nil, "Sel", 2, "Toggle selection"),
            ("arrow.uturn.backward", "", 3, "Undo"),
            ("doc.on.doc", "", 4, "Copy"),
            ("doc.on.clipboard", "", 5, "Paste"),
            (nil, "Snips", 6, "Snippets"),
            ("xmark", "", 7, "Close tools"),
        ]
        for (sym, text, tag, label) in specs {
            let btn = tag == 2 ? selectButton : UIButton(type: .system)
            btn.tag = tag
            btn.layer.cornerRadius = 6
            btn.heightAnchor.constraint(equalToConstant: 30).isActive = true
            if let sym {
                btn.setImage(UIImage(systemName: sym), for: .normal)
                btn.setPreferredSymbolConfiguration(.init(pointSize: 13.5, weight: .medium), forImageIn: .normal)
            } else {
                btn.setTitle(text, for: .normal)
                btn.titleLabel?.font = .systemFont(ofSize: 12.5, weight: .semibold)
            }
            btn.accessibilityLabel = label
            btn.addTarget(self, action: #selector(handleToolButton(_:)), for: .touchUpInside)
            toolsStack.addArrangedSubview(btn)
            if tag < 7 {
                btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
            } else {
                btn.widthAnchor.constraint(equalToConstant: 32).isActive = true
            }
            toolButtons.append(btn)
        }
        toolsStack.distribution = .fillProportionally
    }

    private func setupSnippetsRow() {
        snippetsRow.translatesAutoresizingMaskIntoConstraints = false
        snippetsRow.axis = .horizontal
        snippetsRow.alignment = .center
        snippetsRow.spacing = 6
        addSubview(snippetsRow)
        NSLayoutConstraint.activate([
            snippetsRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            snippetsRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            snippetsRow.topAnchor.constraint(equalTo: topAnchor),
            snippetsRow.bottomAnchor.constraint(equalTo: bottomHairline.topAnchor),
        ])

        snippetsBackBtn.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        snippetsBackBtn.setPreferredSymbolConfiguration(.init(pointSize: 13.5, weight: .semibold), forImageIn: .normal)
        snippetsBackBtn.layer.cornerRadius = 6
        snippetsBackBtn.widthAnchor.constraint(equalToConstant: 30).isActive = true
        snippetsBackBtn.heightAnchor.constraint(equalToConstant: 30).isActive = true
        snippetsBackBtn.accessibilityLabel = "Back to tools"
        snippetsBackBtn.addTarget(self, action: #selector(handleToolsToggle), for: .touchUpInside)

        snippetsScroll.showsHorizontalScrollIndicator = false
        snippetsStack.translatesAutoresizingMaskIntoConstraints = false
        snippetsStack.axis = .horizontal
        snippetsStack.spacing = 6
        snippetsScroll.addSubview(snippetsStack)
        NSLayoutConstraint.activate([
            snippetsStack.leadingAnchor.constraint(equalTo: snippetsScroll.leadingAnchor),
            snippetsStack.trailingAnchor.constraint(equalTo: snippetsScroll.trailingAnchor),
            snippetsStack.topAnchor.constraint(equalTo: snippetsScroll.topAnchor),
            snippetsStack.bottomAnchor.constraint(equalTo: snippetsScroll.bottomAnchor),
            snippetsStack.heightAnchor.constraint(equalTo: snippetsScroll.heightAnchor),
        ])

        snippetsRow.addArrangedSubview(snippetsBackBtn)
        snippetsRow.addArrangedSubview(snippetsScroll)
    }

    private func setupEmojiSearchRow() {
        emojiSearchRow.translatesAutoresizingMaskIntoConstraints = false
        emojiSearchRow.axis = .horizontal
        emojiSearchRow.alignment = .center
        emojiSearchRow.spacing = 6
        addSubview(emojiSearchRow)
        NSLayoutConstraint.activate([
            emojiSearchRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            emojiSearchRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            emojiSearchRow.topAnchor.constraint(equalTo: topAnchor),
            emojiSearchRow.bottomAnchor.constraint(equalTo: bottomHairline.topAnchor),
        ])

        searchQueryPill.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        searchQueryPill.contentEdgeInsets = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        searchQueryPill.layer.cornerRadius = 6
        searchQueryPill.heightAnchor.constraint(equalToConstant: 28).isActive = true
        searchQueryPill.setContentHuggingPriority(.required, for: .horizontal)
        searchQueryPill.setContentCompressionResistancePriority(.required, for: .horizontal)
        searchQueryPill.addTarget(self, action: #selector(handleCloseEmojiSearch), for: .touchUpInside)

        searchResultsScroll.showsHorizontalScrollIndicator = false
        searchResultsStack.translatesAutoresizingMaskIntoConstraints = false
        searchResultsStack.axis = .horizontal
        searchResultsStack.spacing = 4
        searchResultsScroll.addSubview(searchResultsStack)
        NSLayoutConstraint.activate([
            searchResultsStack.leadingAnchor.constraint(equalTo: searchResultsScroll.leadingAnchor),
            searchResultsStack.trailingAnchor.constraint(equalTo: searchResultsScroll.trailingAnchor),
            searchResultsStack.topAnchor.constraint(equalTo: searchResultsScroll.topAnchor),
            searchResultsStack.bottomAnchor.constraint(equalTo: searchResultsScroll.bottomAnchor),
            searchResultsStack.heightAnchor.constraint(equalTo: searchResultsScroll.heightAnchor),
        ])

        searchGridBtn.setImage(UIImage(systemName: "square.grid.2x2"), for: .normal)
        searchGridBtn.setPreferredSymbolConfiguration(.init(pointSize: 13.5, weight: .medium), forImageIn: .normal)
        searchGridBtn.layer.cornerRadius = 6
        searchGridBtn.widthAnchor.constraint(equalToConstant: 30).isActive = true
        searchGridBtn.heightAnchor.constraint(equalToConstant: 28).isActive = true
        searchGridBtn.accessibilityLabel = "Back to emoji grid"
        searchGridBtn.addTarget(self, action: #selector(handleCloseEmojiSearch), for: .touchUpInside)

        emojiSearchRow.addArrangedSubview(searchQueryPill)
        emojiSearchRow.addArrangedSubview(searchResultsScroll)
        emojiSearchRow.addArrangedSubview(searchGridBtn)
    }

    func update(
        mode: InstrumentBarMode,
        candidates: [CandidateDTO],
        emojiHints: [EmojiHintDTO],
        undoWord: String?,
        snippets: [String: String],
        selectActive: Bool,
        emojiSearchQuery: String,
        emojiSearchResults: [EmojiItemDTO]
    ) {
        self.mode = mode
        self.candidates = candidates
        self.emojiHints = emojiHints
        self.undoWord = undoWord
        self.snippets = snippets.sorted(by: { $0.key < $1.key }).map { ($0.key, $0.value) }
        self.selectModeActive = selectActive
        self.emojiSearchQuery = emojiSearchQuery
        self.emojiSearchResults = emojiSearchResults
        refreshUI()
    }

    func applyTheme(_ theme: KeyboardTheme) {
        self.theme = theme
        backgroundColor = theme.barBackground
        bottomHairline.backgroundColor = theme.hairline
        divider1.backgroundColor = theme.hairline
        divider2.backgroundColor = theme.hairline

        toolsButton.tintColor = mode == .tools ? theme.accentInk : theme.primaryInk
        toolsButton.backgroundColor = mode == .tools ? theme.accentFill : .clear

        for btn in toolButtons {
            let active = btn === selectButton && selectModeActive
            btn.tintColor = active ? theme.accentInk : theme.primaryInk
            btn.setTitleColor(active ? theme.accentInk : theme.primaryInk, for: .normal)
            btn.backgroundColor = active ? theme.accentFill : theme.utilityKeyFill.withAlphaComponent(0.55)
        }
        snippetsBackBtn.tintColor = theme.primaryInk
        snippetsBackBtn.backgroundColor = theme.utilityKeyFill
        searchQueryPill.setTitleColor(theme.primaryInk, for: .normal)
        searchQueryPill.backgroundColor = theme.utilityKeyFill
        searchGridBtn.tintColor = theme.primaryInk
        searchGridBtn.backgroundColor = theme.utilityKeyFill
        refreshUI()
    }

    private func refreshUI() {
        predictStack.isHidden = mode != .predict
        toolsStack.isHidden = mode != .tools
        snippetsRow.isHidden = mode != .snippets
        emojiSearchRow.isHidden = mode != .emojiSearch

        switch mode {
        case .predict:
            let hasAutoCommit = candidates.contains { $0.autoCommit }
            for (i, btn) in candidateButtons.enumerated() {
                if i < candidates.count {
                    let item = candidates[i]
                    btn.isHidden = false
                    btn.isEnabled = true
                    let label = item.kind == "literal" ? "\"\(item.text)\"" : item.text
                    btn.setTitle(label, for: .normal)
                    let highlight = item.autoCommit || (!hasAutoCommit && i == 0 && item.kind != "literal")
                    btn.backgroundColor = highlight ? theme.candidateHighlightFill : .clear
                    btn.setTitleColor(theme.primaryInk, for: .normal)
                    btn.titleLabel?.font = .systemFont(ofSize: 15, weight: highlight ? .semibold : .regular)
                } else {
                    btn.isHidden = false
                    btn.isEnabled = false
                    btn.setTitle("", for: .normal)
                    btn.backgroundColor = .clear
                }
            }

            if let undo = undoWord, !undo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hintOrUndoButton.isHidden = false
                let clean = undo.trimmingCharacters(in: .whitespacesAndNewlines)
                hintOrUndoButton.setTitle("↺ \(clean)", for: .normal)
                hintOrUndoButton.setTitleColor(theme.accentInk, for: .normal)
                hintOrUndoButton.backgroundColor = theme.accentFill
                hintOrUndoButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
            } else if let hint = emojiHints.first {
                hintOrUndoButton.isHidden = false
                hintOrUndoButton.setTitle(hint.glyph, for: .normal)
                hintOrUndoButton.setTitleColor(theme.primaryInk, for: .normal)
                hintOrUndoButton.backgroundColor = theme.candidateHighlightFill
                hintOrUndoButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .regular)
                hintOrUndoButton.accessibilityLabel = "Insert \(hint.label)"
            } else {
                hintOrUndoButton.isHidden = true
            }

            toolsButton.tintColor = theme.primaryInk
            toolsButton.backgroundColor = .clear

        case .tools:
            selectButton.tintColor = selectModeActive ? theme.accentInk : theme.primaryInk
            selectButton.setTitleColor(selectModeActive ? theme.accentInk : theme.primaryInk, for: .normal)
            selectButton.backgroundColor = selectModeActive ? theme.accentFill : theme.utilityKeyFill.withAlphaComponent(0.55)

        case .snippets:
            for v in snippetsStack.arrangedSubviews { v.removeFromSuperview() }
            for (idx, item) in snippets.enumerated() {
                let pill = UIButton(type: .system)
                pill.tag = idx
                pill.setTitle(item.trigger, for: .normal)
                pill.setTitleColor(theme.primaryInk, for: .normal)
                pill.titleLabel?.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
                pill.backgroundColor = theme.letterKeyFill
                pill.layer.cornerRadius = 6
                pill.contentEdgeInsets = UIEdgeInsets(top: 0, left: 9, bottom: 0, right: 9)
                pill.heightAnchor.constraint(equalToConstant: 28).isActive = true
                pill.addTarget(self, action: #selector(handleSnippetTap(_:)), for: .touchUpInside)
                snippetsStack.addArrangedSubview(pill)
            }

        case .emojiSearch:
            let shown = emojiSearchQuery.isEmpty ? "🔍 Search emoji" : "🔍 \(emojiSearchQuery)"
            searchQueryPill.setTitle(shown, for: .normal)
            for v in searchResultsStack.arrangedSubviews { v.removeFromSuperview() }
            for (idx, item) in emojiSearchResults.prefix(16).enumerated() {
                let btn = UIButton(type: .system)
                btn.tag = idx
                btn.setTitle(item.glyph, for: .normal)
                btn.titleLabel?.font = .systemFont(ofSize: 22)
                btn.layer.cornerRadius = 6
                btn.widthAnchor.constraint(equalToConstant: 34).isActive = true
                btn.heightAnchor.constraint(equalToConstant: 30).isActive = true
                btn.accessibilityLabel = item.label
                btn.addTarget(self, action: #selector(handleEmojiSearchPick(_:)), for: .touchUpInside)
                searchResultsStack.addArrangedSubview(btn)
            }
        }
    }

    @objc private func handleCandidateTap(_ sender: UIButton) {
        onSelectCandidate?(sender.tag)
    }

    @objc private func handleHintOrUndoTap() {
        if undoWord != nil {
            onTapUndoDelete?()
        } else if let hint = emojiHints.first {
            onSelectEmojiHint?(hint)
        }
    }

    @objc private func handleToolsToggle() {
        onToggleTools?()
    }

    @objc private func handleCloseEmojiSearch() {
        onCloseEmojiSearch?()
    }

    @objc private func handleSnippetTap(_ sender: UIButton) {
        guard sender.tag < snippets.count else { return }
        onSelectSnippet?(snippets[sender.tag].body)
    }

    @objc private func handleEmojiSearchPick(_ sender: UIButton) {
        guard sender.tag < emojiSearchResults.count else { return }
        onSelectEmojiResult?(emojiSearchResults[sender.tag])
    }

    @objc private func handleToolButton(_ sender: UIButton) {
        switch sender.tag {
        case 0: onToolAction?(.moveLeft)
        case 1: onToolAction?(.moveRight)
        case 2: onToolAction?(.toggleSelect)
        case 3: onToolAction?(.undo)
        case 4: onToolAction?(.copy)
        case 5: onToolAction?(.paste)
        case 6: onToolAction?(.openSnippets)
        case 7: onToggleTools?()
        default: break
        }
    }
}
