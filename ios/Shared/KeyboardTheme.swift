import UIKit

struct KeyboardTheme {
    let isDark: Bool
    let deckBackground: UIColor
    let barBackground: UIColor
    let letterKeyFill: UIColor
    let letterKeyPressed: UIColor
    let utilityKeyFill: UIColor
    let utilityKeyPressed: UIColor
    let keyBorder: UIColor
    let keyShadow: UIColor
    let primaryInk: UIColor
    let secondaryInk: UIColor
    let candidateHighlightFill: UIColor
    let hairline: UIColor
    let accentFill: UIColor
    let accentInk: UIColor
    let glideTrail: UIColor
    let popupFill: UIColor
    let popupBorder: UIColor

    static func resolved(dark: Bool) -> KeyboardTheme {
        if dark {
            return KeyboardTheme(
                isDark: true,
                deckBackground: UIColor(red: 0.078, green: 0.078, blue: 0.086, alpha: 1.0),
                barBackground: UIColor(red: 0.106, green: 0.106, blue: 0.118, alpha: 1.0),
                letterKeyFill: UIColor(red: 0.227, green: 0.227, blue: 0.243, alpha: 1.0),
                letterKeyPressed: UIColor(red: 0.329, green: 0.329, blue: 0.353, alpha: 1.0),
                utilityKeyFill: UIColor(red: 0.153, green: 0.153, blue: 0.169, alpha: 1.0),
                utilityKeyPressed: UIColor(red: 0.243, green: 0.243, blue: 0.267, alpha: 1.0),
                keyBorder: UIColor(white: 1.0, alpha: 0.09),
                keyShadow: UIColor(white: 0.0, alpha: 0.55),
                primaryInk: UIColor(red: 0.961, green: 0.961, blue: 0.969, alpha: 1.0),
                secondaryInk: UIColor(red: 0.620, green: 0.620, blue: 0.651, alpha: 1.0),
                candidateHighlightFill: UIColor(white: 1.0, alpha: 0.12),
                hairline: UIColor(white: 1.0, alpha: 0.09),
                accentFill: UIColor(red: 0.184, green: 0.486, blue: 0.965, alpha: 1.0),
                accentInk: .white,
                glideTrail: UIColor(red: 0.230, green: 0.540, blue: 0.980, alpha: 0.48),
                popupFill: UIColor(red: 0.290, green: 0.290, blue: 0.314, alpha: 1.0),
                popupBorder: UIColor(white: 1.0, alpha: 0.16)
            )
        } else {
            return KeyboardTheme(
                isDark: false,
                deckBackground: UIColor(red: 0.902, green: 0.894, blue: 0.875, alpha: 1.0),
                barBackground: UIColor(red: 0.925, green: 0.918, blue: 0.898, alpha: 1.0),
                letterKeyFill: .white,
                letterKeyPressed: UIColor(red: 0.859, green: 0.847, blue: 0.816, alpha: 1.0),
                utilityKeyFill: UIColor(red: 0.812, green: 0.796, blue: 0.757, alpha: 1.0),
                utilityKeyPressed: UIColor(red: 0.729, green: 0.710, blue: 0.663, alpha: 1.0),
                keyBorder: UIColor(white: 0.0, alpha: 0.08),
                keyShadow: UIColor(white: 0.0, alpha: 0.28),
                primaryInk: UIColor(red: 0.102, green: 0.098, blue: 0.090, alpha: 1.0),
                secondaryInk: UIColor(red: 0.400, green: 0.388, blue: 0.357, alpha: 1.0),
                candidateHighlightFill: UIColor(white: 0.0, alpha: 0.075),
                hairline: UIColor(white: 0.0, alpha: 0.09),
                accentFill: UIColor(red: 0.039, green: 0.400, blue: 0.761, alpha: 1.0),
                accentInk: .white,
                glideTrail: UIColor(red: 0.039, green: 0.400, blue: 0.761, alpha: 0.42),
                popupFill: .white,
                popupBorder: UIColor(white: 0.0, alpha: 0.14)
            )
        }
    }
}
