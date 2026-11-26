import StoreKit
import SwiftUI
import UIKit

@main
@MainActor
struct PDFMergeApp: App {
    var body: some Scene {
        WindowGroup {
            if Launch.hostedTests { Color.clear } else { MergeScreen() }
        }
    }
}

enum Sheet: Identifiable {
    case settings, templates, card
    case photos(PhotoExportTarget)

    var id: String {
        switch self {
        case .settings: return "settings"
        case .templates: return "templates"
        case .card: return "card"
        case .photos: return "photos"
        }
    }
}

enum PickRoute: Identifiable {
    case system(PickPurpose), samples(PickPurpose)
    var id: String {
        switch self {
        case .system: return "system"
        case .samples: return "samples"
        }
    }

    static func pdf(_ purpose: PickPurpose) -> Self {
        Launch.testing && Launch.arguments.contains("-fixtures") ? .samples(purpose) : .system(purpose)
    }
}

struct ActivitySheet: UIViewControllerRepresentable {
    let job: ShareJob
    let finished: (Bool) -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: job.items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, error in
            DispatchQueue.main.async { finished(completed && error == nil) }
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct FilePicker: UIViewControllerRepresentable {
    let purpose: PickPurpose
    let finish: ([URL]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(finish) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: purpose.types, asCopy: false)
        controller.allowsMultipleSelection = purpose.multiple
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let finish: ([URL]) -> Void
        init(_ finish: @escaping ([URL]) -> Void) { self.finish = finish }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish([]) }
    }
}

let mergeBlue = Color(red: 36 / 255, green: 70 / 255, blue: 184 / 255)
let mergeAccent = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark ? UIColor(red: 0.69, green: 0.79, blue: 1, alpha: 1)
        : UIColor(red: 36 / 255, green: 70 / 255, blue: 184 / 255, alpha: 1)
})

struct MainAction: View {
    let title: String
    let id: String
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                if let icon { Image(systemName: icon).accessibilityHidden(true) }
                Text(title)
            }
            .font(.headline)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.borderedProminent)
        .tint(mergeBlue)
        .accessibilityIdentifier(id)
    }
}

@MainActor
struct MergeScreen: View {
    @StateObject private var model = MergeModel()
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var phase
    @State private var sheet: Sheet?
    @State private var card: CardContent?
    @State private var picker: PickRoute?
    @State private var rename = false
    @State private var newName = ""
    @State private var confirmingSource: Source?
    @State private var delete: Output?
    @State private var savingTemplate = false
    @State private var swipedSource: UUID?

    private var reviewHome: Bool {
        model.ready && !model.busy && !model.purchaseSheet && model.share == nil && model.issue == nil
            && sheet == nil && picker == nil && !rename && confirmingSource == nil && delete == nil
            && (!model.organizing || model.result != nil)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let output = model.result { result(output) }
                else if model.organizing { editor }
                else { home }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(L.t(model.result != nil ? "result.title" : model.organizing ? "edit.title" : "app.name"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .task { await model.start() }
        .onChange(of: phase) { _, next in
            if next == .active { Task { if model.ready { await model.refreshClock() } } }
            else { model.cancelReview() }
        }
        .reviewAfterCoreAction(when: reviewHome, alreadyRequested: model.reviewedThisVersion) {
            requestReview()
            model.markReviewRequested()
        }
        .task(id: reviewHome && model.reviewCount > 0 && model.result == nil && phase == .active) {
            guard reviewHome, model.reviewCount > 0, model.result == nil, phase == .active else { return }
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            guard !Task.isCancelled, reviewHome, !model.reviewedThisVersion else { return }
            if CoreReview.shared.attempt({ requestReview() }) { model.markReviewRequested() }
        }
        .onOpenURL { model.openTemplate($0); savingTemplate = false; sheet = .templates }
        .sheet(item: $sheet, onDismiss: { model.shareRequested = false }) { shown in
            switch shown {
            case .settings: SettingsScreen(model: model)
            case .templates: TemplateScreen(model: model, initialOrder: savingTemplate ? model.suggestedOrder() : nil, dismiss: { sheet = nil })
            case .card:
                if let card { CardScreen(model: model, content: card) }
            case .photos(let target):
                PhotoExportScreen(target: target, model: model) { sheet = nil }
            }
        }
        .sheet(item: $picker) { route in RoutedPicker(model: model, route: route) { picker = nil } }
        .mergePresentations(model, active: sheet == nil)
        .alert(L.t("error.title"), isPresented: Binding(get: { model.issue != nil }, set: { if !$0 { model.issue = nil } })) {
            Button(L.t("ok")) { model.issue = nil }
        } message: { Text(model.issue?.message ?? "") }
        .alert(L.t("result.rename"), isPresented: $rename) {
            TextField(L.t("result.name"), text: $newName)
            Button(L.t("save")) { if let output = model.result { model.rename(output, to: newName) } }
            Button(L.t("cancel"), role: .cancel) {}
        }
        .alert(L.t("interactive.title"), isPresented: Binding(get: { confirmingSource != nil }, set: { if !$0 { confirmingSource = nil } }), presenting: confirmingSource) { source in
            Button(L.t("interactive.allow")) { model.edit { $0.allow(source.id) } }
            Button(L.t("cancel"), role: .cancel) {}
        } message: { _ in Text(L.t("issue.interactivePDF")) }
        .alert(L.t("delete.title"), isPresented: Binding(get: { delete != nil }, set: { if !$0 { delete = nil } }), presenting: delete) { output in
            Button(L.t("remove"), role: .destructive) { model.deleteOutput(output) }
            Button(L.t("cancel"), role: .cancel) {}
        } message: { _ in Text(L.t("delete.copy")) }
        .safeAreaInset(edge: .top, spacing: 0) { if model.busy { WorkBanner(model: model) } }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if model.result != nil || model.organizing {
            ToolbarItem(placement: .topBarLeading) {
                Button(L.t("back")) { model.closeWork() }.accessibilityIdentifier("work.back").disabled(model.busy)
            }
        }
        if model.result == nil {
            ToolbarItem(placement: .topBarTrailing) {
                if model.organizing {
                    Button(L.t("edit.add")) { choose() }.accessibilityIdentifier("edit.add").disabled(model.busy)
                } else {
                    Button(L.t("settings")) { model.cancelReview(); sheet = .settings }
                        .accessibilityIdentifier("home.settings").disabled(!model.ready || model.busy)
                }
            }
        }
    }

    private func choose() {
        model.cancelReview()
        picker = .pdf(.files)
    }

    private func exportPhotos(_ target: PhotoExportTarget) {
        guard model.ready, !model.busy else { return }
        model.cancelReview()
        guard model.pro else { model.purchaseSheet = true; return }
        sheet = .photos(target)
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "doc.on.doc.fill").font(.system(size: 33)).foregroundStyle(mergeAccent).accessibilityHidden(true)
                    Text(L.t("home.title")).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    Text(L.t("home.subtitle")).foregroundStyle(.secondary)
                    MainAction(title: L.t("home.pick"), id: "home.pick", icon: "plus", action: choose)
                }
                .padding(20)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
                if !model.draft.sources.isEmpty {
                    homeLink("home.resume", icon: "arrow.uturn.forward", id: "home.resume") { model.cancelReview(); model.organizing = true }
                }
                homeLink("home.templates", icon: "square.and.arrow.down", id: "home.templates") {
                    model.cancelReview(); savingTemplate = false; sheet = .templates
                }
                if !model.library.history.isEmpty {
                    Text(L.t("home.recent")).font(.headline).accessibilityAddTraits(.isHeader)
                    ForEach(model.library.history) { output in
                        Button { model.openOutput(output) } label: {
                            HStack {
                                Image(systemName: "doc.fill").foregroundStyle(mergeAccent).accessibilityHidden(true)
                                VStack(alignment: .leading) {
                                    Text(output.name).foregroundStyle(.primary)
                                    Text(L.f("pages.count", output.pageCount)).font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary).accessibilityHidden(true)
                            }.padding(14).frame(minHeight: 48)
                        }
                        .buttonStyle(.plain)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityIdentifier("home.recent.\(model.library.history.firstIndex(of: output) ?? 0)")
                        .contextMenu { Button(L.t("delete.title"), role: .destructive) { delete = output } }
                    }
                }
                if !model.ready && !model.loadFailed { ProgressView().accessibilityIdentifier("home.loading") }
            }.padding(18).disabled(!model.ready || model.busy)
            if model.loadFailed {
                Button(L.t("retry")) { Task { await model.start() } }.accessibilityIdentifier("home.retry")
            }
        }
    }

    private func homeLink(_ key: String, icon: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon).foregroundStyle(mergeAccent).accessibilityHidden(true)
                Text(L.t(key)).font(.headline).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary).accessibilityHidden(true)
            }.padding(14).frame(minHeight: 48)
        }.buttonStyle(.plain)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityIdentifier(id)
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                heading("edit.files", hint: "edit.groupsHint")
                if model.draft.mixed {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle").accessibilityHidden(true)
                        Text(L.t("edit.mixed")).accessibilityIdentifier("edit.mixed")
                    }.font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(Array(model.draft.sources.enumerated()), id: \.element.id) { index, source in
                    sourceRow(source, index: index)
                }
                if model.draft.sources.count == 1, let source = model.draft.sources.first, source.canExportPhotos {
                    PhotoExportAction(id: "edit.photos.0") { exportPhotos(.source(source)) }
                }
                heading("edit.pages", hint: "edit.pagesHint").padding(.top, 4)
                if model.draft.pages.isEmpty { Text(L.t("edit.empty")).foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 91), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(Array(model.draft.pages.enumerated()), id: \.element.id) { index, page in pageTile(page, index: index) }
                }
            }.padding(16).disabled(model.busy)
        }.safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                if let selected = model.selectedPage {
                    HStack {
                        Button { model.edit { $0.rotate(selected) } } label: { Label(L.t("edit.rotate"), systemImage: "rotate.right").frame(minHeight: 44) }
                            .accessibilityIdentifier("edit.rotate")
                        Button(role: .destructive) { model.edit { $0.removePage(selected) } } label: { Label(L.t("remove"), systemImage: "trash").frame(minHeight: 44) }
                            .accessibilityIdentifier("edit.removePage")
                    }.buttonStyle(.bordered).disabled(model.busy)
                }
                HStack {
                    Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 48) }
                        .accessibilityLabel(L.t("edit.undo")).accessibilityIdentifier("edit.undo")
                        .disabled(model.busy || model.history.previous.isEmpty)
                    MainAction(title: L.t(model.draft.usedSources == 1 ? "edit.generateAndShare" : "edit.mergeAndShare"), id: "edit.generate") {
                        model.generate()
                    }.disabled(model.busy || !model.draft.canGenerate)
                }
                if model.draft.canGenerate, model.suggestedOrder() != nil {
                    Button(L.t("edit.generateAndShareCard")) { model.generate(delivery: .orderCard) }
                        .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                        .accessibilityIdentifier("edit.shareOrder").disabled(model.busy)
                }
            }.padding(.horizontal, 16).padding(.vertical, 6).background(.regularMaterial)
        }
    }

    private func heading(_ key: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L.t(key)).font(.headline).accessibilityAddTraits(.isHeader)
            Text(L.t(hint)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func sourceRow(_ source: Source, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(index + 1)").font(.caption.bold()).foregroundStyle(mergeAccent).accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text(source.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                        .contextMenu {
                            if index > 0 { moveToTopButton(source) }
                        }
                    Text(source.issue?.message ?? L.f("pages.count", source.pageCount)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if model.draft.sources.count > 1, source.canExportPhotos {
                    PhotoExportAction(id: "edit.photos.\(index)", compact: true) { exportPhotos(.source(source)) }
                }
                Menu {
                    if index > 0 {
                        Button(L.t("edit.file.moveEarlier")) { moveSource(source, by: -1) }
                        moveToTopButton(source)
                    }
                    if index + 1 < model.draft.sources.count {
                        Button(L.t("edit.file.moveLater")) { moveSource(source, by: 1) }
                    }
                    Button(L.t("remove"), role: .destructive) { model.edit { $0.removeSource(source.id) } }
                } label: { Image(systemName: "line.3.horizontal").frame(width: 44, height: 44) }
                .accessibilityLabel(L.f("edit.moveFile", source.name))
                .accessibilityIdentifier("edit.file.\(index)")
                .draggable("file:\(source.id.uuidString)")
                .accessibilityAction(named: Text(L.t("edit.file.moveEarlier"))) {
                    moveSource(source, by: -1)
                }
                .accessibilityAction(named: Text(L.t("edit.file.moveToTop"))) {
                    moveSourceToTop(source)
                }
                .accessibilityAction(named: Text(L.t("edit.file.moveLater"))) {
                    moveSource(source, by: 1)
                }
            }
            if source.issue != nil || swipedSource == source.id {
                HStack {
                    if source.issue != nil {
                        Button(L.t("reselect")) { picker = .pdf(.replace(source.id)) }.accessibilityIdentifier("edit.replace.\(index)")
                    }
                    if source.issue == .interactivePDF {
                        Button(L.t("interactive.review")) { confirmingSource = source }.accessibilityIdentifier("edit.allow.\(index)")
                    }
                    Button(L.t("remove"), role: .destructive) {
                        swipedSource = nil; model.edit { $0.removeSource(source.id) }
                    }.accessibilityIdentifier("edit.remove.\(index)")
                }.buttonStyle(.bordered).controlSize(.large)
            }
        }.padding(.horizontal, 10).padding(.vertical, 3)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 13))
            .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
                let width = value.translation.width
                if abs(width) > abs(value.translation.height) * 1.8 { swipedSource = width < 0 ? source.id : nil }
            })
            .dropDestination(for: String.self) { items, _ in
                guard !model.busy, let item = items.first, item.hasPrefix("file:"),
                      let moved = UUID(uuidString: String(item.dropFirst(5))) else { return false }
                moveSource(moved, to: source.id)
                return true
            }
    }

    private func moveToTopButton(_ source: Source) -> some View {
        Button(L.t("edit.file.moveToTop")) { moveSourceToTop(source) }
            .accessibilityIdentifier("edit.file.moveToTop")
    }

    private func moveSourceToTop(_ source: Source) {
        guard let first = model.draft.sources.first else { return }
        moveSource(source.id, to: first.id)
    }

    private func moveSource(_ source: Source, by step: Int) {
        let sources = model.draft.sources
        guard let index = sources.firstIndex(where: { $0.id == source.id }),
              sources.indices.contains(index + step) else { return }
        moveSource(source.id, to: sources[index + step].id)
    }

    private func moveSource(_ source: UUID, to target: UUID) {
        guard !model.busy, source != target else { return }
        model.edit { $0.moveSource(source, to: target) }
    }

    private func pageTile(_ page: Page, index: Int) -> some View {
        let name = model.draft.sources.first { $0.id == page.source }?.name ?? ""
        return Button { model.selectedPage = model.selectedPage == page.id ? nil : page.id } label: {
            VStack(spacing: 3) {
                Thumbnail(workspace: model.workspace, page: page).frame(height: 65).accessibilityHidden(true)
                Text(L.f("page.label", index + 1, name)).font(.caption2.weight(.medium)).lineLimit(1)
            }.padding(5).frame(maxWidth: .infinity, minHeight: 80)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(model.selectedPage == page.id ? mergeAccent : Color.secondary.opacity(0.24), lineWidth: model.selectedPage == page.id ? 2 : 1))
        }.buttonStyle(.plain)
            .accessibilityIdentifier("edit.page.\(index)")
            .accessibilityAddTraits(model.selectedPage == page.id ? .isSelected : [])
            .draggable("page:\(page.id)")
            .dropDestination(for: String.self) { items, _ in
                guard !model.busy, let item = items.first, item.hasPrefix("page:") else { return false }
                model.edit { $0.movePage(String(item.dropFirst(5)), to: page.id) }
                return true
            }
            .accessibilityAction(named: Text(L.t("move.earlier"))) { movePage(page, from: index, by: -1) }
            .accessibilityAction(named: Text(L.t("move.later"))) { movePage(page, from: index, by: 1) }
    }

    private func movePage(_ page: Page, from index: Int, by step: Int) {
        let target = index + step
        model.edit { draft in
            if draft.pages.indices.contains(target) {
                let id = draft.pages[target].id
                draft.movePage(page.id, to: id)
            }
        }
    }

    private func result(_ output: Output) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 45)).foregroundStyle(mergeAccent).accessibilityHidden(true)
                Text(L.t("result.ready")).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                Text(output.name).font(.headline).accessibilityIdentifier("result.name")
                Text(L.f("result.count", output.fileCount, output.pageCount)).foregroundStyle(.secondary)
                Text(L.t("result.originals")).font(.footnote).foregroundStyle(.secondary)
                MainAction(title: L.t("result.share"), id: "result.share", icon: "square.and.arrow.up") { model.sharePDF(output) }
                PhotoExportAction(id: "result.photos") { exportPhotos(.output(output)) }
                Button { newName = (output.name as NSString).deletingPathExtension; rename = true } label: {
                    Text(L.t("result.rename")).frame(minHeight: 44).contentShape(Rectangle())
                }
                    .accessibilityIdentifier("result.rename")
                if let order = output.order {
                    Button { card = .order(order); sheet = .card } label: {
                        Text(L.t("result.card")).frame(minHeight: 44).contentShape(Rectangle())
                    }
                        .accessibilityIdentifier("result.card")
                }
                if model.organizing, model.suggestedOrder() != nil {
                    Button { savingTemplate = true; sheet = .templates } label: {
                        Text(L.t("result.template")).frame(minHeight: 44).contentShape(Rectangle())
                    }
                        .accessibilityIdentifier("result.template")
                }
                if let milestone = model.library.stats.pendingMilestones[output.id] {
                    Button {
                        card = .milestone(milestone); sheet = .card; model.acknowledge(output.id)
                    } label: {
                        Text(L.t("result.milestone")).frame(minHeight: 44).contentShape(Rectangle())
                    }.accessibilityIdentifier("result.milestone")
                }
                ShareFeedback(model: model)
            }.padding(20).disabled(model.busy)
        }
    }
}

struct Thumbnail: View {
    let workspace: Workspace
    let page: Page
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "doc").foregroundStyle(.secondary) }
        }.task(id: page) {
            let rendered = await workspace.thumbnail(page)
            if !Task.isCancelled { image = rendered }
        }
    }
}

@MainActor
struct WorkBanner: View {
    @ObservedObject var model: MergeModel
    var body: some View {
        HStack {
            ProgressView()
            Text(L.t("working"))
            Spacer()
            Button(action: model.cancel) {
                Text(L.t("cancel")).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .accessibilityIdentifier("work.cancel")
        }.padding(.horizontal, 16).background(.regularMaterial)
    }
}

@MainActor
struct ShareFeedback: View {
    @ObservedObject var model: MergeModel
    var body: some View {
        if model.shareRequested { Text(L.t("share.ready")).font(.footnote).accessibilityIdentifier("share.requested") }
    }
}

extension View {
    @MainActor
    func mergePresentations(_ model: MergeModel, active: Bool = true) -> some View {
        sheet(isPresented: Binding(get: { active && model.purchaseSheet }, set: { if !$0 && active { model.purchaseSheet = false } })) {
            PurchaseScreen(model: model)
        }.sheet(item: Binding(get: { active ? model.share : nil }, set: { if active { model.share = $0 } })) { job in
            ActivitySheet(job: job) { model.finish(job, delivered: $0) }.interactiveDismissDisabled()
        }
    }
}

@MainActor
struct SamplePicker: View {
    @ObservedObject var model: MergeModel
    let purpose: PickPurpose
    let finish: ([URL]) -> Void
    @State private var files: [URL] = []
    @State private var selected: [URL] = []
    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(files.enumerated()), id: \.offset) { index, file in
                    Button {
                        if selected.contains(file) { selected.removeAll { $0 == file } }
                        else if purpose.multiple { selected.append(file) }
                        else { selected = [file] }
                    } label: {
                        Label(file.lastPathComponent, systemImage: selected.contains(file) ? "checkmark.circle.fill" : "circle")
                    }.accessibilityIdentifier("fixtures.file.\(index)")
                        .accessibilityAddTraits(selected.contains(file) ? .isSelected : [])
                }
            }.navigationTitle(L.t(purpose == .template ? "template.openFile" : "fixtures.title"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L.t("cancel")) { finish([]) }.accessibilityIdentifier("fixtures.cancel") }
                    ToolbarItem(placement: .confirmationAction) { Button(L.t("open")) { finish(selected) }.accessibilityIdentifier("fixtures.open").disabled(selected.isEmpty) }
                }
        }.task { files = (try? await model.workspace.fixtures(template: purpose == .template)) ?? [] }
    }
}

@MainActor
struct RoutedPicker: View {
    @ObservedObject var model: MergeModel
    let route: PickRoute
    let dismiss: () -> Void

    var body: some View {
        switch route {
        case .system(let purpose): FilePicker(purpose: purpose) { finish($0, purpose: purpose) }
        case .samples(let purpose): SamplePicker(model: model, purpose: purpose) { finish($0, purpose: purpose) }
        }
    }

    private func finish(_ urls: [URL], purpose: PickPurpose) {
        dismiss()
        model.importFiles(urls, purpose: purpose)
    }
}
