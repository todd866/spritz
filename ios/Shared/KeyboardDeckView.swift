import UIKit

enum DeckLayer {
    case letters
    case numbers
    case symbols
}

private enum KeyAction: Equatable {
    case char(lower: String, upper: String, flick: String?)
    case symbol(String)
    case shift
    case backspace
    case layer(DeckLayer, title: String)
    case globe
    case emoji
    case space
    case returnKey
}

private struct KeySpec {
    let action: KeyAction
    let weight: CGFloat
    let isUtility: Bool
}

private final class KeyTileView: UIView {
    let spec: KeySpec
    var normFrame: CGRect = .zero

    private let mainLabel = UILabel()
    private let flickLabel = UILabel()
    private let iconView = UIImageView()
    private var isLowercaseLetter = false

    init(spec: KeySpec) {
        self.spec = spec
        super.init(frame: .zero)
        isUserInteractionEnabled = false

        layer.cornerRadius = 6.5
        layer.borderWidth = 1.0 / UIScreen.main.scale
        layer.masksToBounds = false
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 0
        layer.shadowOpacity = 1

        mainLabel.textAlignment = .center
        mainLabel.adjustsFontSizeToFitWidth = true
        mainLabel.minimumScaleFactor = 0.72
        addSubview(mainLabel)

        flickLabel.textAlignment = .right
        flickLabel.font = .systemFont(ofSize: 9.0, weight: .medium)
        addSubview(flickLabel)

        iconView.contentMode = .scaleAspectFit
        addSubview(iconView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 6.5).cgPath
        mainLabel.frame = isLowercaseLetter ? bounds.offsetBy(dx: 0, dy: -1.5) : bounds
        flickLabel.frame = CGRect(x: bounds.width - 14, y: 2.5, width: 10.5, height: 11)
        let iconSide: CGFloat = min(19, bounds.height * 0.44)
        iconView.frame = CGRect(
            x: (bounds.width - iconSide) * 0.5,
            y: (bounds.height - iconSide) * 0.5,
            width: iconSide,
            height: iconSide
        )
    }

    func configure(
        theme: KeyboardTheme,
        shift: ShiftStateDTO,
        showFlicks: Bool,
        returnType: UIReturnKeyType,
        pressed: Bool,
        trackpadActive: Bool
    ) {
        layer.shadowColor = theme.keyShadow.cgColor
        layer.borderColor = theme.keyBorder.cgColor

        flickLabel.isHidden = true
        iconView.isHidden = true
        mainLabel.isHidden = false

        let isSpace: Bool
        if case .space = spec.action { isSpace = true } else { isSpace = false }
        let dimAlpha: CGFloat = (trackpadActive && !isSpace) ? 0.28 : 1.0
        mainLabel.alpha = dimAlpha
        flickLabel.alpha = dimAlpha
        iconView.alpha = dimAlpha

        let wasLower = isLowercaseLetter
        isLowercaseLetter = false

        switch spec.action {
        case let .char(lower, upper, flick):
            let shifted = shift != .off
            isLowercaseLetter = !shifted
            mainLabel.text = shifted ? upper : lower
            mainLabel.font = .systemFont(ofSize: shifted ? 22.0 : 24.5, weight: .regular)
            mainLabel.textColor = theme.primaryInk
            backgroundColor = pressed ? theme.letterKeyPressed : theme.letterKeyFill
            if showFlicks, let flick {
                flickLabel.text = flick
                flickLabel.textColor = theme.secondaryInk.withAlphaComponent(0.58)
                flickLabel.isHidden = false
            }

        case let .symbol(s):
            mainLabel.text = s
            let isDigitRow = s.count == 1 && s.first?.isNumber == true && !spec.isUtility
            mainLabel.font = .systemFont(ofSize: isDigitRow ? 16 : 20, weight: isDigitRow ? .medium : .regular)
            mainLabel.textColor = theme.primaryInk
            backgroundColor = pressed ? theme.letterKeyPressed : theme.letterKeyFill

        case .shift:
            mainLabel.isHidden = true
            iconView.isHidden = false
            let symName: String
            switch shift {
            case .off: symName = "shift"
            case .once: symName = "shift.fill"
            case .capsLock: symName = "capslock.fill"
            }
            iconView.image = UIImage(systemName: symName)
            let active = shift != .off
            backgroundColor = pressed
                ? theme.utilityKeyPressed
                : (active ? theme.letterKeyFill : theme.utilityKeyFill)
            iconView.tintColor = shift == .capsLock ? theme.accentFill : theme.primaryInk

        case .backspace:
            mainLabel.isHidden = true
            iconView.isHidden = false
            iconView.image = UIImage(systemName: "delete.left")
            iconView.tintColor = theme.primaryInk
            backgroundColor = pressed ? theme.utilityKeyPressed : theme.utilityKeyFill

        case let .layer(_, title):
            mainLabel.text = title
            mainLabel.font = .systemFont(ofSize: 15, weight: .medium)
            mainLabel.textColor = theme.primaryInk
            backgroundColor = pressed ? theme.utilityKeyPressed : theme.utilityKeyFill

        case .globe:
            mainLabel.isHidden = true
            iconView.isHidden = false
            iconView.image = UIImage(systemName: "globe")
            iconView.tintColor = theme.primaryInk
            backgroundColor = pressed ? theme.utilityKeyPressed : theme.utilityKeyFill

        case .emoji:
            mainLabel.isHidden = true
            iconView.isHidden = false
            iconView.image = UIImage(systemName: "face.smiling")
            iconView.tintColor = theme.primaryInk
            backgroundColor = pressed ? theme.utilityKeyPressed : theme.utilityKeyFill

        case .space:
            mainLabel.text = trackpadActive ? "◀  trackpad  ▶" : "Spritz"
            mainLabel.font = .systemFont(ofSize: trackpadActive ? 13 : 14, weight: trackpadActive ? .medium : .regular)
            mainLabel.textColor = trackpadActive ? theme.accentFill : theme.secondaryInk
            backgroundColor = pressed ? theme.letterKeyPressed : theme.letterKeyFill

        case .returnKey:
            let (title, emphasized) = returnTitleAndEmphasis(returnType)
            if let title {
                mainLabel.text = title
                mainLabel.font = .systemFont(ofSize: 15, weight: emphasized ? .semibold : .medium)
                mainLabel.textColor = emphasized ? theme.accentInk : theme.primaryInk
                backgroundColor = emphasized
                    ? (pressed ? theme.accentFill.withAlphaComponent(0.8) : theme.accentFill)
                    : (pressed ? theme.utilityKeyPressed : theme.utilityKeyFill)
            } else {
                mainLabel.isHidden = true
                iconView.isHidden = false
                iconView.image = UIImage(systemName: "return")
                iconView.tintColor = theme.primaryInk
                backgroundColor = pressed ? theme.utilityKeyPressed : theme.utilityKeyFill
            }
        }

        if wasLower != isLowercaseLetter {
            setNeedsLayout()
        }
    }

    private func returnTitleAndEmphasis(_ type: UIReturnKeyType) -> (String?, Bool) {
        switch type {
        case .go: return ("go", true)
        case .search, .google, .yahoo: return ("search", true)
        case .send: return ("send", true)
        case .done: return ("done", true)
        case .next: return ("next", true)
        case .join: return ("join", true)
        case .route: return ("route", true)
        case .continue: return ("continue", true)
        default: return (nil, false)
        }
    }
}

private final class KeyPopupView: UIView {
    private let label = UILabel()
    private var optionButtons: [UILabel] = []
    private var selectedOptionIndex = 0
    private var options: [String] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.cornerRadius = 8
        layer.borderWidth = 1
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.24
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)

        label.font = .systemFont(ofSize: 30, weight: .regular)
        label.textAlignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSingle(_ text: String, over keyFrame: CGRect, in containerBounds: CGRect, theme: KeyboardTheme) {
        options = []
        clearOptionViews()
        label.isHidden = false
        label.text = text
        label.textColor = theme.primaryInk
        backgroundColor = theme.popupFill
        layer.borderColor = theme.popupBorder.cgColor

        let w = max(keyFrame.width + 14, 44)
        let h: CGFloat = 52
        let x = min(max(keyFrame.midX - w * 0.5, 4), containerBounds.width - w - 4)
        let y = max(-InstrumentBarView.height + 2, keyFrame.minY - h - 4)
        frame = CGRect(x: x, y: y, width: w, height: h)
        label.frame = bounds
        isHidden = false
    }

    func showOptions(_ list: [String], over keyFrame: CGRect, in containerBounds: CGRect, theme: KeyboardTheme) {
        options = list
        selectedOptionIndex = 0
        label.isHidden = true
        clearOptionViews()
        backgroundColor = theme.popupFill
        layer.borderColor = theme.popupBorder.cgColor

        let itemW: CGFloat = 34
        let pad: CGFloat = 4
        let totalW = CGFloat(list.count) * itemW + pad * 2
        let h: CGFloat = 46
        let x = min(max(keyFrame.midX - totalW * 0.5, 4), containerBounds.width - totalW - 4)
        let y = max(-InstrumentBarView.height + 2, keyFrame.minY - h - 4)
        frame = CGRect(x: x, y: y, width: totalW, height: h)

        for (i, txt) in list.enumerated() {
            let lbl = UILabel(frame: CGRect(x: pad + CGFloat(i) * itemW, y: 4, width: itemW, height: h - 8))
            lbl.text = txt
            lbl.textAlignment = .center
            lbl.font = .systemFont(ofSize: 20, weight: .regular)
            lbl.layer.cornerRadius = 6
            lbl.layer.masksToBounds = true
            addSubview(lbl)
            optionButtons.append(lbl)
        }
        highlightOption(at: 0, theme: theme)
        isHidden = false
    }

    func updateOptionSelection(touchX: CGFloat, theme: KeyboardTheme) -> String? {
        guard !options.isEmpty, !optionButtons.isEmpty else { return nil }
        let localX = touchX - frame.minX - 4
        let idx = min(max(0, Int(localX / 34.0)), options.count - 1)
        if idx != selectedOptionIndex {
            highlightOption(at: idx, theme: theme)
        }
        return options[selectedOptionIndex]
    }

    var currentSelectedOption: String? {
        guard selectedOptionIndex >= 0, selectedOptionIndex < options.count else { return nil }
        return options[selectedOptionIndex]
    }

    private func highlightOption(at idx: Int, theme: KeyboardTheme) {
        selectedOptionIndex = idx
        for (i, lbl) in optionButtons.enumerated() {
            if i == idx {
                lbl.backgroundColor = theme.accentFill
                lbl.textColor = theme.accentInk
            } else {
                lbl.backgroundColor = .clear
                lbl.textColor = theme.primaryInk
            }
        }
    }

    private func clearOptionViews() {
        for v in optionButtons { v.removeFromSuperview() }
        optionButtons.removeAll()
    }
}

@MainActor
final class KeyboardDeckView: UIView, UIInputViewAudioFeedback {
    var onTapCharacter: ((_ text: String, _ normPoint: CGPoint) -> Void)?
    var onDirectInsert: ((_ text: String) -> Void)?
    var onSpace: (() -> Void)?
    var onReturn: (() -> Void)?
    var onBackspace: (() -> Void)?
    var onSwipeDeleteWord: (() -> Void)?
    var onShiftChanged: ((ShiftStateDTO) -> Void)?
    var onGlideComplete: ((_ normPoints: [CGPoint]) -> Void)?
    var onTrackpadMove: ((_ charOffset: Int) -> Void)?
    var onRequestEmoji: (() -> Void)?
    var onGlobePress: ((_ view: UIView, _ event: UIEvent) -> Void)?
    var onLayerChanged: ((DeckLayer) -> Void)?

    var enableInputClicksWhenVisible: Bool { true }

    private(set) var layerKind: DeckLayer = .letters
    private var theme = KeyboardTheme.resolved(dark: false)
    private var showNumberRow = true
    private var showFlicks = true
    private var glideEnabled = true
    private var hapticsEnabled = true
    private var needsGlobe = true
    private var shiftState: ShiftStateDTO = .off
    private var returnKeyType: UIReturnKeyType = .default
    private var likelyNextSet: Set<String> = []

    private var rows: [[KeyTileView]] = []
    private var letterAreaFrame: CGRect = .zero

    private let popupView = KeyPopupView()
    private let glideLayer = CAShapeLayer()
    private let impactFeedback = UIImpactFeedbackGenerator(style: .light)
    private let selectionFeedback = UISelectionFeedbackGenerator()

    // Touch state
    private weak var activeTouch: UITouch?
    private weak var startTile: KeyTileView?
    private var startPoint: CGPoint = .zero
    private var touchStartTime: TimeInterval = 0
    private weak var shiftHoldTouch: UITouch?
    private var shiftBeforeTouch: ShiftStateDTO = .off
    private var shiftHoldTypedAny = false
    private var didCapsLockOnHold = false
    private var isFlicking = false
    private var isGliding = false
    private var isTrackpad = false
    private var trackpadAccumX: CGFloat = 0
    private var glidePoints: [CGPoint] = []
    private var glideDisplayPoints: [CGPoint] = []
    private var visitedLetters: Set<String> = []
    private var longPressTimer: Timer?
    private var shiftLongPressTimer: Timer?
    private var backspaceRepeatTimer: Timer?
    private var didRepeatBackspace = false
    private var swipeDeleteTriggered = false
    private var swipeDeleteLastX: CGFloat = 0
    private var lastShiftTapTime: TimeInterval = 0

    private static let accents: [String: [String]] = [
        "a": ["a", "à", "á", "â", "ä", "æ", "ã", "å"],
        "c": ["c", "ç", "ć", "č"],
        "e": ["e", "é", "è", "ê", "ë", "ē", "€"],
        "i": ["i", "í", "ì", "î", "ï", "ī"],
        "n": ["n", "ñ", "ń"],
        "o": ["o", "ó", "ò", "ô", "ö", "œ", "ø"],
        "s": ["s", "ß", "ś", "š"],
        "u": ["u", "ú", "ù", "û", "ü", "ū"],
        "y": ["y", "ÿ"],
        ".": [".", ",", "?", "!", "…", "'", ".com", ".au"],
        "-": ["-", "–", "—", "•"],
        "$": ["$", "€", "£", "¥", "¢"],
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        clipsToBounds = false

        glideLayer.fillColor = UIColor.clear.cgColor
        glideLayer.lineWidth = 4.5
        glideLayer.lineCap = .round
        glideLayer.lineJoin = .round
        layer.addSublayer(glideLayer)

        popupView.isHidden = true
        addSubview(popupView)

        rebuildTiles()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setLikelyNextChars(_ chars: String) {
        if chars.isEmpty {
            likelyNextSet.removeAll()
        } else {
            likelyNextSet = Set(chars.lowercased().map { String($0) })
        }
    }

    func setConfiguration(
        layerKind: DeckLayer? = nil,
        showNumberRow: Bool? = nil,
        showFlicks: Bool? = nil,
        glideEnabled: Bool? = nil,
        hapticsEnabled: Bool? = nil,
        needsGlobe: Bool? = nil,
        shiftState: ShiftStateDTO? = nil,
        returnKeyType: UIReturnKeyType? = nil
    ) {
        var needsRebuild = false
        if let l = layerKind, l != self.layerKind {
            self.layerKind = l
            needsRebuild = true
        }
        if let n = showNumberRow, n != self.showNumberRow {
            self.showNumberRow = n
            needsRebuild = true
        }
        if let f = showFlicks { self.showFlicks = f }
        if let g = glideEnabled { self.glideEnabled = g }
        if let h = hapticsEnabled { self.hapticsEnabled = h }
        if let gl = needsGlobe, gl != self.needsGlobe {
            self.needsGlobe = gl
            needsRebuild = true
        }
        if let s = shiftState {
            self.shiftState = (shiftHoldTouch != nil && s == .off) ? .once : s
        }
        if let r = returnKeyType { self.returnKeyType = r }

        if needsRebuild {
            rebuildTiles()
        } else {
            refreshAllTiles()
        }
    }

    func applyTheme(_ theme: KeyboardTheme) {
        self.theme = theme
        backgroundColor = theme.deckBackground
        glideLayer.strokeColor = theme.glideTrail.cgColor
        refreshAllTiles()
    }

    private func rebuildTiles() {
        for row in rows {
            for tile in row { tile.removeFromSuperview() }
        }
        rows.removeAll()

        let specsRows = buildRowSpecs()
        for rSpecs in specsRows {
            var rowViews: [KeyTileView] = []
            for spec in rSpecs {
                let tv = KeyTileView(spec: spec)
                addSubview(tv)
                rowViews.append(tv)
            }
            rows.append(rowViews)
        }
        bringSubviewToFront(popupView)
        refreshAllTiles()
        setNeedsLayout()
    }

    private func refreshAllTiles() {
        for row in rows {
            for tile in row {
                let isShiftHeld = (tile.spec.action == .shift && shiftHoldTouch != nil)
                let isPressed = isShiftHeld || (tile === startTile && !isGliding && !isTrackpad)
                tile.configure(
                    theme: theme,
                    shift: shiftState,
                    showFlicks: showFlicks,
                    returnType: returnKeyType,
                    pressed: isPressed,
                    trackpadActive: isTrackpad
                )
            }
        }
    }

    private func buildRowSpecs() -> [[KeySpec]] {
        switch layerKind {
        case .letters:
            var list: [[KeySpec]] = []
            if showNumberRow {
                list.append(["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"].map {
                    KeySpec(action: .symbol($0), weight: 1.0, isUtility: false)
                })
            }
            let r1: [(String, String)] = [
                ("q", "!"), ("w", "@"), ("e", "#"), ("r", "$"), ("t", "%"),
                ("y", "^"), ("u", "&"), ("i", "*"), ("o", "("), ("p", ")"),
            ]
            list.append(r1.map {
                KeySpec(action: .char(lower: $0.0, upper: $0.0.uppercased(), flick: $0.1), weight: 1.0, isUtility: false)
            })
            let r2: [(String, String)] = [
                ("a", "-"), ("s", "_"), ("d", "="), ("f", "+"), ("g", "["),
                ("h", "]"), ("j", "/"), ("k", ":"), ("l", ";"),
            ]
            list.append(r2.map {
                KeySpec(action: .char(lower: $0.0, upper: $0.0.uppercased(), flick: $0.1), weight: 1.0, isUtility: false)
            })
            let r3Chars: [(String, String)] = [
                ("z", "'"), ("x", "\""), ("c", "<"), ("v", ">"),
                ("b", "\\"), ("n", "~"), ("m", "?"),
            ]
            var row3: [KeySpec] = [KeySpec(action: .shift, weight: 1.35, isUtility: true)]
            row3.append(contentsOf: r3Chars.map {
                KeySpec(action: .char(lower: $0.0, upper: $0.0.uppercased(), flick: $0.1), weight: 1.0, isUtility: false)
            })
            row3.append(KeySpec(action: .backspace, weight: 1.35, isUtility: true))
            list.append(row3)
            list.append(bottomUtilityRow(leftLayer: .numbers, leftTitle: "123"))
            return list

        case .numbers:
            var list: [[KeySpec]] = []
            list.append(["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"].map {
                KeySpec(action: .symbol($0), weight: 1.0, isUtility: false)
            })
            list.append(["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""].map {
                KeySpec(action: .symbol($0), weight: 1.0, isUtility: false)
            })
            var r3: [KeySpec] = [KeySpec(action: .layer(.symbols, title: "#+="), weight: 1.35, isUtility: true)]
            r3.append(contentsOf: [".", ",", "?", "!", "'"].map {
                KeySpec(action: .symbol($0), weight: 1.15, isUtility: false)
            })
            r3.append(KeySpec(action: .backspace, weight: 1.35, isUtility: true))
            list.append(r3)
            list.append(bottomUtilityRow(leftLayer: .letters, leftTitle: "ABC"))
            return list

        case .symbols:
            var list: [[KeySpec]] = []
            list.append(["[", "]", "{", "}", "#", "%", "^", "*", "+", "="].map {
                KeySpec(action: .symbol($0), weight: 1.0, isUtility: false)
            })
            list.append(["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"].map {
                KeySpec(action: .symbol($0), weight: 1.0, isUtility: false)
            })
            var r3: [KeySpec] = [KeySpec(action: .layer(.numbers, title: "123"), weight: 1.35, isUtility: true)]
            r3.append(contentsOf: [".", ",", "?", "!", "'"].map {
                KeySpec(action: .symbol($0), weight: 1.15, isUtility: false)
            })
            r3.append(KeySpec(action: .backspace, weight: 1.35, isUtility: true))
            list.append(r3)
            list.append(bottomUtilityRow(leftLayer: .letters, leftTitle: "ABC"))
            return list
        }
    }

    private func bottomUtilityRow(leftLayer: DeckLayer, leftTitle: String) -> [KeySpec] {
        var row: [KeySpec] = [
            KeySpec(action: .layer(leftLayer, title: leftTitle), weight: 1.35, isUtility: true),
        ]
        if needsGlobe {
            row.append(KeySpec(action: .globe, weight: 0.95, isUtility: true))
        }
        row.append(KeySpec(action: .emoji, weight: 0.95, isUtility: true))
        row.append(KeySpec(action: .symbol(","), weight: 0.78, isUtility: false))
        row.append(KeySpec(action: .space, weight: needsGlobe ? 4.15 : 5.05, isUtility: false))
        row.append(KeySpec(action: .symbol("."), weight: 0.78, isUtility: false))
        row.append(KeySpec(action: .returnKey, weight: 1.90, isUtility: true))
        return row
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 20, bounds.height > 40, !rows.isEmpty else { return }

        let sideMargin: CGFloat = 3.5
        let keyGap: CGFloat = 5.0
        let topPad: CGFloat = 6.0
        let bottomPad: CGFloat = 6.0
        let rowCount = rows.count
        let rowGap: CGFloat = rowCount >= 5 ? 5.0 : 6.0

        let usableW = bounds.width - sideMargin * 2
        let usableH = bounds.height - topPad - bottomPad - rowGap * CGFloat(rowCount - 1)

        var rowHeights: [CGFloat]
        if rowCount == 5 {
            let numH: CGFloat = 30
            let otherH = (usableH - numH) / 4.0
            rowHeights = [numH, otherH, otherH, otherH, otherH]
        } else {
            let each = usableH / CGFloat(rowCount)
            rowHeights = Array(repeating: each, count: rowCount)
        }

        var curY = topPad
        var qRowFrame: CGRect?
        var zRowFrame: CGRect?

        for (rIdx, row) in rows.enumerated() {
            let rh = rowHeights[rIdx]
            let isMiddleLetters = layerKind == .letters && ((rowCount == 5 && rIdx == 2) || (rowCount == 4 && rIdx == 1))
            let rowSideInset: CGFloat = isMiddleLetters ? usableW * 0.05 : 0
            let rowW = usableW - rowSideInset * 2
            var totalWeight: CGFloat = 0
            for tile in row { totalWeight += tile.spec.weight }
            let gapsW = keyGap * CGFloat(max(0, row.count - 1))
            let unitW = (rowW - gapsW) / max(1, totalWeight)

            var curX = sideMargin + rowSideInset
            for tile in row {
                let w = tile.spec.weight * unitW
                tile.frame = CGRect(x: curX, y: curY, width: w, height: rh)
                curX += w + keyGap
            }

            if layerKind == .letters {
                let letterTopIdx = rowCount == 5 ? 1 : 0
                let letterBotIdx = rowCount == 5 ? 3 : 2
                if rIdx == letterTopIdx { qRowFrame = CGRect(x: sideMargin, y: curY, width: usableW, height: rh) }
                if rIdx == letterBotIdx { zRowFrame = CGRect(x: sideMargin, y: curY, width: usableW, height: rh) }
            }

            curY += rh + rowGap
        }

        if let qf = qRowFrame, let zf = zRowFrame {
            letterAreaFrame = CGRect(
                x: qf.minX,
                y: qf.minY,
                width: qf.width,
                height: zf.maxY - qf.minY
            )
        } else {
            letterAreaFrame = bounds
        }
    }

    private func tile(at point: CGPoint, applyBias: Bool = true) -> KeyTileView? {
        guard !rows.isEmpty, bounds.insetBy(dx: -8, dy: -8).contains(point) else { return nil }
        var bestTile: KeyTileView?
        var bestScore = CGFloat.greatestFiniteMagnitude
        for row in rows {
            for tv in row {
                let f = tv.frame
                if f.isEmpty { continue }
                let dx = point.x < f.minX ? (f.minX - point.x) : (point.x > f.maxX ? (point.x - f.maxX) : 0)
                let dy = point.y < f.minY ? (f.minY - point.y) : (point.y > f.maxY ? (point.y - f.maxY) : 0)
                var dist = hypot(dx, dy * 1.45)
                if applyBias,
                   case let .char(lower, _, _) = tv.spec.action,
                   likelyNextSet.contains(lower),
                   dist > 0, dist <= 5.5 {
                    dist = max(0.01, dist - 2.5)
                }
                if dist < bestScore {
                    bestScore = dist
                    bestTile = tv
                }
            }
        }
        return bestTile
    }

    private func normalizedPoint(_ pt: CGPoint) -> CGPoint {
        guard letterAreaFrame.width > 1, letterAreaFrame.height > 1 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        let nx = min(max(0.0, (pt.x - letterAreaFrame.minX) / letterAreaFrame.width), 1.0)
        let ny = min(max(0.0, (pt.y - letterAreaFrame.minY) / letterAreaFrame.height), 1.0)
        return CGPoint(x: nx, y: ny)
    }

    private func triggerLightHaptic() {
        guard hapticsEnabled else { return }
        impactFeedback.impactOccurred(intensity: 0.65)
    }

    private func clearTimers() {
        longPressTimer?.invalidate()
        longPressTimer = nil
        backspaceRepeatTimer?.invalidate()
        backspaceRepeatTimer = nil
    }

    private func clearAllTimers() {
        clearTimers()
        shiftLongPressTimer?.invalidate()
        shiftLongPressTimer = nil
    }

    private func resetActiveTouchState() {
        clearTimers()
        activeTouch = nil
        startTile = nil
        isFlicking = false
        isGliding = false
        isTrackpad = false
        swipeDeleteTriggered = false
        swipeDeleteLastX = 0
        glidePoints.removeAll()
        glideDisplayPoints.removeAll()
        visitedLetters.removeAll()
        glideLayer.path = nil
        popupView.isHidden = true
        refreshAllTiles()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        impactFeedback.prepare()
        for touch in touches {
            let pt = touch.location(in: self)
            guard let tv = tile(at: pt, applyBias: true) else { continue }

            if tv.spec.action == .shift && shiftHoldTouch == nil {
                shiftHoldTouch = touch
                shiftBeforeTouch = shiftState
                shiftHoldTypedAny = false
                didCapsLockOnHold = false
                if shiftState == .off {
                    shiftState = .once
                    onShiftChanged?(.once)
                }
                triggerLightHaptic()
                UIDevice.current.playInputClick()
                startShiftLongPressTimer()
                refreshAllTiles()
                continue
            }

            if let prev = startTile, activeTouch != nil, prev !== tv {
                // Fast two-thumb rollover: commit previous tap cleanly with its real touch point.
                let prevPoint = startPoint
                commitActiveKey(startPoint: prevPoint, event: event)
                resetActiveTouchState()
            }

            if shiftHoldTouch != nil {
                shiftHoldTypedAny = true
                shiftLongPressTimer?.invalidate()
                shiftLongPressTimer = nil
            }

            activeTouch = touch
            startTile = tv
            startPoint = pt
            touchStartTime = touch.timestamp
            isFlicking = false
            isGliding = false
            isTrackpad = false
            trackpadAccumX = 0
            didRepeatBackspace = false
            swipeDeleteTriggered = false
            swipeDeleteLastX = pt.x
            glidePoints = [normalizedPoint(pt)]
            glideDisplayPoints = [pt]
            visitedLetters.removeAll()

            if case let .char(lower, _, _) = tv.spec.action {
                visitedLetters.insert(lower)
            }

            triggerLightHaptic()
            UIDevice.current.playInputClick()
            refreshAllTiles()

            switch tv.spec.action {
            case let .char(lower, upper, _):
                let shown = shiftState == .off ? lower : upper
                popupView.showSingle(shown, over: tv.frame, in: bounds, theme: theme)
                startLongPressTimer(for: tv)
            case let .symbol(s):
                popupView.showSingle(s, over: tv.frame, in: bounds, theme: theme)
                startLongPressTimer(for: tv)
            case .backspace:
                backspaceRepeatTimer = Timer.scheduledTimer(withTimeInterval: 0.38, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        self?.beginBackspaceRepeat()
                    }
                }
            case .globe:
                if let event {
                    onGlobePress?(tv, event)
                }
                resetActiveTouchState()
            default:
                break
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch), let tv = startTile else { return }
        let pt = touch.location(in: self)
        let dx = pt.x - startPoint.x
        let dy = pt.y - startPoint.y
        let elapsed = touch.timestamp - touchStartTime

        if !popupView.isHidden && popupView.currentSelectedOption != nil && longPressTimer == nil {
            _ = popupView.updateOptionSelection(touchX: pt.x, theme: theme)
            return
        }

        switch tv.spec.action {
        case .space:
            if !isTrackpad && ((elapsed >= 0.22 && abs(dx) >= 8) || (abs(dx) >= 26 && elapsed >= 0.08 && abs(dx) > abs(dy) * 1.6)) {
                isTrackpad = true
                clearTimers()
                popupView.isHidden = true
                trackpadAccumX = pt.x
                selectionFeedback.prepare()
                refreshAllTiles()
            }
            if isTrackpad {
                let delta = pt.x - trackpadAccumX
                let step: CGFloat = 9.0
                if abs(delta) >= step {
                    let chars = Int(delta / step)
                    trackpadAccumX += CGFloat(chars) * step
                    if hapticsEnabled { selectionFeedback.selectionChanged() }
                    onTrackpadMove?(chars)
                }
            }

        case .backspace:
            if !swipeDeleteTriggered && dx <= -30 && abs(dx) > abs(dy) * 1.6 {
                swipeDeleteTriggered = true
                swipeDeleteLastX = pt.x
                clearTimers()
                triggerLightHaptic()
                onSwipeDeleteWord?()
            } else if swipeDeleteTriggered && (swipeDeleteLastX - pt.x) >= 44 {
                swipeDeleteLastX = pt.x
                triggerLightHaptic()
                onSwipeDeleteWord?()
            }

        case let .char(lower, upper, flick):
            if let flick, showFlicks, !isGliding, dy >= 28, dy > abs(dx) * 1.65 {
                if !isFlicking {
                    isFlicking = true
                    longPressTimer?.invalidate()
                    longPressTimer = nil
                    triggerLightHaptic()
                }
                popupView.showSingle(flick, over: tv.frame, in: bounds, theme: theme)
                return
            }
            if isFlicking && dy < 20 {
                isFlicking = false
                let shown = shiftState == .off ? lower : upper
                popupView.showSingle(shown, over: tv.frame, in: bounds, theme: theme)
            }

            guard glideEnabled, layerKind == .letters, !isFlicking else { return }
            if let hit = tile(at: pt, applyBias: false),
               hit.frame.insetBy(dx: 3, dy: 3).contains(pt),
               case let .char(hl, _, _) = hit.spec.action {
                visitedLetters.insert(hl)
            }
            if !isGliding && hypot(dx, dy) >= 34 && elapsed >= 0.065 && visitedLetters.count >= 2 {
                isGliding = true
                longPressTimer?.invalidate()
                longPressTimer = nil
                popupView.isHidden = true
                refreshAllTiles()
            }
            if isGliding {
                glidePoints.append(normalizedPoint(pt))
                glideDisplayPoints.append(pt)
                renderGlideTrail()
            }

        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = activeTouch, touches.contains(touch) {
            let committedStart = startPoint
            commitActiveKey(startPoint: committedStart, event: event)
            resetActiveTouchState()
        }

        if let sh = shiftHoldTouch, touches.contains(sh) {
            shiftLongPressTimer?.invalidate()
            shiftLongPressTimer = nil
            if didCapsLockOnHold {
                shiftState = .capsLock
            } else if shiftHoldTypedAny {
                shiftState = .off
            } else {
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastShiftTapTime < 0.32 && shiftBeforeTouch != .capsLock {
                    shiftState = .capsLock
                } else if shiftBeforeTouch == .off {
                    shiftState = .once
                } else {
                    shiftState = .off
                }
                lastShiftTapTime = now
            }
            shiftHoldTouch = nil
            shiftHoldTypedAny = false
            didCapsLockOnHold = false
            onShiftChanged?(shiftState)
            refreshAllTiles()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = activeTouch, touches.contains(touch) {
            resetActiveTouchState()
        }
        if let sh = shiftHoldTouch, touches.contains(sh) {
            shiftLongPressTimer?.invalidate()
            shiftLongPressTimer = nil
            shiftState = shiftBeforeTouch
            shiftHoldTouch = nil
            shiftHoldTypedAny = false
            didCapsLockOnHold = false
            onShiftChanged?(shiftState)
            refreshAllTiles()
        }
    }

    private func commitActiveKey(startPoint: CGPoint, event: UIEvent?) {
        guard let tv = startTile else { return }

        if isTrackpad || swipeDeleteTriggered {
            return
        }

        if isGliding {
            if glidePoints.count >= 2 {
                onGlideComplete?(glidePoints)
            }
            if shiftHoldTouch != nil {
                shiftHoldTypedAny = true
                shiftState = .once
                onShiftChanged?(.once)
            }
            return
        }

        if let alt = popupView.currentSelectedOption, !popupView.isHidden, longPressTimer == nil {
            onDirectInsert?(alt)
            return
        }

        switch tv.spec.action {
        case let .char(lower, upper, flick):
            if isFlicking, let flick {
                onDirectInsert?(flick)
            } else {
                let text = shiftState == .off ? lower : upper
                onTapCharacter?(text, normalizedPoint(startPoint))
            }
            if shiftHoldTouch != nil {
                shiftHoldTypedAny = true
                shiftState = .once
                onShiftChanged?(.once)
            }

        case let .symbol(s):
            onDirectInsert?(s)

        case .shift:
            break

        case .backspace:
            if !didRepeatBackspace {
                onBackspace?()
            }

        case let .layer(nextLayer, _):
            setConfiguration(layerKind: nextLayer)
            onLayerChanged?(nextLayer)

        case .emoji:
            onRequestEmoji?()

        case .space:
            onSpace?()
            if layerKind == .numbers || layerKind == .symbols {
                setConfiguration(layerKind: .letters)
                onLayerChanged?(.letters)
            }

        case .returnKey:
            onReturn?()

        case .globe:
            break
        }
    }

    private func startShiftLongPressTimer() {
        shiftLongPressTimer?.invalidate()
        shiftLongPressTimer = Timer.scheduledTimer(withTimeInterval: 0.36, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.shiftHoldTouch != nil, !self.shiftHoldTypedAny else { return }
                self.didCapsLockOnHold = true
                self.shiftState = .capsLock
                self.onShiftChanged?(.capsLock)
                self.triggerLightHaptic()
                self.refreshAllTiles()
                self.shiftLongPressTimer = nil
            }
        }
    }

    private func startLongPressTimer(for tile: KeyTileView) {
        longPressTimer?.invalidate()
        longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.36, repeats: false) { [weak self, weak tile] _ in
            Task { @MainActor in
                guard let self, let tile, self.startTile === tile, !self.isGliding, !self.isFlicking else { return }
                switch tile.spec.action {
                case let .char(lower, _, _):
                    if let list = Self.accents[lower] {
                        let cased = self.shiftState == .off ? list : list.map { $0.uppercased() }
                        self.triggerLightHaptic()
                        self.popupView.showOptions(cased, over: tile.frame, in: self.bounds, theme: self.theme)
                    }
                case let .symbol(s):
                    if let list = Self.accents[s] {
                        self.triggerLightHaptic()
                        self.popupView.showOptions(list, over: tile.frame, in: self.bounds, theme: self.theme)
                    }
                default:
                    break
                }
                self.longPressTimer = nil
            }
        }
    }

    private func beginBackspaceRepeat() {
        backspaceRepeatTimer?.invalidate()
        guard startTile?.spec.action == .backspace, !swipeDeleteTriggered else { return }
        didRepeatBackspace = true
        onBackspace?()
        backspaceRepeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.startTile?.spec.action == .backspace, !self.swipeDeleteTriggered else { return }
                self.didRepeatBackspace = true
                self.onBackspace?()
            }
        }
    }

    private func renderGlideTrail() {
        guard glideDisplayPoints.count >= 2 else {
            glideLayer.path = nil
            return
        }
        let recent = Array(glideDisplayPoints.suffix(28))
        let path = UIBezierPath()
        path.move(to: recent[0])
        for p in recent.dropFirst() {
            path.addLine(to: p)
        }
        glideLayer.path = path.cgPath
    }
}
