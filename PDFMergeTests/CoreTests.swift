import Foundation
import CoreImage
import CryptoKit
import PDFKit
import UIKit
import XCTest

final class CoreTests: XCTestCase {
    private func draft() -> Draft {
        let sources = [Source(name: "A", pageCount: 2), Source(name: "B", pageCount: 3), Source(name: "C", pageCount: 1)]
        return Draft(sources: sources, pages: sources.flatMap(\.pages))
    }

    func testCoreReviewRequiresThreeActionsOnTwoLocalDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 23)))
        let nextDay = firstDay.addingTimeInterval(2 * 3600)
        let empty = try JSONDecoder().decode(CoreReviewProgress.self, from: Data("{}".utf8))
        XCTAssertFalse(empty.isEligible)
        var progress = CoreReviewProgress.recording(empty, at: firstDay, calendar: calendar)
        var twoDays = progress
        twoDays.record(at: nextDay, calendar: calendar)
        XCTAssertFalse(twoDays.isEligible)
        progress.record(at: firstDay, calendar: calendar)
        XCTAssertFalse(progress.isEligible)

        var sameDay = progress
        sameDay.record(at: firstDay, calendar: calendar)
        XCTAssertFalse(sameDay.isEligible)

        let data = try JSONEncoder().encode(progress)
        progress = try JSONDecoder().decode(CoreReviewProgress.self, from: data)
        progress.record(at: nextDay, calendar: calendar)
        XCTAssertTrue(progress.isEligible)
    }

    func testRegroupPreservesRelativePageOrderAndUndo() {
        var history = DraftHistory(current: draft())
        let original = history.current
        let pages = original.pages
        let sources = original.sources
        history.edit { $0.movePage(pages[3].id, to: pages[1].id) }
        let mixed = history.current
        XCTAssertTrue(mixed.mixed)
        history.edit { $0.moveSource(sources[2].id, to: sources[0].id) }
        XCTAssertFalse(history.current.mixed)
        XCTAssertEqual(history.current.pages, [pages[5], pages[0], pages[1], pages[3], pages[2], pages[4]])
        history.edit { $0.removeSource(sources[1].id) }
        XCTAssertEqual(history.current.pages.count, 3)
        history.undo()
        XCTAssertEqual(history.current.pages.count, 6)
        history.undo()
        XCTAssertEqual(history.current, mixed)
        history.undo()
        XCTAssertEqual(history.current, original)
    }

    func testMovingMixedSourceRegroupsItsDisplacedPageAndUndoRestoresMix() {
        let application = Source(name: "Application.pdf", pageCount: 2)
        let receipt = Source(name: "Receipt.pdf", pageCount: 1)
        let attachment = Source(name: "Attachment.pdf", pageCount: 3)
        let sources = [application, receipt, attachment]
        let original = Draft(sources: sources, pages: sources.flatMap(\.pages))
        var history = DraftHistory(current: original)
        let displaced = original.pages[3]

        history.edit { $0.movePage(displaced.id, to: original.pages[1].id) }
        let mixed = history.current
        XCTAssertTrue(mixed.mixed)
        XCTAssertEqual(mixed.pages, [original.pages[0], displaced, original.pages[1], original.pages[2],
                                     original.pages[4], original.pages[5]])

        history.edit { $0.moveSource(attachment.id, to: application.id) }
        XCTAssertEqual(history.current.sources, [attachment, application, receipt])
        XCTAssertEqual(history.current.pages, attachment.pages + application.pages + receipt.pages)
        XCTAssertFalse(history.current.mixed)

        history.undo()
        XCTAssertEqual(history.current, mixed)
        XCTAssertTrue(history.current.mixed)
        history.undo()
        XCTAssertEqual(history.current, original)
    }

    func testLastPageRemovalDisablesAndUndoRestores() {
        var history = DraftHistory()
        var source = Source(name: "form.pdf", pageCount: 1, issue: .interactivePDF)
        history.edit { $0.add(source) }
        XCTAssertFalse(history.current.canGenerate)
        history.edit { $0.allow(source.id) }
        XCTAssertTrue(history.current.canGenerate)
        history.edit { $0.removePage(source.pages[0].id) }
        XCTAssertFalse(history.current.canGenerate)
        history.undo()
        XCTAssertTrue(history.current.canGenerate)
        source.issue = .invalidPDF
        history.edit { $0.add(source, replacing: source.id) }
        XCTAssertFalse(history.current.canGenerate)
    }

    func testValidatedTemplateRoundTripAndLocalizedSlots() throws {
        let order = PublicTemplate.sample
        let file = try order.encoded()
        XCTAssertEqual(try PublicTemplate.decode(file), order)
        XCTAssertEqual(try PublicTemplate.from(code: "\n\(order.code())\r\n"), order)
        let examples = ["zh-Hans": "申请表", "zh-Hant": "申請表", "en": "Application"]
        for (language, title) in examples {
            let path = try XCTUnwrap(Bundle(for: LocalizationAnchor.self).path(forResource: language, ofType: "lproj"))
            XCTAssertEqual(order.title(at: 0, bundle: try XCTUnwrap(Bundle(path: path))), title)
        }
        for text in [#"{"version":2,"slots":["material"]}"#, #"{"version":1,"slots":[]}"#,
                     #"{"version":1,"slots":["private.pdf"]}"#, #"{"version":1,"slots":["material"],"name":"secret"}"#] {
            XCTAssertThrowsError(try PublicTemplate.decode(Data(text.utf8)))
        }
        XCTAssertThrowsError(try PublicTemplate.decode(Data(repeating: 0, count: 2049)))
        XCTAssertThrowsError(try PublicTemplate(Array(repeating: .material, count: 21)).code())
    }

    func testBatchSlotOrderAndIndependentFailure() {
        let order = PublicTemplate([.application, .receipt])
        let first = Source(name: "first", pageCount: 2)
        let second = Source(name: "second", pageCount: 1)
        let denied = Source(name: "bad", issue: .protectedPDF)
        let success = BatchGroup(files: [1: second, 0: first], result: UUID())
        var retry = BatchGroup(files: [0: first, 1: denied])
        XCTAssertEqual(success.draft(for: order)?.sources, [first, second])
        XCTAssertNil(retry.draft(for: order))
        retry.files[1] = second
        XCTAssertEqual(retry.draft(for: order)?.pages.count, 3)
        XCTAssertEqual([success, retry].filter { $0.result == nil }.map(\.id), [retry.id])
    }

    func testStartupReconciliationKeepsAvailableOutputsAndRetriesMissingGroups() {
        var library = Library()
        let retained = Output(name: "Retained", pageCount: 1, fileCount: 1, date: .now, order: nil)
        let missing = Output(name: "Missing", pageCount: 1, fileCount: 1, date: .now, order: nil)
        library.history = [retained, missing]
        let order = PublicTemplate([.material])
        let files = [0: Source(name: "Source", pageCount: 1)]
        library.batch = BatchPlan(template: SavedTemplate(title: "Plan", order: order),
                                  groups: [BatchGroup(files: files, result: retained.id), BatchGroup(files: files, result: missing.id)])
        library.reconcileOutputs([retained.id])
        XCTAssertEqual(library.history, [retained])
        XCTAssertEqual(library.batch?.groups[0].result, retained.id)
        XCTAssertNil(library.batch?.groups[1].result)
        XCTAssertEqual(library.batch?.groups[1].draft(for: order)?.pages.count, 1)
    }

    func testNamingAndDeliveryGates() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let output = Output(name: "Packet.pdf", pageCount: 1, fileCount: 1, date: now, order: nil)
        XCTAssertEqual(Naming.unique("packet.pdf", existing: [output]), "packet-2.pdf")
        XCTAssertEqual(Naming.unique("../foo:bar", existing: []), "-foo-bar.pdf")
        var stats = DeliveryStats()
        for _ in 1...4 { stats.generated(UUID()) }
        stats.generated(output.id)
        XCTAssertEqual(stats.pendingMilestones[output.id], 5)
        stats.acknowledge(output.id)
        XCTAssertNil(stats.pendingMilestones[output.id])
        stats.delivered(output.id, on: now)
        stats.delivered(output.id, on: now.addingTimeInterval(86_400))
        stats.delivered(UUID(), on: now)
        stats.delivered(UUID(), on: now)
        XCTAssertFalse(stats.request(version: "1", firstSession: false))
        stats.delivered(UUID(), on: now.addingTimeInterval(86_400))
        XCTAssertFalse(stats.request(version: "1", firstSession: true))
        XCTAssertTrue(stats.request(version: "1", firstSession: false))
        XCTAssertFalse(stats.request(version: "1", firstSession: false))
    }

    func testTrialMigrationExpiryRollbackAndCachedPurchase() throws {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let start = old.addingTimeInterval(90 * 86_400)
        var state = Entitlement(firstOpen: old)
        state.observe(old, free: true)
        XCTAssertTrue(state.hasPro(at: start, free: true))
        state.observe(start, free: false)
        XCTAssertEqual(state.trialStart, start)
        state.recordTrial(start.addingTimeInterval(86_400))
        XCTAssertEqual(state.trialStart, start)
        XCTAssertTrue(state.hasPro(at: state.trialEnd.addingTimeInterval(-1)))
        XCTAssertFalse(state.hasPro(at: state.trialEnd))
        state.observe(state.trialEnd, free: false)
        XCTAssertFalse(state.hasPro(at: start))
        state.purchasedPro = true
        let restored = try JSONDecoder().decode(Entitlement.self, from: JSONEncoder().encode(state))
        XCTAssertTrue(restored.hasPro(at: start))
        var reinstall = Entitlement(firstOpen: start)
        reinstall.observe(start, free: false)
        reinstall.recordTrial(old)
        XCTAssertFalse(reinstall.hasPro(at: start))
    }

    func testCardDimensionsPrivacyAndQRCode() throws {
        let url = try XCTUnwrap(URL(string: "https://apps.apple.com/app/id1234567890"))
        let content = CardContent.order(.sample)
        let image = ShareCard.render(content, storeURL: url)
        XCTAssertEqual(try XCTUnwrap(image.cgImage).width, 1242)
        XCTAssertEqual(try XCTUnwrap(image.cgImage).height, 1656)
        XCTAssertTrue(content.topics.hasPrefix("#"))
        let code = String(decoding: try PublicTemplate.sample.encoded(), as: UTF8.self)
        XCTAssertFalse(code.contains(".pdf"))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let messages = detector.features(in: try XCTUnwrap(CIImage(image: image))).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertTrue(messages.contains(url.absoluteString), "Decoded: \(messages)")
        let generic = PublicTemplate([.material, .material])
        let generatedCard = ShareCard.render(.order(generic), storeURL: url)
        let generatedCodes = detector.features(in: try XCTUnwrap(CIImage(image: generatedCard)))
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(generatedCodes, [url.absoluteString])
        let placeholder = ShareCard.render(.milestone(20), storeURL: nil)
        XCTAssertTrue(detector.features(in: try XCTUnwrap(CIImage(image: placeholder))).isEmpty)
    }

    func testPDFExportWithPageBoxesSearchRotationAndUntouchedInputs() throws {
        try inTemporaryFolder { root in
            let draft = draft()
            let inputs = Dictionary(uniqueKeysWithValues: draft.sources.map { ($0.id, root.appendingPathComponent($0.name + ".pdf")) })
            var hashes: [UUID: SHA256.Digest] = [:]
            for source in draft.sources {
                let url = try XCTUnwrap(inputs[source.id])
                try PDFWork.fixture(title: source.name, pages: source.pageCount, at: url)
                if source.name == "A" {
                    let original = try PDFWork.open(url)
                    let page = try XCTUnwrap(original.page(at: 0))
                    page.rotation = 90
                    page.setBounds(CGRect(x: 8, y: 12, width: 270, height: 330), for: .cropBox)
                    let bytes = try XCTUnwrap(original.dataRepresentation())
                    try bytes.write(to: url, options: .atomic)
                }
                hashes[source.id] = SHA256.hash(data: try Data(contentsOf: url))
            }
            var arranged = draft
            arranged.moveSource(draft.sources[2].id, to: draft.sources[0].id)
            arranged.movePage(draft.pages[3].id, to: draft.pages[0].id)
            arranged.rotate(draft.pages[0].id)
            arranged.removePage(draft.pages[4].id)
            let target = root.appendingPathComponent("combined.pdf")
            try PDFWork.generate(arranged, source: { inputs[$0]! }, to: target)
            let reopened = try PDFWork.open(target)
            XCTAssertEqual(reopened.pageCount, 5)
            for (index, expected) in arranged.pages.enumerated() {
                let original = try XCTUnwrap(try PDFWork.open(XCTUnwrap(inputs[expected.source])).page(at: expected.index))
                let page = try XCTUnwrap(reopened.page(at: index))
                XCTAssertEqual(page.string?.trimmingCharacters(in: .whitespacesAndNewlines), original.string?.trimmingCharacters(in: .whitespacesAndNewlines))
                XCTAssertEqual(page.rotation, expected.rotation(on: original.rotation))
                XCTAssertEqual(page.bounds(for: .mediaBox), original.bounds(for: .mediaBox))
                XCTAssertEqual(page.bounds(for: .cropBox), original.bounds(for: .cropBox))
            }
            XCTAssertFalse(reopened.findString("C", withOptions: []).isEmpty)
            for (id, input) in inputs { XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: input)), hashes[id]) }
        }
    }

    func testPDFRejectionAndCancellation() throws {
        try inTemporaryFolder { root in
            let bad = root.appendingPathComponent("bad.pdf")
            let target = root.appendingPathComponent("result.pdf")
            try Data().write(to: bad)
            XCTAssertEqual(PDFWork.importPDF(bad, to: target, id: UUID()).issue, .invalidPDF)
            try Data("not a PDF".utf8).write(to: bad)
            XCTAssertEqual(PDFWork.importPDF(bad, to: target, id: UUID()).issue, .invalidPDF)
            let secure = root.appendingPathComponent("secure.pdf")
            try PDFWork.fixture(title: "S", pages: 1, at: secure)
            let original = try PDFWork.open(secure)
            let bytes = try XCTUnwrap(original.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "reader", PDFDocumentWriteOption.ownerPasswordOption: "owner"]))
            try bytes.write(to: secure, options: .atomic)
            XCTAssertEqual(PDFWork.importPDF(secure, to: target, id: UUID()).issue, .protectedPDF)
            let source = Source(name: "S", pageCount: 1)
            var draft = Draft()
            draft.add(source)
            XCTAssertThrowsError(try PDFWork.generate(draft, source: { _ in secure }, to: target) { throw CancellationError() })
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            XCTAssertEqual(Issue.storage(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)), .noSpace)
        }
    }

    func testInteractivePDFIsNotSilentlyIncluded() throws {
        let bundle = Bundle(for: CoreTests.self)
        for fixture in ["Form", "Signature", "CopyRestricted"] {
            let url = try XCTUnwrap(bundle.url(forResource: fixture, withExtension: "pdf"))
            try inTemporaryFolder { root in
                let source = PDFWork.importPDF(url, to: root.appendingPathComponent("copy.pdf"), id: UUID())
                XCTAssertEqual(source.issue, fixture == "CopyRestricted" ? .protectedPDF : .interactivePDF)
                var draft = Draft()
                draft.add(source)
                XCTAssertFalse(draft.canGenerate)
            }
        }
    }

    func testPhotoExportRendersAllPDFPagesAtTwiceScreenPixels() throws {
        try inTemporaryFolder { root in
            let url = root.appendingPathComponent("photo-fixture.pdf")
            try PDFWork.fixture(title: "Photos", pages: 3, at: url)
            let document = try PDFWork.open(url)
            XCTAssertEqual(document.pageCount, 3)
            try XCTUnwrap(document.page(at: 1)).rotation = 90

            let files = try PDFPhotoRenderer.render(document, screenPixels: CGSize(width: 320, height: 640), to: root)
            XCTAssertEqual(files.map(\.lastPathComponent), ["page-1.jpg", "page-2.jpg", "page-3.jpg"])
            let portrait = try XCTUnwrap(UIImage(contentsOfFile: files[0].path)?.cgImage)
            let landscape = try XCTUnwrap(UIImage(contentsOfFile: files[1].path)?.cgImage)
            XCTAssertEqual(portrait.width, 640)
            XCTAssertEqual(portrait.height, 840)
            XCTAssertEqual(landscape.width, 840)
            XCTAssertEqual(landscape.height, 640)
        }
    }

    func testPhotoExportRendersOnlyCheckedPagesInPDFOrder() throws {
        try inTemporaryFolder { root in
            let url = root.appendingPathComponent("photo-fixture.pdf")
            try PDFWork.fixture(title: "Photos", pages: 4, at: url)
            let document = try PDFWork.open(url)
            let screen = CGSize(width: 320, height: 640)

            XCTAssertThrowsError(try PDFPhotoRenderer.render(document, selected: [], screenPixels: screen, to: root))
            XCTAssertThrowsError(try PDFPhotoRenderer.render(document, selected: [1, 4], screenPixels: screen, to: root))
            let files = try PDFPhotoRenderer.render(document, selected: [3, 1], screenPixels: screen, to: root)
            XCTAssertEqual(files.map(\.lastPathComponent), ["page-2.jpg", "page-4.jpg"])
            let written = try FileManager.default.contentsOfDirectory(atPath: root.path)
            XCTAssertEqual(Set(written), Set(["page-2.jpg", "page-4.jpg", "photo-fixture.pdf"]))
        }
    }

    private func inTemporaryFolder(_ run: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try run(root)
    }
}
