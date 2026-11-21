import Foundation
import CoreGraphics
import PDFKit
import UIKit

enum PDFWork {
    static let byteLimit = 150 * 1024 * 1024
    static let pageLimit = 500

    static func coordinated<T>(_ url: URL, read: (URL) throws -> T) throws -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readable in
            result = Result { try read(readable) }
        }
        guard coordinationError == nil, let result else { throw Issue.unreadable }
        return try result.get()
    }

    static func importPDF(_ url: URL, to target: URL, id: UUID) -> Source {
        let name = url.lastPathComponent
        do {
            try coordinated(url) { readable in
                let details = try readable.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard details.isRegularFile == true, let size = details.fileSize else { throw Issue.unreadable }
                guard size > 0 else { throw Issue.invalidPDF }
                guard size <= byteLimit else { throw Issue.tooLarge }
                try FileManager.default.copyItem(at: readable, to: target)
            }
            try Task.checkCancellation()
            let document = try open(target)
            return Source(id: id, name: name, pageCount: document.pageCount,
                          issue: interactive(document) ? .interactivePDF : nil)
        } catch {
            try? FileManager.default.removeItem(at: target)
            let issue = error as? Issue ?? (Issue.storage(error) == .noSpace ? .noSpace : .unreadable)
            return Source(id: id, name: name, issue: issue)
        }
    }

    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw Issue.invalidPDF }
        guard !document.isEncrypted, !document.isLocked, document.allowsCopying else { throw Issue.protectedPDF }
        guard document.pageCount > 0 else { throw Issue.invalidPDF }
        guard document.pageCount <= pageLimit else { throw Issue.tooLarge }
        return document
    }

    static func interactive(_ document: PDFDocument) -> Bool {
        if let catalog = document.documentRef?.catalog {
            var form: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form) { return true }
        }
        for index in 0..<document.pageCount {
            if document.page(at: index)?.annotations.contains(where: { $0.type == "Widget" || $0.type == "/Widget" }) == true {
                return true
            }
        }
        return false
    }

    struct SourceFailure: Error {
        let id: UUID
        let issue: Issue
    }

    static func generate(_ draft: Draft, source: (UUID) -> URL, to target: URL,
                         check: () throws -> Void = { try Task.checkCancellation() }) throws {
        guard draft.canGenerate else { throw Issue.invalidPDF }
        guard draft.pages.count <= pageLimit else { throw Issue.tooLarge }
        let fileManager = FileManager.default
        let staging = target.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).partial.pdf")
        defer { try? fileManager.removeItem(at: staging) }
        let combined = PDFDocument()
        var documents: [UUID: PDFDocument] = [:]
        var bytes = 0
        for entry in draft.pages {
            try check()
            if documents[entry.source] == nil {
                let url = source(entry.source)
                do {
                    bytes += (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                    documents[entry.source] = try open(url)
                } catch { throw SourceFailure(id: entry.source, issue: error as? Issue ?? .unreadable) }
                guard bytes <= byteLimit else { throw Issue.tooLarge }
            }
            guard let original = documents[entry.source]?.page(at: entry.index),
                  let page = original.copy() as? PDFPage else { throw SourceFailure(id: entry.source, issue: .invalidPDF) }
            page.rotation = entry.rotation(on: original.rotation)
            combined.insert(page, at: combined.pageCount)
        }
        try withExtendedLifetime(documents) {
            guard let data = combined.dataRepresentation() else { throw Issue.writeFailed }
            try data.write(to: staging)
        }
        try check()
        guard PDFDocument(url: staging)?.pageCount == draft.pages.count else { throw Issue.writeFailed }
        try fileManager.moveItem(at: staging, to: target)
    }

    static func thumbnail(url: URL, page: Page) -> UIImage? {
        guard let document = PDFDocument(url: url), let original = document.page(at: page.index) else { return nil }
        original.rotation = page.rotation(on: original.rotation)
        return original.thumbnail(of: CGSize(width: 210, height: 270), for: .cropBox)
    }

    static func fixture(title: String, pages: Int, at url: URL) throws {
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 420)
        try UIGraphicsPDFRenderer(bounds: bounds).writePDF(to: url) { context in
            for index in 1...pages {
                context.beginPage()
                ("\(title) · \(index)" as NSString).draw(at: CGPoint(x: 24, y: 28), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 20)])
                for line in 0..<5 {
                    UIColor.systemGray4.setFill()
                    context.cgContext.fill(CGRect(x: 24, y: 80 + line * 29, width: 254 - line * 18, height: 3))
                }
            }
        }
    }
}
