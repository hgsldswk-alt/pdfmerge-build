import StoreKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum PickPurpose: Equatable {
    case files, replace(UUID), template, slot(Int), batch(UUID, Int)

    var types: [UTType] { self == .template ? [.mergeTemplate] : [.pdf] }
    var multiple: Bool { self == .files }
}

extension UTType {
    static let mergeTemplate = UTType(exportedAs: "com.hgsldswk.pdfmerge.template", conformingTo: .data)
}

struct ShareJob: Identifiable {
    let id = UUID()
    let items: [Any]
    var temporary: URL?
    var output: UUID?
}

@MainActor
final class MergeModel: ObservableObject {
    @Published private(set) var library = Library()
    @Published private(set) var history = DraftHistory()
    @Published private(set) var ready = false
    @Published private(set) var loadFailed = false
    @Published private(set) var busy = false
    @Published private(set) var products: [Product] = []
    @Published private(set) var entitlement: Entitlement?
    @Published var issue: Issue?
    @Published var organizing = false
    @Published var result: Output?
    @Published var selectedPage: String?
    @Published var purchaseSheet = false
    @Published var shareRequested = false
    @Published var share: ShareJob?
    @Published var reviewCount = 0
    @Published var cleanupBytes: Int64?

    let workspace = Workspace()
    private let vault = EntitlementVault(service: "com.hgsldswk.pdfmerge")
    private var revision = 0
    private var firstSession = true
    private var eligibleReturn = false
    private var operation: Task<Void, Never>?
    private var changes: Task<Void, Never>?
    private var pendingURL: URL?
    private var pendingReview: Task<Void, Never>?
    private var loading = false
    let proID = "com.hgsldswk.pdfmerge.pro"
    let trialID = "com.hgsldswk.pdfmerge.trial"
    var now: Date { Launch.testing ? Date(timeIntervalSince1970: 1_794_571_200) : .now }
    var pro: Bool { Launch.isFree || entitlement?.hasPro(at: now) == true }
    var draft: Draft { history.current }

    func start() async {
        guard !ready, !loading else { return }
        loading = true
        loadFailed = false
        defer { loading = false }
        do {
            let (saved, first) = try await workspace.load(testing: Launch.testing, reset: Launch.arguments.contains("-reset"))
            library = saved
            history = saved.draft
            firstSession = first
            if Launch.testing {
                var state = Entitlement(firstOpen: now)
                state.proStartedAt = Launch.arguments.contains("-expired") ? now.addingTimeInterval(-31 * 86_400) : now
                entitlement = state
            } else {
                await refreshClock()
            }
            if Launch.testing && Launch.arguments.contains("-sample-template") && library.templates.isEmpty {
                library.templates = [SavedTemplate(title: L.t("card.sample"), order: .sample, includeDate: true)]
            }
            try await persist()
            ready = true
            if let url = pendingURL { pendingURL = nil; openTemplate(url) }
            if Launch.testing && Launch.arguments.contains("-paywall") { purchaseSheet = true }
            if !Launch.testing && !Launch.isFree { observeStore() }
        } catch { loadFailed = true; self.issue = Issue.storage(error) }
    }

    func refreshClock() async {
        guard !Launch.testing else { return }
        do {
            entitlement = try await vault.update(at: .now, free: Launch.isFree)
        } catch {}
    }

    private func observeStore() {
        changes = Task { [weak self] in
            for await update in StoreKit.Transaction.updates {
                guard let self else { return }
                await self.apply(update)
            }
        }
        Task { await readStore() }
    }

    func readStore() async {
        guard !Launch.testing, !Launch.isFree else { return }
        for await item in StoreKit.Transaction.currentEntitlements { await apply(item, finish: false) }
        if let latest = await StoreKit.Transaction.latest(for: proID) { await apply(latest, finish: false) }
        if let latest = await StoreKit.Transaction.latest(for: trialID) { await apply(latest, finish: false) }
        if let loaded = try? await Product.products(for: [proID, trialID]) { products = loaded }
    }

    private func apply(_ update: VerificationResult<StoreKit.Transaction>, finish: Bool = true) async {
        guard case .verified(let transaction) = update, [proID, trialID].contains(transaction.productID) else { return }
        let isPro = transaction.productID == proID
        do {
            entitlement = try await vault.update(at: .now, free: false) { state in
                if isPro { state.purchasedPro = transaction.revocationDate == nil }
                else if transaction.revocationDate == nil { state.recordTrial(transaction.originalPurchaseDate) }
            }
            if finish { await transaction.finish() }
        } catch { self.issue = .purchaseFailed }
    }

    func purchase(_ product: Product) async {
        do {
            if case .success(let result) = try await product.purchase() {
                guard case .verified = result else { issue = .purchaseFailed; return }
                await apply(result)
            }
        } catch { self.issue = .purchaseFailed }
    }

    func restore() async {
        guard !Launch.testing else { return }
        do { try await AppStore.sync(); await readStore() }
        catch { self.issue = .purchaseFailed }
    }

    private func persist() async throws {
        library.draft = history
        revision += 1
        try await workspace.save(library, revision: revision)
    }

    private func saveSoon() {
        Task {
            do { try await persist() }
            catch { self.issue = Issue.storage(error) }
        }
    }

    func edit(_ action: (inout Draft) -> Void) {
        history.edit(action)
        if !draft.pages.contains(where: { $0.id == selectedPage }) { selectedPage = nil }
        saveSoon()
    }

    func undo() { history.undo(); selectedPage = nil; saveSoon() }

    func closeWork() {
        result = nil
        organizing = false
        selectedPage = nil
        shareRequested = false
        guard eligibleReturn, !firstSession, share == nil, !purchaseSheet else { return }
        eligibleReturn = false
        pendingReview?.cancel()
        pendingReview = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, !organizing, result == nil, share == nil, !purchaseSheet else { return }
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
            if library.stats.request(version: version, firstSession: firstSession) { reviewCount += 1; saveSoon() }
        }
    }

    func cancelReview() { pendingReview?.cancel() }

    func startWork(_ body: @escaping @MainActor () async throws -> Void) {
        guard ready, !busy else { return }
        busy = true
        cancelReview()
        operation = Task {
            defer { busy = false; operation = nil }
            do { try await body() }
            catch is CancellationError {}
            catch { self.issue = Issue.storage(error) }
        }
    }

    func cancel() { operation?.cancel() }

    func openTemplate(_ url: URL) {
        if !ready { pendingURL = url; return }
        guard url.pathExtension.lowercased() == "pdfmergetemplate" else { return }
        importFiles([url], purpose: .template)
    }

    func importFiles(_ urls: [URL], purpose: PickPurpose) {
        guard let first = urls.first else { return }
        startWork {
            if purpose == .template { try self.activate(await self.workspace.template(at: first)); return }
            var sources: [Source] = []
            do {
                for url in (purpose.multiple ? urls : [first]) {
                    try Task.checkCancellation()
                    sources.append(try await self.workspace.add(url))
                }
                try Task.checkCancellation()
            } catch {
                await self.workspace.discard(sources)
                throw error
            }
            guard let source = sources.first else { return }
            switch purpose {
            case .files:
                self.edit { draft in sources.forEach { draft.add($0) } }
                self.organizing = true
            case .replace(let id): self.edit { $0.add(source, replacing: id) }
            case .slot(let index): self.library.slots[index] = source
            case .batch(let id, let index):
                if let group = self.library.batch?.groups.firstIndex(where: { $0.id == id }) {
                    self.library.batch?.groups[group].files[index] = source
                }
            case .template: break
            }
            try await self.persist()
        }
    }

    func activate(_ order: PublicTemplate) throws {
        _ = try order.encoded()
        use(SavedTemplate(title: L.t("card.order"), order: order))
    }

    func use(_ template: SavedTemplate) {
        library.activeTemplate = template
        library.slots = [:]
        saveSoon()
    }

    func clearSlot(_ index: Int) { library.slots.removeValue(forKey: index); saveSoon() }
    func acceptSlot(_ index: Int) { library.slots[index]?.issue = nil; saveSoon() }

    func applyTemplate() {
        guard let template = library.activeTemplate else { return }
        let group = BatchGroup(files: library.slots)
        guard let arranged = group.draft(for: template.order) else { return }
        edit { $0 = arranged }
        organizing = true
    }

    func saveTemplate(_ template: SavedTemplate) {
        if let index = library.templates.firstIndex(where: { $0.id == template.id }) {
            let previous = library.templates[index]
            guard pro || (template.prefix == previous.prefix && template.includeDate == previous.includeDate &&
                         template.includeSequence == previous.includeSequence) else { purchaseSheet = true; return }
            library.templates[index] = template
        } else {
            guard library.templates.isEmpty || pro else { purchaseSheet = true; return }
            library.templates.append(template)
        }
        if library.activeTemplate?.id == template.id {
            if library.activeTemplate?.order != template.order { library.slots = [:] }
            library.activeTemplate = template
        }
        saveSoon()
    }

    func deleteTemplate(_ id: UUID) { library.templates.removeAll { $0.id == id }; saveSoon() }

    func suggestedOrder() -> PublicTemplate? {
        let sourceOrder = draft.sources.map(\.id).filter { id in draft.pages.contains { $0.source == id } }
        if let active = library.activeTemplate?.order,
           sourceOrder.count == active.slots.count,
           sourceOrder == active.slots.indices.compactMap({ library.slots[$0]?.id }) { return active }
        if Launch.testing && Launch.arguments.contains("-store-shots"), sourceOrder.count == 3 { return .sample }
        guard (1...PublicTemplate.limit).contains(sourceOrder.count) else { return nil }
        return PublicTemplate(sourceOrder.map { _ in .material })
    }

    func generate() {
        let snapshot = draft
        guard snapshot.canGenerate, result == nil else { return }
        let draftRevision = history.revision
        if let existing = library.history.first(where: { $0.draftRevision == draftRevision }) {
            openOutput(existing)
            return
        }
        let order = suggestedOrder()
        let active = library.activeTemplate.flatMap { template in
            snapshot.sources.map(\.id) == template.order.slots.indices.compactMap { library.slots[$0]?.id } ? template : nil
        }
        startWork {
            let name = active?.filename(date: self.now, sequence: self.library.stats.generated + 1, useRules: self.pro)
            do {
                let output = try await self.write(snapshot, order: order, name: name, draftRevision: draftRevision)
                self.eligibleReturn = false
                self.shareRequested = false
                self.result = output
            } catch let failure as PDFWork.SourceFailure {
                self.edit { draft in
                    if let index = draft.sources.firstIndex(where: { $0.id == failure.id }) {
                        draft.sources[index].issue = failure.issue
                    }
                }
            }
        }
    }

    @discardableResult
    private func write(_ draft: Draft, order: PublicTemplate?, name: String? = nil, draftRevision: Int? = nil,
                       batchIndex: Int? = nil) async throws -> Output {
        let suggestion = name ?? "\(L.t("output.default"))-\(Naming.day(now))"
        let output = Output(name: Naming.unique(suggestion, existing: library.history), pageCount: draft.pages.count,
                            fileCount: draft.usedSources, date: now, order: order, draftRevision: draftRevision)
        try await workspace.write(draft, output: output)
        let previous = library.stats
        let previousGroup = batchIndex.flatMap { library.batch?.groups[$0] }
        library.history.insert(output, at: 0)
        library.stats.generated(output.id)
        if let batchIndex {
            library.batch?.groups[batchIndex].result = output.id
            library.batch?.groups[batchIndex].issue = nil
        }
        do { try await persist() }
        catch {
            library.history.removeAll { $0.id == output.id }
            library.stats = previous
            if let batchIndex, let previousGroup { library.batch?.groups[batchIndex] = previousGroup }
            try? await workspace.clean("outputs", retaining: Set(library.history.map(\.id)))
            throw error
        }
        return output
    }

    func openOutput(_ output: Output) { cancelReview(); eligibleReturn = false; shareRequested = false; result = output }

    func rename(_ output: Output, to name: String) {
        guard let index = library.history.firstIndex(where: { $0.id == output.id }), !Naming.clean(name).isEmpty else { return }
        library.history[index].name = Naming.unique(name, existing: library.history, except: output.id)
        result = library.history[index]
        saveSoon()
    }

    func sharePDF(_ output: Output) {
        shareRequested = false
        eligibleReturn = false
        startWork {
            let url = try await self.workspace.handoff(output: output)
            if Task.isCancelled { await self.workspace.finishSharing(url); throw CancellationError() }
            self.present(ShareJob(items: [url], temporary: url, output: output.id))
        }
    }

    func shareTemplate(_ order: PublicTemplate) {
        shareRequested = false
        startWork {
            let url = try await self.workspace.handoff(template: order)
            if Task.isCancelled { await self.workspace.finishSharing(url); throw CancellationError() }
            self.present(ShareJob(items: [url], temporary: url))
        }
    }

    func shareCard(_ image: UIImage) {
        shareRequested = false
        present(ShareJob(items: [image]))
    }

    func copy(_ text: String) {
        if !Launch.testing { UIPasteboard.general.string = text }
        shareRequested = true
    }

    private func present(_ job: ShareJob) {
        cancelReview()
        if Launch.testing {
            shareRequested = true
            finish(job, delivered: false)
        } else { share = job }
    }

    func finish(_ job: ShareJob, delivered: Bool) {
        share = nil
        if let url = job.temporary { Task { await workspace.finishSharing(url) } }
        guard let output = job.output, delivered else { return }
        library.stats.delivered(output, on: now)
        eligibleReturn = result?.id == output
        saveSoon()
    }

    func acknowledge(_ output: UUID) { library.stats.acknowledge(output); saveSoon() }

    func beginBatch(_ template: SavedTemplate) -> Bool {
        guard pro else { purchaseSheet = true; return false }
        if library.batch?.template.id != template.id || library.batch?.template.order != template.order {
            library.batch = BatchPlan(template: template)
        } else if library.batch?.template.order == template.order {
            library.batch?.template = template
        }
        saveSoon()
        return true
    }

    func addGroup() { library.batch?.groups.append(BatchGroup()); saveSoon() }

    func removeBatchFile(_ group: UUID, slot: Int, allow: Bool) {
        guard let index = library.batch?.groups.firstIndex(where: { $0.id == group }) else { return }
        if allow { library.batch?.groups[index].files[slot]?.issue = nil }
        else { library.batch?.groups[index].files.removeValue(forKey: slot) }
        saveSoon()
    }

    func generateBatch(only id: UUID? = nil) {
        guard pro else { purchaseSheet = true; return }
        guard let batch = library.batch else { return }
        startWork {
            for (index, group) in batch.groups.enumerated() where group.result == nil && (id == nil || id == group.id) {
                try Task.checkCancellation()
                guard let draft = group.draft(for: batch.template.order) else {
                    self.library.batch?.groups[index].issue = .invalidPDF
                    continue
                }
                do {
                    let name = batch.template.filename(date: self.now, sequence: index + 1, useRules: true)
                    try await self.write(draft, order: batch.template.order, name: name, batchIndex: index)
                } catch is CancellationError { throw CancellationError() }
                catch let failure as PDFWork.SourceFailure {
                    if let slot = group.files.first(where: { $0.value.id == failure.id })?.key {
                        self.library.batch?.groups[index].files[slot]?.issue = failure.issue
                    }
                    self.library.batch?.groups[index].issue = failure.issue
                } catch { self.library.batch?.groups[index].issue = Issue.storage(error) }
            }
            try await self.persist()
        }
    }

    private var retained: Set<UUID> {
        var ids = Set<UUID>()
        for d in [draft] + history.previous {
            for s in d.sources { ids.insert(s.id) }
        }
        for s in library.slots.values { ids.insert(s.id) }
        for g in library.batch?.groups ?? [] {
            for f in g.files.values { ids.insert(f.id) }
        }
        return ids
    }

    func inspectCleanup() {
        startWork {
            let sources = try await self.workspace.bytes(in: "sources", retaining: self.retained)
            let outputs = try await self.workspace.bytes(in: "outputs", retaining: Set(self.library.history.map(\.id)))
            self.cleanupBytes = sources + outputs
        }
    }

    func cleanup() {
        startWork {
            try await self.workspace.clean("sources", retaining: self.retained)
            try await self.workspace.clean("outputs", retaining: Set(self.library.history.map(\.id)))
        }
    }

    func deleteOutput(_ output: Output) {
        startWork {
            let previous = self.library
            self.library.history.removeAll { $0.id == output.id }
            if let index = self.library.batch?.groups.firstIndex(where: { $0.result == output.id }) {
                self.library.batch?.groups[index].result = nil
            }
            self.library.stats.acknowledge(output.id)
            do { try await self.persist() }
            catch { self.library = previous; throw error }
            try await self.workspace.clean("outputs", retaining: Set(self.library.history.map(\.id)))
        }
    }
}
