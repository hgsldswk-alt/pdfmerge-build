import Foundation

enum SlotKind: String, Codable {
    case material, application, receipt, attachment
}

struct PublicTemplate: Codable, Equatable {
    let version: Int
    let slots: [SlotKind]
    static let limit = 20
    static let sample = PublicTemplate([.application, .receipt, .attachment])

    init(_ slots: [SlotKind]) { version = 1; self.slots = slots }

    func title(at index: Int, bundle: Bundle = Bundle(for: LocalizationAnchor.self)) -> String {
        let kind = slots[index]
        if kind == .material || slots.filter({ $0 == kind }).count > 1 {
            return String(format: L.t("slot.indexed", bundle: bundle), L.t("slot.\(kind.rawValue)", bundle: bundle), index + 1)
        }
        return L.t("slot.\(kind.rawValue)", bundle: bundle)
    }

    func encoded() throws -> Data {
        guard version == 1, (1...Self.limit).contains(slots.count) else { throw Issue.badTemplate }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }

    func code() throws -> String {
        "PDFMERGE1:" + (try encoded()).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 2048, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "slots"], let template = try? JSONDecoder().decode(Self.self, from: data),
              template.version == 1, (1...limit).contains(template.slots.count) else { throw Issue.badTemplate }
        return template
    }

    static func from(code: String) throws -> Self {
        guard code.utf8.count <= 3072 else { throw Issue.badTemplate }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("PDFMERGE1:") else { throw Issue.badTemplate }
        let payload = trimmed.dropFirst(10)
        guard !payload.isEmpty, payload.utf8.allSatisfy({ byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45 || byte == 95
        }), payload.count % 4 != 1 else { throw Issue.badTemplate }
        let padded = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else { throw Issue.badTemplate }
        return try decode(data)
    }
}

struct SavedTemplate: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var order: PublicTemplate
    var prefix = ""
    var includeDate = false
    var includeSequence = false

    func filename(date: Date, sequence: Int, useRules: Bool) -> String {
        guard useRules else { return "\(L.t("output.default"))-\(Naming.day(date))" }
        let base = Naming.clean(prefix)
        return ([base.isEmpty ? L.t("output.default") : base] +
            (includeDate ? [Naming.day(date)] : []) + (includeSequence ? [String(sequence)] : [])).joined(separator: "-")
    }
}

struct BatchGroup: Codable, Identifiable, Equatable {
    var id = UUID()
    var files: [Int: Source] = [:]
    var result: UUID?
    var issue: Issue?

    func draft(for template: PublicTemplate) -> Draft? {
        let ordered = template.slots.indices.compactMap { files[$0] }
        guard ordered.count == template.slots.count else { return nil }
        let draft = Draft(sources: ordered, pages: ordered.flatMap(\.pages))
        return draft.canGenerate ? draft : nil
    }
}

struct BatchPlan: Codable, Equatable {
    var template: SavedTemplate
    var groups = [BatchGroup()]
}
