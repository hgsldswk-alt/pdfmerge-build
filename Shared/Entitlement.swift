import Foundation
import Security

struct Entitlement: Codable, Equatable {
    var firstOpen: Date
    var proStartedAt: Date?
    var trialReceiptAt: Date?
    var purchasedPro = false
    var latestSeen: Date?

    init(firstOpen: Date = .now) { self.firstOpen = firstOpen }

    var trialStart: Date {
        let local = proStartedAt ?? firstOpen
        return min(local, trialReceiptAt ?? local)
    }

    var trialEnd: Date { trialStart.addingTimeInterval(30 * 86_400) }

    mutating func observe(_ now: Date, free: Bool) {
        let effective = max(latestSeen ?? now, now)
        latestSeen = effective
        if !free && proStartedAt == nil { proStartedAt = effective }
    }

    func hasPro(at now: Date, free: Bool = Launch.isFree) -> Bool {
        let effective = max(now, latestSeen ?? now)
        return free || purchasedPro || (effective >= trialStart && effective < trialEnd)
    }

    mutating func recordTrial(_ date: Date) { trialReceiptAt = min(trialReceiptAt ?? date, date) }
}

actor EntitlementVault {
    let service: String

    init(service: String) {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "entitlement-v1"]
    }

    func read() throws -> Entitlement? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &found)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = found as? Data else { throw Issue.unreadable }
        return try JSONDecoder().decode(Entitlement.self, from: data)
    }

    func save(_ state: Entitlement) throws {
        let update: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(state)]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(update) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Issue.writeFailed }
        } else if status != errSecSuccess { throw Issue.writeFailed }
    }

    func update(at now: Date, free: Bool, edit: (inout Entitlement) -> Void = { _ in }) throws -> Entitlement {
        var state = try read() ?? Entitlement(firstOpen: now)
        state.observe(now, free: free)
        edit(&state)
        try save(state)
        return state
    }
}
