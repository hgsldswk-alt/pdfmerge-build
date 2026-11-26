import PDFKit
import UIKit

enum PDFPhotoRenderer {
    static func render(_ document: PDFDocument, selected: Set<Int>? = nil,
                       screenPixels: CGSize, to directory: URL) throws -> [URL] {
        let allPages = 0..<document.pageCount
        let indices = selected.map { $0.sorted() } ?? Array(allPages)
        guard !indices.isEmpty, indices.allSatisfy(allPages.contains) else { throw Issue.invalidPDF }

        return try indices.map { index in
            try Task.checkCancellation()
            return try autoreleasepool {
                guard let page = document.page(at: index) else { throw Issue.invalidPDF }
                let file = directory.appendingPathComponent("page-\(index + 1).jpg")
                try jpeg(page, screenPixels: screenPixels).write(to: file, options: .atomic)
                return file
            }
        }
    }

    private static func jpeg(_ page: PDFPage, screenPixels: CGSize) throws -> Data {
        guard let crop = page.pageRef?.getBoxRect(.cropBox),
              crop.width.isFinite, crop.height.isFinite, crop.width > 0, crop.height > 0 else {
            throw Issue.invalidPDF
        }
        let rotated = page.rotation % 180 != 0
        let width = rotated ? crop.height : crop.width
        let height = rotated ? crop.width : crop.height
        let shortSide = min(screenPixels.width, screenPixels.height) * 2
        let longSide = max(screenPixels.width, screenPixels.height) * 2
        let maxWidth = width > height ? longSide : shortSide
        let maxHeight = width > height ? shortSide : longSide
        let scale = min(maxWidth / width, maxHeight / height)
        guard scale.isFinite, scale > 0 else { throw Issue.photoSaveFailed }

        let size = CGSize(width: max(1, min(maxWidth, (width * scale).rounded(.up))),
                          height: max(1, min(maxHeight, (height * scale).rounded(.up))))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.92) { renderer in
            let context = renderer.cgContext
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: scale, y: -scale)
            page.draw(with: .cropBox, to: context)
        }
    }
}

actor PhotoPDF {
    private var document: PDFDocument?

    func load(_ url: URL) throws -> Int {
        let document = try PDFWork.open(url)
        self.document = document
        return document.pageCount
    }

    func thumbnail(at index: Int) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        return autoreleasepool {
            document?.page(at: index)?.thumbnail(of: CGSize(width: 180, height: 230), for: .cropBox)
        }
    }

    func render(selected: Set<Int>?, screenPixels: CGSize, to directory: URL) throws -> [URL] {
        guard let document else { throw Issue.invalidPDF }
        return try PDFPhotoRenderer.render(document, selected: selected, screenPixels: screenPixels, to: directory)
    }
}
