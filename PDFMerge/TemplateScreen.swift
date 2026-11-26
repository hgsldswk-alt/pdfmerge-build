import SwiftUI
import UIKit

@MainActor
struct TemplateScreen: View {
    @ObservedObject var model: MergeModel
    let initialOrder: PublicTemplate?
    let dismiss: () -> Void
    @State private var code = ""
    @State private var pick: PickRoute?
    @State private var editing: SavedTemplate?
    @State private var batch = false
    @State private var warning: SlotWarning?
    @State private var replacingDraft = false

    var body: some View {
        NavigationStack {
            List {
                Section(L.t("template.import")) {
                    TextEditor(text: $code).frame(minHeight: 66).accessibilityLabel(L.t("template.code"))
                        .accessibilityIdentifier("template.code").autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button(L.t("template.paste")) {
                        if Launch.testing, let value = ProcessInfo.processInfo.environment["PDFMERGE_TEST_PASTE"] { code = value }
                        else { code = UIPasteboard.general.string ?? "" }
                        loadCode()
                    }.accessibilityIdentifier("template.paste")
                    Button(L.t("template.loadCode"), action: loadCode).accessibilityIdentifier("template.loadCode").disabled(code.isEmpty)
                    Button(L.t("template.openFile")) { pick = .pdf(.template) }.accessibilityIdentifier("template.openFile")
                }
                if let template = model.library.activeTemplate { slots(template) }
                Section(L.t("template.saved")) {
                    ForEach(Array(model.library.templates.enumerated()), id: \.element.id) { index, template in
                        Button { model.use(template) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(template.title).font(.headline)
                                Text(template.order.slots.indices.map { template.order.title(at: $0) }.joined(separator: " → "))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }.frame(minHeight: 44)
                        }.accessibilityIdentifier("template.use.\(index)")
                            .swipeActions {
                                Button(L.t("remove"), role: .destructive) { model.deleteTemplate(template.id) }.accessibilityIdentifier("template.delete.\(index)")
                                Button(L.t("edit.title")) { editing = template }.accessibilityIdentifier("template.edit.\(index)").tint(mergeBlue)
                            }
                    }
                    Button(L.t("template.new")) {
                        if model.library.templates.isEmpty || model.pro {
                            editing = SavedTemplate(title: "", order: model.suggestedOrder() ?? .sample)
                        } else { model.purchaseSheet = true }
                    }.accessibilityIdentifier("template.new")
                }
                ShareFeedback(model: model)
            }.disabled(model.busy)
                .navigationTitle(L.t("home.templates"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L.t("done"), action: dismiss).accessibilityIdentifier("template.done").disabled(model.busy) } }
        }
        .safeAreaInset(edge: .top, spacing: 0) { if model.busy { WorkBanner(model: model) } }
        .onAppear {
            if let initialOrder, editing == nil {
                if model.library.templates.isEmpty || model.pro { editing = SavedTemplate(title: "", order: initialOrder) }
                else { model.purchaseSheet = true }
            } else if Launch.testing && Launch.arguments.contains("-sample-template"), model.library.activeTemplate == nil,
                      let template = model.library.templates.first { model.use(template) }
        }
        .sheet(item: $pick) { route in RoutedPicker(model: model, route: route) { pick = nil } }
        .sheet(item: $editing) { template in
            TemplateEditor(model: model, template: template) { next in model.saveTemplate(next); editing = nil }
        }
        .sheet(isPresented: $batch) { BatchScreen(model: model) }
        .mergePresentations(model, active: editing == nil && !batch && pick == nil)
        .alert(L.t("interactive.title"), isPresented: Binding(get: { warning != nil }, set: { if !$0 { warning = nil } }), presenting: warning) { item in
            Button(L.t("interactive.allow")) { model.acceptSlot(item.slot) }
            Button(L.t("cancel"), role: .cancel) {}
        } message: { _ in Text(L.t("issue.interactivePDF")) }
        .alert(L.t("template.replaceDraft"), isPresented: $replacingDraft) {
            Button(L.t("template.apply")) { apply() }
            Button(L.t("cancel"), role: .cancel) {}
        } message: { Text(L.t("template.replaceDetail")) }
        .alert(L.t("error.title"), isPresented: Binding(get: { model.issue != nil && !batch }, set: { if !$0 { model.issue = nil } })) {
            Button(L.t("ok")) { model.issue = nil }
        } message: { Text(model.issue?.message ?? "") }
    }

    private func loadCode() {
        do { try model.activate(PublicTemplate.from(code: code)); code = "" }
        catch { model.issue = .badTemplate }
    }

    private func apply() { model.result = nil; model.applyTemplate(); dismiss() }

    private func slots(_ template: SavedTemplate) -> some View {
        Section {
            ForEach(template.order.slots.indices, id: \.self) { index in
                SlotRow(title: template.order.title(at: index), source: model.library.slots[index], id: "template.slot.\(index)",
                        pick: { pick = .pdf(.slot(index)) }, remove: { model.clearSlot(index) }, allow: { warning = SlotWarning(slot: index) })
            }
            if template.includeDate || template.includeSequence || !template.prefix.isEmpty {
                Text(template.filename(date: model.now, sequence: 1, useRules: true) + ".pdf").font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("template.namingPreview")
            }
            Button(L.t("template.apply")) {
                if model.draft.sources.isEmpty { apply() } else { replacingDraft = true }
            }.accessibilityIdentifier("template.apply").disabled(BatchGroup(files: model.library.slots).draft(for: template.order) == nil)
            Button(L.t("template.edit")) { editing = template }.accessibilityIdentifier("template.editActive")
            Button(L.t("template.batch")) { batch = model.beginBatch(template) }.accessibilityIdentifier("template.batch")
            Button(L.t("template.copyCode")) {
                if let code = try? template.order.code() { model.copy(code) }
            }.accessibilityIdentifier("template.copy")
            Button(L.t("template.shareFile")) { model.shareTemplate(template.order) }.accessibilityIdentifier("template.shareFile")
        } header: { Text(template.title).accessibilityIdentifier("template.active") }
    }
}

struct SlotWarning { let slot: Int; var group: UUID? }

struct SlotRow: View {
    let title: String
    let source: Source?
    let id: String
    let pick: () -> Void
    let remove: () -> Void
    let allow: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: pick) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(title).font(.headline)
                        Text(source?.name ?? L.t("template.chooseSlot")).font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: source == nil ? "plus.circle" : "arrow.trianglehead.clockwise").accessibilityHidden(true)
                }.frame(minHeight: 44)
            }.accessibilityIdentifier(id)
            if let issue = source?.issue {
                Text(issue.message).font(.footnote).foregroundStyle(.secondary)
                HStack {
                    if issue == .interactivePDF { Button(L.t("interactive.review"), action: allow).accessibilityIdentifier(id + ".allow") }
                    Button(L.t("remove"), role: .destructive, action: remove).accessibilityIdentifier(id + ".remove")
                }.buttonStyle(.bordered).controlSize(.large)
            }
        }
    }
}

@MainActor
struct TemplateEditor: View {
    @ObservedObject var model: MergeModel
    @Environment(\.dismiss) private var dismiss
    @State var template: SavedTemplate
    let save: (SavedTemplate) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField(L.t("template.name"), text: $template.title).accessibilityIdentifier("template.name")
                Section(L.t("template.slots")) {
                    ForEach(template.order.slots.indices, id: \.self) { index in
                        Picker(L.f("template.slotNumber", index + 1), selection: binding(index)) {
                            ForEach([SlotKind.material, .application, .receipt, .attachment], id: \.self) { item in
                                Text(L.t("slot.\(item.rawValue)")).tag(item)
                            }
                        }.accessibilityIdentifier("template.editSlot.\(index)")
                    }.onMove { offsets, target in
                        var slots = template.order.slots; slots.move(fromOffsets: offsets, toOffset: target); template.order = PublicTemplate(slots)
                    }.onDelete { offsets in
                        var slots = template.order.slots; slots.remove(atOffsets: offsets)
                        if !slots.isEmpty { template.order = PublicTemplate(slots) }
                    }
                    Button(L.t("template.addSlot")) { template.order = PublicTemplate(template.order.slots + [.material]) }
                        .accessibilityIdentifier("template.addSlot").disabled(template.order.slots.count >= PublicTemplate.limit)
                }
                Section(L.t("template.rules")) {
                    if model.pro {
                        TextField(L.t("template.prefix"), text: $template.prefix).accessibilityIdentifier("template.prefix")
                        Toggle(L.t("template.date"), isOn: $template.includeDate).accessibilityIdentifier("template.date")
                        Toggle(L.t("template.sequence"), isOn: $template.includeSequence).accessibilityIdentifier("template.sequence")
                    } else {
                        Button(L.t("purchase.title")) { model.purchaseSheet = true }.accessibilityIdentifier("template.unlockRules")
                    }
                }
            }.navigationTitle(L.t("template.edit"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L.t("cancel")) { dismiss() }.accessibilityIdentifier("template.edit.cancel") }
                    ToolbarItem(placement: .primaryAction) { EditButton().accessibilityIdentifier("template.edit.reorder") }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L.t("save")) { save(template) }.accessibilityIdentifier("template.save")
                            .disabled(template.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }.mergePresentations(model)
    }

    private func binding(_ index: Int) -> Binding<SlotKind> {
        Binding(get: { template.order.slots.indices.contains(index) ? template.order.slots[index] : .material }, set: { value in
            var slots = template.order.slots
            if slots.indices.contains(index) { slots[index] = value; template.order = PublicTemplate(slots) }
        })
    }
}

@MainActor
struct BatchScreen: View {
    @ObservedObject var model: MergeModel
    @Environment(\.dismiss) private var dismiss
    @State private var pick: PickRoute?
    @State private var output: Output?
    @State private var warning: SlotWarning?

    var body: some View {
        NavigationStack {
            List {
                if let batch = model.library.batch {
                    ForEach(Array(batch.groups.enumerated()), id: \.element.id) { index, group in
                        Section(L.f("batch.group", index + 1)) {
                            if let id = group.result, let match = model.library.history.first(where: { $0.id == id }) {
                                Button(match.name) { output = match }.accessibilityIdentifier("batch.output.\(index)")
                            } else {
                                ForEach(batch.template.order.slots.indices, id: \.self) { slot in
                                    SlotRow(title: batch.template.order.title(at: slot), source: group.files[slot], id: "batch.slot.\(index).\(slot)",
                                            pick: { pick = .pdf(.batch(group.id, slot)) }, remove: { model.removeBatchFile(group.id, slot: slot, allow: false) },
                                            allow: { warning = SlotWarning(slot: slot, group: group.id) })
                                }
                                if let issue = group.issue {
                                    Text(issue == .invalidPDF && group.draft(for: batch.template.order) == nil ? L.t("batch.incomplete") : issue.message).foregroundStyle(.secondary)
                                }
                                if group.issue != nil {
                                    Button(L.t("batch.retry")) { model.generateBatch(only: group.id) }
                                        .accessibilityIdentifier("batch.retry.\(index)").disabled(group.draft(for: batch.template.order) == nil)
                                }
                            }
                        }
                    }
                    Button(L.t("batch.add"), action: model.addGroup).accessibilityIdentifier("batch.add")
                    MainAction(title: L.t("batch.generate"), id: "batch.generate") { model.generateBatch() }
                        .disabled(!batch.groups.contains { $0.result == nil })
                }
            }.disabled(model.busy)
                .navigationTitle(L.t("template.batch"))
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L.t("done")) { dismiss() }.accessibilityIdentifier("batch.done").disabled(model.busy) } }
        }
        .safeAreaInset(edge: .top, spacing: 0) { if model.busy { WorkBanner(model: model) } }
        .sheet(item: $pick) { route in RoutedPicker(model: model, route: route) { pick = nil } }
        .sheet(item: $output) { match in
            VStack(alignment: .leading, spacing: 18) {
                Text(match.name).font(.headline)
                MainAction(title: L.t("result.share"), id: "batch.share") { model.sharePDF(match) }
                ShareFeedback(model: model)
                Button(L.t("done")) { model.shareRequested = false; output = nil }.accessibilityIdentifier("batch.output.done")
            }.padding(20).mergePresentations(model)
        }
        .mergePresentations(model, active: output == nil && pick == nil)
        .alert(L.t("interactive.title"), isPresented: Binding(get: { warning != nil }, set: { if !$0 { warning = nil } }), presenting: warning) { item in
            Button(L.t("interactive.allow")) { if let group = item.group { model.removeBatchFile(group, slot: item.slot, allow: true) } }
            Button(L.t("cancel"), role: .cancel) {}
        } message: { _ in Text(L.t("issue.interactivePDF")) }
        .alert(L.t("error.title"), isPresented: Binding(get: { model.issue != nil }, set: { if !$0 { model.issue = nil } })) {
            Button(L.t("ok")) { model.issue = nil }
        } message: { Text(model.issue?.message ?? "") }
    }
}
