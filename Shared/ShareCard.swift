import CoreImage.CIFilterBuiltins
import UIKit

enum CardContent: Identifiable {
    case order(PublicTemplate)
    case milestone(Int)

    var id: String { title }
    var title: String {
        switch self {
        case .order(let order): return L.t(order == .sample ? "card.sample" : "card.order")
        case .milestone(let count): return L.f("card.milestone", count)
        }
    }

    var order: PublicTemplate? {
        if case .order(let order) = self { return order }
        return nil
    }
    var topics: String { L.t("card.topics") }
}

enum ShareCard {
    static let size = CGSize(width: 1242, height: 1656)

    static func render(_ content: CardContent, storeURL: URL? = Launch.storeURL) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let blue = UIColor(red: 36 / 255, green: 70 / 255, blue: 184 / 255, alpha: 1)
        let ink = UIColor(red: 20 / 255, green: 31 / 255, blue: 58 / 255, alpha: 1)
        let code = storeURL.flatMap(qr)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.93, green: 0.95, blue: 1, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(x: 60, y: 60, width: 1122, height: 1536), cornerRadius: 62).fill()
            func text(_ value: String, x: CGFloat = 120, y: CGFloat, width: CGFloat = 1002,
                      height: CGFloat, font: UIFont, color: UIColor) {
                (value as NSString).draw(with: CGRect(x: x, y: y, width: width, height: height),
                                         options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                         attributes: [.font: font, .foregroundColor: color], context: nil)
            }
            text(L.t("app.name"), y: 138, height: 65, font: .boldSystemFont(ofSize: 42), color: blue)
            text(content.title, y: 237, height: 220, font: .boldSystemFont(ofSize: 79), color: ink)
            if let order = content.order {
                for index in order.slots.indices {
                    let columns = order.slots.count > 10 ? 2 : 1
                    let x = CGFloat(120 + (index % columns) * 510)
                    let y = CGFloat(465 + (index / columns) * 57)
                    text("\(index + 1)  ·  \(order.title(at: index))", x: x, y: y, width: columns == 2 ? 493 : 1002,
                         height: 52, font: .systemFont(ofSize: 37, weight: .semibold), color: ink)
                }
            } else {
                text(L.t("card.milestone.subtitle"), y: 475, height: 205, font: .systemFont(ofSize: 48), color: ink)
            }
            let frame = CGRect(x: 120, y: 1090, width: 330, height: 330)
            if let code {
                context.cgContext.interpolationQuality = .none
                code.draw(in: frame)
            } else {
                UIColor(red: 0.93, green: 0.95, blue: 1, alpha: 1).setFill()
                UIBezierPath(roundedRect: frame, cornerRadius: 24).fill()
                text("QR", x: 204, y: 1204, width: 180, height: 110, font: .boldSystemFont(ofSize: 76), color: blue)
            }
            text(L.t(code == nil ? "card.placeholder" : "card.scan"), x: 502, y: 1190, width: 610,
                 height: 195, font: .boldSystemFont(ofSize: 47), color: ink)
            text(content.topics, y: 1464, height: 70, font: .boldSystemFont(ofSize: 36), color: blue)
        }
    }

    static func qr(_ url: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let pixels = filter.outputImage else { return nil }
        let rectangle = pixels.extent.insetBy(dx: -4, dy: -4)
        let background = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: rectangle)
        let padded = pixels.composited(over: background).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let image = CIContext().createCGImage(padded, from: padded.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
