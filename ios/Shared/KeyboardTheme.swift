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
                deckBackground: UIColor(red: 0.086, green: 0.086, blue: 0.094, alpha: 1.0),
                barBackground: UIColor(red: 0.110, green: 0.110, blue: 0.122, alpha: 1.0),
                letterKeyFill: UIColor(red: 0.184, green: 0.184, blue: 0.198, alpha: 1.0),
                letterKeyPressed: UIColor(red: 0.290, green: 0.290, blue: 0.310, alpha: 1.0),
                utilityKeyFill: UIColor(red: 0.137, green: 0.137, blue: 0.150, alpha: 1.0),
                utilityKeyPressed: UIColor(red: 0.230, green: 0.230, blue: 0.250, alpha: 1.0),
                keyBorder: UIColor(white: 1.0, alpha: 0.08),
                keyShadow: UIColor(white: 0.0, alpha: 0.72),
                primaryInk: UIColor(red: 0.961, green: 0.961, blue: 0.969, alpha: 1.0),
                secondaryInk: UIColor(red: 0.620, green: 0.620, blue: 0.650, alpha: 1.0),
                candidateHighlightFill: UIColor(white: 1.0, alpha: 0.12),
                hairline: UIColor(white: 1.0, alpha: 0.09),
                accentFill: UIColor(red: 0.184, green: 0.486, blue: 0.965, alpha: 1.0),
                accentInk: .white,
                glideTrail: UIColor(red: 0.230, green: 0.540, blue: 0.980, alpha: 0.48),
                popupFill: UIColor(red: 0.235, green: 0.235, blue: 0.255, alpha: 1.0),
                popupBorder: UIColor(white: 1.0, alpha: 0.16)
            )
        } else {
            return KeyboardTheme(
                isDark: false,
                deckBackground: UIColor(red: 0.910, green: 0.902, blue: 0.882, alpha: 1.0),
                barBackground: UIColor(red: 0.925, green: 0.918, blue: 0.898, alpha: 1.0),
                letterKeyFill: .white,
                letterKeyPressed: UIColor(red: 0.890, green: 0.885, blue: 0.870, alpha: 1.0),
                utilityKeyFill: UIColor(red: 0.835, green: 0.824, blue: 0.792, alpha: 1.0),
                utilityKeyPressed: UIColor(red: 0.745, green: 0.734, blue: 0.702, alpha: 1.0),
                keyBorder: UIColor(white: 0.0, alpha: 0.08),
                keyShadow: UIColor(white: 0.0, alpha: 0.22),
                primaryInk: UIColor(red: 0.110, green: 0.106, blue: 0.094, alpha: 1.0),
                secondaryInk: UIColor(red: 0.431, green: 0.420, blue: 0.388, alpha: 1.0),
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
