import UIKit

private final class EmojiGridCell: UICollectionViewCell {
    static let reuseID = "EmojiGridCell"
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 28)
        label.textAlignment = .center
        contentView.addSubview(label)
        contentView.layer.cornerRadius = 8
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = contentView.bounds
    }

    func configure(_ item: EmojiItemDTO) {
        label.text = item.glyph
        accessibilityLabel = item.label
    }
}

@MainActor
final class EmojiDeckView: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    var onPickEmoji: ((EmojiItemDTO) -> Void)?
    var onReturnABC: (() -> Void)?
    var onBackspace: (() -> Void)?
    var onRequestSearch: (() -> Void)?
    var onSelectMode: ((String) -> Void)?

    private var theme = KeyboardTheme.resolved(dark: false)
    private var snapshot: EmojiSnapshotDTO?

    private let modeStrip = UIStackView()
    private var modeButtons: [UIButton] = []
    private let searchButton = UIButton(type: .system)

    private let collectionView: UICollectionView
    private let footerRow = UIStackView()
    private let abcButton = UIButton(type: .system)
    private let categoryScroll = UIScrollView()
    private let categoryStack = UIStackView()
    private var categoryButtons: [UIButton] = []
    private let deleteButton = UIButton(type: .system)

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing = 4
        layout.sectionInset = UIEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        setupUI()
        applyTheme(theme)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        modeStrip.translatesAutoresizingMaskIntoConstraints = false
        modeStrip.axis = .horizontal
        modeStrip.alignment = .center
        modeStrip.spacing = 4
        addSubview(modeStrip)

        searchButton.setImage(UIImage(systemName: "magnifyingglass"), for: .normal)
        searchButton.setPreferredSymbolConfiguration(.init(pointSize: 13.5, weight: .medium), forImageIn: .normal)
        searchButton.setTitle(" Search", for: .normal)
        searchButton.titleLabel?.font = .systemFont(ofSize: 12.5, weight: .medium)
        searchButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 9, bottom: 0, right: 9)
        searchButton.layer.cornerRadius = 6
        searchButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        searchButton.setContentHuggingPriority(.required, for: .horizontal)
        searchButton.addTarget(self, action: #selector(handleSearchTap), for: .touchUpInside)

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(EmojiGridCell.self, forCellWithReuseIdentifier: EmojiGridCell.reuseID)
        addSubview(collectionView)

        footerRow.translatesAutoresizingMaskIntoConstraints = false
        footerRow.axis = .horizontal
        footerRow.alignment = .center
        footerRow.spacing = 4
        addSubview(footerRow)

        abcButton.setTitle("ABC", for: .normal)
        abcButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        abcButton.layer.cornerRadius = 6.5
        abcButton.widthAnchor.constraint(equalToConstant: 48).isActive = true
        abcButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        abcButton.addTarget(self, action: #selector(handleABCTap), for: .touchUpInside)

        categoryScroll.showsHorizontalScrollIndicator = false
        categoryStack.translatesAutoresizingMaskIntoConstraints = false
        categoryStack.axis = .horizontal
        categoryStack.spacing = 4
        categoryScroll.addSubview(categoryStack)
        NSLayoutConstraint.activate([
            categoryStack.leadingAnchor.constraint(equalTo: categoryScroll.leadingAnchor),
            categoryStack.trailingAnchor.constraint(equalTo: categoryScroll.trailingAnchor),
            categoryStack.topAnchor.constraint(equalTo: categoryScroll.topAnchor),
            categoryStack.bottomAnchor.constraint(equalTo: categoryScroll.bottomAnchor),
            categoryStack.heightAnchor.constraint(equalTo: categoryScroll.heightAnchor),
        ])

        deleteButton.setImage(UIImage(systemName: "delete.left"), for: .normal)
        deleteButton.setPreferredSymbolConfiguration(.init(pointSize: 15, weight: .medium), forImageIn: .normal)
        deleteButton.layer.cornerRadius = 6.5
        deleteButton.widthAnchor.constraint(equalToConstant: 46).isActive = true
        deleteButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        deleteButton.addTarget(self, action: #selector(handleDeleteTap), for: .touchUpInside)

        footerRow.addArrangedSubview(abcButton)
        footerRow.addArrangedSubview(categoryScroll)
        footerRow.addArrangedSubview(deleteButton)

        NSLayoutConstraint.activate([
            modeStrip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            modeStrip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            modeStrip.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            modeStrip.heightAnchor.constraint(equalToConstant: 28),

            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: modeStrip.bottomAnchor, constant: 2),
            collectionView.bottomAnchor.constraint(equalTo: footerRow.topAnchor, constant: -2),

            footerRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            footerRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            footerRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            footerRow.heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    func applyTheme(_ theme: KeyboardTheme) {
        self.theme = theme
        backgroundColor = theme.deckBackground
        abcButton.backgroundColor = theme.utilityKeyFill
        abcButton.setTitleColor(theme.primaryInk, for: .normal)
        deleteButton.backgroundColor = theme.utilityKeyFill
        deleteButton.tintColor = theme.primaryInk
        searchButton.backgroundColor = theme.utilityKeyFill
        searchButton.tintColor = theme.primaryInk
        searchButton.setTitleColor(theme.primaryInk, for: .normal)
        refreshBars()
    }

    func update(snapshot: EmojiSnapshotDTO) {
        self.snapshot = snapshot
        refreshBars()
        collectionView.reloadData()
    }

    private func refreshBars() {
        guard let snap = snapshot else { return }

        for v in modeStrip.arrangedSubviews { v.removeFromSuperview() }
        modeButtons.removeAll()

        let modesContainer = UIStackView()
        modesContainer.axis = .horizontal
        modesContainer.distribution = .fillEqually
        modesContainer.spacing = 4

        for m in snap.availableModes {
            let btn = UIButton(type: .system)
            btn.setTitle(Self.modeTitle(m), for: .normal)
            btn.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
            btn.layer.cornerRadius = 6
            btn.heightAnchor.constraint(equalToConstant: 26).isActive = true
            let selected = m == snap.mode
            btn.backgroundColor = selected ? theme.letterKeyFill : theme.utilityKeyFill.withAlphaComponent(0.6)
            btn.setTitleColor(theme.primaryInk, for: .normal)
            btn.accessibilityIdentifier = m
            btn.addTarget(self, action: #selector(handleModeTap(_:)), for: .touchUpInside)
            modesContainer.addArrangedSubview(btn)
            modeButtons.append(btn)
        }

        modeStrip.addArrangedSubview(modesContainer)
        modeStrip.addArrangedSubview(searchButton)

        for v in categoryStack.arrangedSubviews { v.removeFromSuperview() }
        categoryButtons.removeAll()
        categoryScroll.isHidden = snap.sections.isEmpty
        for (i, sec) in snap.sections.enumerated() {
            let btn = UIButton(type: .system)
            btn.tag = i
            btn.setImage(UIImage(systemName: sec.symbol), for: .normal)
            btn.setPreferredSymbolConfiguration(.init(pointSize: 12.5, weight: .medium), forImageIn: .normal)
            btn.tintColor = theme.secondaryInk
            btn.layer.cornerRadius = 6
            btn.widthAnchor.constraint(equalToConstant: 30).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 26).isActive = true
            btn.accessibilityLabel = sec.title
            btn.addTarget(self, action: #selector(handleCategoryTap(_:)), for: .touchUpInside)
            categoryStack.addArrangedSubview(btn)
            categoryButtons.append(btn)
        }
    }

    private static func modeTitle(_ m: String) -> String {
        switch m {
        case "suggested": return "Suggested"
        case "pinned": return "Pinned"
        case "recent": return "Recent"
        case "all": return "All"
        default: return m
        }
    }

    @objc private func handleModeTap(_ sender: UIButton) {
        if let m = sender.accessibilityIdentifier {
            onSelectMode?(m)
        }
    }

    @objc private func handleSearchTap() {
        onRequestSearch?()
    }

    @objc private func handleABCTap() {
        onReturnABC?()
    }

    @objc private func handleDeleteTap() {
        onBackspace?()
    }

    @objc private func handleCategoryTap(_ sender: UIButton) {
        guard let snap = snapshot, sender.tag < snap.sections.count else { return }
        let start = snap.sections[sender.tag].startIndex
        guard start < snap.items.count else { return }
        collectionView.scrollToItem(at: IndexPath(item: start, section: 0), at: .top, animated: true)
    }

    // MARK: - UICollectionView

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        snapshot?.items.count ?? 0
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: EmojiGridCell.reuseID, for: indexPath) as! EmojiGridCell
        if let item = snapshot?.items[indexPath.item] {
            cell.configure(item)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = snapshot?.items[indexPath.item] else { return }
        onPickEmoji?(item)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let cols: CGFloat = 8
        let totalPad: CGFloat = 12 + (cols - 1) * 2
        let side = floor((collectionView.bounds.width - totalPad) / cols)
        return CGSize(width: max(32, side), height: 38)
    }
}
