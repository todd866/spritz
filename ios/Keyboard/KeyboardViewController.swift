import UIKit

@MainActor
final class KeyboardViewController: UIInputViewController {
    private let bridge = SpritzIosBridge()
    private lazy var proxyTarget = TextDocumentProxyTarget(controller: self)
    private var containerView: SpritzKeyboardContainerView?

    override func viewDidLoad() {
        super.viewDidLoad()

        let container = SpritzKeyboardContainerView(bridge: bridge, needsGlobe: needsInputModeSwitchKey)
        container.target = proxyTarget
        container.onGlobePress = { [weak self] sourceView, event in
            self?.handleInputModeList(from: sourceView, with: event)
        }
        view.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.topAnchor.constraint(equalTo: view.topAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.containerView = container
        applyAppearance()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        containerView?.reloadConfiguration(needsGlobe: needsInputModeSwitchKey)
        applyAppearance()
    }

    override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        containerView?.refreshContext()
        applyAppearance()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyAppearance()
    }

    private func applyAppearance() {
        let appearance = textDocumentProxy.keyboardAppearance
        let isDark: Bool
        switch appearance {
        case .dark:
            isDark = true
        case .light:
            isDark = false
        default:
            isDark = traitCollection.userInterfaceStyle == .dark
        }
        containerView?.updateAppearance(dark: isDark)
    }
}
