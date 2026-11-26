import Foundation

final class LocalizationAnchor: NSObject {}

enum L {
    static func t(_ key: String, bundle: Bundle = Bundle(for: LocalizationAnchor.self)) -> String {
        let translation = NSLocalizedString(key, bundle: bundle, comment: "")
        guard translation == key, bundle.preferredLocalizations.first == "ja",
              let path = bundle.path(forResource: "en", ofType: "lproj"),
              let english = Bundle(path: path) else { return translation }
        return NSLocalizedString(key, bundle: english, comment: "")
    }

    static func f(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), locale: Locale.current, arguments: arguments)
    }
}
