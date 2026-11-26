import Foundation
import UIKit

struct Library: Codable {
    var draft = DraftHistory()
    var history: [Output] = []
    var templates: [SavedTemplate] = []
    var activeTemplate: SavedTemplate?
    var slots: [Int: Source] = [:]
    var batch: BatchPlan?
    var stats = DeliveryStats()

    mutating func reconcileOutputs(_ available: Set<UUID>) {
        let missing = Set(history.map(\.id)).subtracting(available)
        history.removeAll { missing.contains($0.id) }
        for id in missing { stats.acknowledge(id) }
        if let indices = batch?.groups.indices {
            for index in indices {
                if let result = batch?.groups[index].result, !available.contains(result) {
                    batch?.groups[index].result = nil
                }
            }
        }
    }
}

actor Workspace {
    var base: URL?
    var revision = 0
    var writing = false
    let thumbnails: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 90
        cache.totalCostLimit = 20 * 1024 * 1024
        return cache
    }()

    private func folder(_ component: String = "") throws -> URL {
        guard let base else { throw Issue.writeFailed }
        return component.isEmpty ? base : base.appendingPathComponent(component, isDirectory: true)
    }

    func load(testing: Bool, reset: Bool) throws -> (Library, Bool) {
        var root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(testing ? "PDFMerge-UITests" : "PDFMerge", isDirectory: true)
        if testing && reset && FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var flags = URLResourceValues()
        flags.isExcludedFromBackup = true
        try root.setResourceValues(flags)
        base = root
        for directory in ["sources", "outputs", "fixtures"] {
            try FileManager.default.createDirectory(at: folder(directory), withIntermediateDirectories: true)
        }
        let outputs = try FileManager.default.contentsOfDirectory(at: folder("outputs"), includingPropertiesForKeys: nil)
        for url in outputs where url.lastPathComponent.hasSuffix(".partial.pdf") { try? FileManager.default.removeItem(at: url) }
        let file = root.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return (Library(), true) }
        var state = try JSONDecoder().decode(Library.self, from: Data(contentsOf: file))
        state.reconcileOutputs(Set(outputs.compactMap { url in
            guard url.pathExtension == "pdf" else { return nil }
            return UUID(uuidString: url.deletingPathExtension().lastPathComponent)
        }))
        return (state, false)
    }

    func save(_ state: Library, revision next: Int) throws {
        guard next > revision else { return }
        try JSONEncoder().encode(state).write(to: folder().appendingPathComponent("state.json"), options: .atomic)
        revision = next
    }

    func sourceURL(_ id: UUID) throws -> URL { try folder("sources").appendingPathComponent("\(id.uuidString).pdf") }
    func outputURL(_ id: UUID) throws -> URL { try folder("outputs").appendingPathComponent("\(id.uuidString).pdf") }

    func add(_ url: URL) throws -> Source {
        let id = UUID()
        return PDFWork.importPDF(url, to: try sourceURL(id), id: id)
    }

    func discard(_ sources: [Source]) {
        for source in sources {
            if let url = try? sourceURL(source.id) { try? FileManager.default.removeItem(at: url) }
        }
    }

    func write(_ draft: Draft, output: Output) async throws {
        guard !writing else { throw Issue.writeFailed }
        writing = true
        defer { writing = false }
        let sources = try folder("sources")
        let target = try outputURL(output.id)
        let work = Task.detached(priority: .userInitiated) {
            try PDFWork.generate(draft, source: { sources.appendingPathComponent("\($0.uuidString).pdf") }, to: target)
        }
        do {
            try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    func thumbnail(_ page: Page) -> UIImage? {
        guard !Task.isCancelled, let url = try? sourceURL(page.source) else { return nil }
        let key = "\(page.id):\(page.turns)" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        let image = autoreleasepool { PDFWork.thumbnail(url: url, page: page) }
        if let image { thumbnails.setObject(image, forKey: key, cost: 210 * 270 * 4) }
        return image
    }

    func template(at url: URL) throws -> PublicTemplate {
        try PDFWork.coordinated(url) { readable in
            let info = try readable.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard info.isRegularFile == true, let size = info.fileSize, size <= 2048 else { throw Issue.badTemplate }
            return try PublicTemplate.decode(Data(contentsOf: readable))
        }
    }

    func fixtures(template: Bool = false) throws -> [URL] {
        if template {
            let url = try folder("fixtures").appendingPathComponent(L.t("share.filename") + ".pdfmergetemplate")
            try PublicTemplate([.material]).encoded().write(to: url, options: .atomic)
            return [url]
        }
        var files = try zip(PublicTemplate.sample.slots.indices, [2, 1, 3]).map { index, pages in
            let title = PublicTemplate.sample.title(at: index)
            let url = try folder("fixtures").appendingPathComponent("\(title).pdf")
            if !FileManager.default.fileExists(atPath: url.path) { try PDFWork.fixture(title: title, pages: pages, at: url) }
            return url
        }
        if Launch.arguments.contains("-invalid-fixture") {
            let invalid = try folder("fixtures").appendingPathComponent(L.t("fixtures.invalid") + ".pdf")
            try Data("not a PDF".utf8).write(to: invalid, options: .atomic)
            files.append(invalid)
        }
        return files
    }

    func bytes(in area: String, retaining ids: Set<UUID> = []) throws -> Int64 {
        try candidates(in: area, retaining: ids).reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    func clean(_ area: String, retaining ids: Set<UUID> = []) throws {
        for url in try candidates(in: area, retaining: ids) { try FileManager.default.removeItem(at: url) }
    }

    private func candidates(in area: String, retaining ids: Set<UUID>) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder(area), includingPropertiesForKeys: nil).filter { url in
            guard url.pathExtension == "pdf" else { return false }
            return UUID(uuidString: url.deletingPathExtension().lastPathComponent).map { !ids.contains($0) }
                ?? (area == "outputs" && url.lastPathComponent.hasSuffix(".partial.pdf"))
        }
    }

    func handoff(output: Output) throws -> URL {
        let file = try outputURL(output.id)
        let directory = try temporary()
        let target = directory.appendingPathComponent(output.name)
        do { try FileManager.default.copyItem(at: file, to: target) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        return target
    }

    func handoff(template: PublicTemplate) throws -> URL {
        let directory = try temporary()
        let target = directory.appendingPathComponent(L.t("share.filename") + ".pdfmergetemplate")
        do { try template.encoded().write(to: target, options: .atomic) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        return target
    }

    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PDFMerge-shares", isDirectory: true)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let old = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) {
            for url in old where url != directory {
                if let date = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate,
                   date < Date.now.addingTimeInterval(-86_400) { try? FileManager.default.removeItem(at: url) }
            }
        }
        return directory
    }

    func finishSharing(_ file: URL) { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
}
