import Foundation

enum Issue: String, Codable, Error {
    case unreadable, invalidPDF, protectedPDF, interactivePDF, writeFailed, noSpace, badTemplate, tooLarge, purchaseFailed, photoPermission, photoSaveFailed

    var message: String { L.t("issue.\(rawValue)") }

    static func storage(_ error: Error) -> Issue {
        if let issue = error as? Issue { return issue }
        let underlying = error as NSError
        if underlying.domain == NSCocoaErrorDomain && underlying.code == NSFileWriteOutOfSpaceError { return .noSpace }
        if underlying.domain == NSPOSIXErrorDomain && underlying.code == 28 { return .noSpace }
        return .writeFailed
    }
}

struct Source: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    var pageCount = 0
    var issue: Issue?

    init(id: UUID = UUID(), name: String, pageCount: Int = 0, issue: Issue? = nil) {
        self.id = id
        self.name = name
        self.pageCount = pageCount
        self.issue = issue
    }

    var pages: [Page] { (0..<pageCount).map { Page(source: id, index: $0) } }
}

struct Page: Identifiable, Codable, Equatable {
    let source: UUID
    let index: Int
    var turns = 0
    var id: String { "\(source.uuidString):\(index)" }
    func rotation(on original: Int) -> Int { ((original + turns * 90) % 360 + 360) % 360 }
}

struct Draft: Codable, Equatable {
    var sources: [Source] = []
    var pages: [Page] = []
    var canGenerate: Bool { !pages.isEmpty && !sources.contains { $0.issue != nil } }
    var usedSources: Int { Set(pages.map(\.source)).count }
    var mixed: Bool {
        let groups = Dictionary(grouping: pages, by: \.source)
        return sources.flatMap { groups[$0.id] ?? [] } != pages
    }

    mutating func add(_ source: Source, replacing target: UUID? = nil) {
        let ready = source.issue == nil ? source.pages : []
        if let target, let index = sources.firstIndex(where: { $0.id == target }) {
            sources[index] = source
            pages.removeAll { $0.source == target }
            let later = Set(sources.dropFirst(index + 1).map(\.id))
            let slot = pages.firstIndex(where: { later.contains($0.source) }) ?? pages.endIndex
            pages.insert(contentsOf: ready, at: slot)
        } else {
            sources.append(source)
            pages.append(contentsOf: ready)
        }
    }

    mutating func allow(_ id: UUID) {
        guard var source = sources.first(where: { $0.id == id && $0.issue == .interactivePDF }) else { return }
        source.issue = nil
        add(source, replacing: id)
    }

    mutating func moveSource(_ from: UUID, to target: UUID) {
        guard from != target, let start = sources.firstIndex(where: { $0.id == from }),
              let end = sources.firstIndex(where: { $0.id == target }) else { return }
        let moved = sources.remove(at: start)
        sources.insert(moved, at: end)
        let groups = Dictionary(grouping: pages, by: \.source)
        pages = sources.flatMap { groups[$0.id] ?? [] }
    }

    mutating func movePage(_ from: String, to target: String) {
        guard from != target, let start = pages.firstIndex(where: { $0.id == from }),
              let end = pages.firstIndex(where: { $0.id == target }) else { return }
        let moved = pages.remove(at: start)
        pages.insert(moved, at: end)
    }

    mutating func rotate(_ id: String) {
        if let index = pages.firstIndex(where: { $0.id == id }) { pages[index].turns = (pages[index].turns + 1) % 4 }
    }

    mutating func removePage(_ id: String) { pages.removeAll { $0.id == id } }

    mutating func removeSource(_ id: UUID) {
        sources.removeAll { $0.id == id }
        pages.removeAll { $0.source == id }
    }
}

struct DraftHistory: Codable {
    var current: Draft
    private(set) var previous: [Draft] = []
    private(set) var revision = 0

    init(current: Draft = Draft()) { self.current = current }

    mutating func edit(_ operation: (inout Draft) -> Void) {
        let before = current
        operation(&current)
        guard before != current else { return }
        revision += 1
        previous.append(before)
        if previous.count > 40 { previous.removeFirst() }
    }

    mutating func undo() {
        if let last = previous.popLast() { current = last; revision += 1 }
    }
}

struct Output: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    let pageCount: Int
    let fileCount: Int
    let date: Date
    let order: PublicTemplate?
    var draftRevision: Int? = nil
}

struct DeliveryStats: Codable, Equatable {
    private(set) var generated = 0
    private(set) var delivered: Set<UUID> = []
    private(set) var days: Set<String> = []
    private(set) var lastRequest: String?
    var coreReviewProgress: CoreReviewProgress?
    private(set) var pendingMilestones: [UUID: Int] = [:]

    mutating func generated(_ id: UUID) {
        generated += 1
        if [5, 20].contains(generated) { pendingMilestones[id] = generated }
    }

    mutating func acknowledge(_ id: UUID) { pendingMilestones.removeValue(forKey: id) }

    mutating func delivered(_ id: UUID, on date: Date) {
        guard delivered.insert(id).inserted else { return }
        days.insert(Naming.day(date))
    }

    mutating func request(version: String, firstSession: Bool) -> Bool {
        guard !firstSession, delivered.count >= 3, days.count >= 2, lastRequest != version else { return false }
        markReviewRequested(version: version)
        return true
    }

    mutating func markReviewRequested(version: String) {
        lastRequest = version
    }
}

enum Naming {
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func clean(_ value: String) -> String {
        var stem = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.lowercased().hasSuffix(".pdf") { stem.removeLast(4) }
        let rejected = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = stem.components(separatedBy: rejected).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return String(String.UnicodeScalarView(cleaned.unicodeScalars.prefix(60)))
    }

    static func unique(_ suggestion: String, existing: [Output], except: UUID? = nil) -> String {
        let cleanStem = clean(suggestion)
        let stem = cleanStem.isEmpty ? L.t("output.default") : cleanStem
        let taken = Set(existing.filter { $0.id != except }.map { $0.name.lowercased() })
        var name = "\(stem).pdf"
        var sequence = 2
        while taken.contains(name.lowercased()) {
            name = "\(stem)-\(sequence).pdf"
            sequence += 1
        }
        return name
    }
}
