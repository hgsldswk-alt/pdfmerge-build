import Foundation

final class LocalizationAnchor: NSObject {}

enum L {
    static func t(_ key: String, bundle: Bundle = Bundle(for: LocalizationAnchor.self)) -> String {
        NSLocalizedString(key, bundle: bundle, comment: "")
    }

    static func f(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), locale: Locale.current, arguments: arguments)
    }
}
