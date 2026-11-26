import Foundation

enum Launch {
    static let freePeriod = false
    static var arguments: [String] { ProcessInfo.processInfo.arguments }
    static func isFree(arguments: [String]) -> Bool {
        freePeriod && !arguments.contains(where: { ["-paid-mode", "-paywall", "-expired"].contains($0) })
    }
    static var isFree: Bool { isFree(arguments: arguments) }
    static var hostedTests: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["PDFMERGE_HOSTED_TESTS"] == "1"
        #else
        false
        #endif
    }
    static var testing: Bool {
        #if DEBUG
        arguments.contains("-ui-testing")
        #else
        false
        #endif
    }
    static var storeURL: URL? {
        guard let value = Bundle(for: LocalizationAnchor.self).object(forInfoDictionaryKey: "APP_STORE_ID") as? String,
              !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return URL(string: "https://apps.apple.com/app/id\(value)")
    }
}
