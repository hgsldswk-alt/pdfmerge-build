import StoreKit
import SwiftUI
import UIKit

@MainActor
struct CardScreen: View {
    @ObservedObject var model: MergeModel
    let content: CardContent
    @Environment(\.dismiss) private var dismiss
    @State private var bitmap: UIImage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    if let bitmap {
                        Image(uiImage: bitmap).resizable().scaledToFit().frame(maxWidth: 295)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .accessibilityLabel(([content.title] + (content.order.map { order in order.slots.indices.map { order.title(at: $0) } } ?? []) + [content.topics]).joined(separator: " · "))
                            .accessibilityIdentifier("card.preview")
                    } else { ProgressView() }
                    MainAction(title: L.t("card.share"), id: "card.share", icon: "square.and.arrow.up") {
                        if let bitmap { model.shareCard(bitmap) }
                    }.disabled(bitmap == nil || model.busy)
                    if let order = content.order {
                        Text(L.t("card.importHint")).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        Button(L.t("template.copyCode")) { if let code = try? order.code() { model.copy(code) } }
                            .frame(minHeight: 44).accessibilityIdentifier("card.copyCode")
                        Button(L.t("template.shareFile")) { model.shareTemplate(order) }
                            .frame(minHeight: 44).accessibilityIdentifier("card.template")
                    }
                    Button(L.t("card.copyTopics")) { model.copy(content.topics) }.frame(minHeight: 44).accessibilityIdentifier("card.copyTopics")
                    ShareFeedback(model: model)
                }.padding(16)
            }.background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle(L.t("card.preview"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L.t("done")) { dismiss() }.accessibilityIdentifier("card.done") } }
        }.task {
            let value = content
            bitmap = await Task.detached(priority: .userInitiated) { ShareCard.render(value) }.value
        }.mergePresentations(model)
            .alert(L.t("error.title"), isPresented: Binding(get: { model.issue != nil }, set: { if !$0 { model.issue = nil } })) {
                Button(L.t("ok")) { model.issue = nil }
            } message: { Text(model.issue?.message ?? "") }
    }
}

@MainActor
struct SettingsScreen: View {
    @ObservedObject var model: MergeModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.requestReview) private var requestReview
    @State private var privacy = false
    @State private var restoring = false

    var body: some View {
        NavigationStack {
            List {
                if !Launch.isFree {
                    Button(L.t("purchase.title")) { model.purchaseSheet = true }.accessibilityIdentifier("settings.pro")
                    Button(L.t("purchase.restore")) {
                        restoring = true
                        Task { await model.restore(); restoring = false }
                    }.accessibilityIdentifier("settings.restore").disabled(restoring)
                }
                Button(L.t("settings.cleanup"), action: model.inspectCleanup).accessibilityIdentifier("settings.cleanup")
                Button(L.t("settings.privacy")) { privacy = true }.accessibilityIdentifier("settings.privacy")
                Button(L.t("settings.rate")) {
                    if Launch.testing { model.shareRequested = true }
                    else if let url = Launch.storeURL, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                        parts.queryItems = [URLQueryItem(name: "action", value: "write-review")]
                        if let address = parts.url { openURL(address) }
                    } else { requestReview() }
                }.accessibilityIdentifier("settings.rate")
                ShareFeedback(model: model)
            }.disabled(model.busy)
                .navigationTitle(L.t("settings"))
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L.t("done")) { dismiss() }.accessibilityIdentifier("settings.done") } }
        }.mergePresentations(model, active: !privacy)
            .sheet(isPresented: $privacy) {
                NavigationStack {
                    ScrollView { Text(L.t("settings.privacyBody")).frame(maxWidth: .infinity, alignment: .leading).padding() }
                        .navigationTitle(L.t("settings.privacy"))
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L.t("done")) { privacy = false }.accessibilityIdentifier("privacy.done") } }
                }
            }
            .alert(L.t("settings.cleanup"), isPresented: Binding(get: { model.cleanupBytes != nil }, set: { if !$0 { model.cleanupBytes = nil } })) {
                Button(L.t("settings.clean"), role: .destructive, action: model.cleanup)
                Button(L.t("cancel"), role: .cancel) {}
            } message: {
                Text(L.f("settings.cleanupDetail", ByteCountFormatter.string(fromByteCount: model.cleanupBytes ?? 0, countStyle: .file)))
            }
            .alert(L.t("error.title"), isPresented: Binding(get: { model.issue != nil && !model.purchaseSheet }, set: { if !$0 { model.issue = nil } })) {
                Button(L.t("ok")) { model.issue = nil }
            } message: { Text(model.issue?.message ?? "") }
    }
}

@MainActor
struct PurchaseScreen: View {
    @ObservedObject var model: MergeModel
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "square.stack.3d.up.fill").font(.system(size: 42)).foregroundStyle(mergeAccent).accessibilityHidden(true)
                    Text(L.t("purchase.title")).font(.largeTitle.bold()).accessibilityIdentifier("purchase.title")
                    Text(L.t("purchase.detail"))
                    Text(L.t("purchase.free"))
                    if model.entitlement?.purchasedPro == true {
                        Label(L.t("purchase.owned"), systemImage: "checkmark.circle.fill").accessibilityIdentifier("purchase.owned")
                    } else {
                        if let state = model.entitlement, model.pro {
                            Text(L.f("purchase.trialEnd", state.trialEnd.formatted(date: .abbreviated, time: .omitted))).accessibilityIdentifier("purchase.trialEnd")
                        } else if model.entitlement != nil { Text(L.t("purchase.expired")).accessibilityIdentifier("purchase.expired") }
                        let paid = model.products.first { $0.id == model.proID }
                        let trial = model.products.first { $0.id == model.trialID }
                        MainAction(title: paid.map { L.f("purchase.price", $0.displayPrice) } ?? (Launch.testing ? L.t("purchase.samplePrice") : L.t("purchase.title")), id: "purchase.buy") {
                            if let paid { perform { await model.purchase(paid) } }
                        }.disabled(paid == nil || working)
                        if model.pro && model.entitlement?.trialReceiptAt == nil {
                            Button(L.t("purchase.claim")) { if let trial { perform { await model.purchase(trial) } } }
                                .accessibilityIdentifier("purchase.claim").frame(minHeight: 44).disabled(trial == nil || working)
                        }
                        if paid == nil && !Launch.testing {
                            Button(L.t("purchase.reload")) { perform { await model.readStore() } }.accessibilityIdentifier("purchase.reload")
                        }
                    }
                    Button(L.t("purchase.restore")) { perform { await model.restore() } }
                        .accessibilityIdentifier("purchase.restore").frame(minHeight: 44).disabled(working)
                }.padding(20)
            }.navigationTitle(L.t("purchase.title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L.t("done")) { dismiss() }.accessibilityIdentifier("purchase.done") } }
        }.alert(L.t("error.title"), isPresented: Binding(get: { model.issue != nil }, set: { if !$0 { model.issue = nil } })) {
            Button(L.t("ok")) { model.issue = nil }
        } message: { Text(model.issue?.message ?? "") }
    }

    private func perform(_ action: @escaping @MainActor () async -> Void) {
        working = true
        Task { await action(); working = false }
    }
}
