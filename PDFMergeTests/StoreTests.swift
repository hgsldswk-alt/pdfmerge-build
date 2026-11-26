import StoreKit
import StoreKitTest
import XCTest

final class StoreTests: XCTestCase {
    func testVerifiedStoreKitTransactionsAndRestoredEntitlement() async throws {
        let configuration = try XCTUnwrap(Bundle(for: StoreTests.self).url(forResource: "PDFMerge", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: configuration)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }
        let paid = "com.hgsldswk.pdfmerge.pro"
        let trial = "com.hgsldswk.pdfmerge.trial"
        let products = try await Product.products(for: [paid, trial])
        XCTAssertEqual(Set(products.map(\.id)), [paid, trial])
        XCTAssertTrue(products.allSatisfy { $0.type == .nonConsumable })
        _ = try await session.buyProduct(identifier: trial, options: [])
        _ = try await session.buyProduct(identifier: paid, options: [])
        try await AppStore.sync()
        var restored = Entitlement(firstOpen: .now)
        var observed: Set<String> = []
        for await entry in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = entry, transaction.revocationDate == nil else { continue }
            observed.insert(transaction.productID)
            if transaction.productID == paid { restored.purchasedPro = true }
            if transaction.productID == trial { restored.recordTrial(transaction.originalPurchaseDate) }
        }
        XCTAssertEqual(observed, [trial, paid])
        XCTAssertNotNil(restored.trialReceiptAt)
        XCTAssertTrue(restored.hasPro(at: restored.trialEnd.addingTimeInterval(86_400)))
    }
}
