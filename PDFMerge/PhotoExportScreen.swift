import Photos
import SwiftUI
import UIKit

extension Source {
    var canExportPhotos: Bool { pageCount > 0 && (issue == nil || issue == .interactivePDF) }
}

enum PhotoExportTarget {
    case source(Source), output(Output)

    var name: String {
        switch self {
        case .source(let source): return source.name
        case .output(let output): return output.name
        }
    }

    func url(in workspace: Workspace) async throws -> URL {
        switch self {
        case .source(let source): return try await workspace.sourceURL(source.id)
        case .output(let output): return try await workspace.outputURL(output.id)
        }
    }
}

struct PhotoExportAction: View {
    let id: String
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if compact {
                    Image(systemName: "photo.on.rectangle")
                        .frame(width: 38, height: 38)
                } else {
                    Label(L.t("photo.export"), systemImage: "photo.on.rectangle")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(mergeAccent)
            .background(mergeAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: compact ? 10 : 14))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L.t("photo.export"))
        .accessibilityIdentifier(id)
    }
}

@MainActor
struct PhotoExportScreen: View {
    let target: PhotoExportTarget
    @ObservedObject var model: MergeModel
    let close: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var pdf = PhotoPDF()
    @State private var pageCount: Int?
    @State private var selected: Set<Int> = []
    @State private var saving = false
    @State private var savedCount: Int?
    @State private var issue: Issue?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(target.name).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        if let pageCount {
                            Text(L.f("pages.count", pageCount)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(mergeAccent.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))

                    if let pageCount {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 144 : 92), spacing: 10)], spacing: 10) {
                            ForEach(0..<pageCount, id: \.self, content: pageButton)
                        }
                        .disabled(saving || savedCount != nil)
                    } else if issue == nil {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            .navigationTitle(L.t("photo.export"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.t(savedCount == nil ? "cancel" : "done"), action: close)
                        .disabled(saving)
                        .accessibilityIdentifier("photo.close")
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .task {
            do {
                let url = try await target.url(in: model.workspace)
                pageCount = try await pdf.load(url)
            } catch { issue = Issue.storage(error) }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let issue {
                Label(issue.message, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if saving {
                HStack {
                    ProgressView()
                    Text(L.t("photo.saving"))
                }
                .frame(minHeight: 52)
            } else if let savedCount {
                HStack {
                    Image(systemName: "checkmark.circle.fill").accessibilityHidden(true)
                    Text(L.f("photo.saved", savedCount)).accessibilityIdentifier("photo.saved")
                }
                .font(.headline)
                .foregroundStyle(mergeAccent)
                .frame(minHeight: 52)
            } else if pageCount != nil {
                MainAction(title: L.t(selected.isEmpty ? "photo.saveAll" : "photo.saveSelected"),
                           id: "photo.save", icon: "square.and.arrow.down", action: save)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private func pageButton(_ index: Int) -> some View {
        let checked = selected.contains(index)
        return Button {
            if checked { selected.remove(index) }
            else { selected.insert(index) }
        } label: {
            VStack(spacing: 6) {
                PhotoPagePreview(pdf: pdf, index: index)
                    .frame(height: 84)
                    .accessibilityHidden(true)
                HStack(spacing: 5) {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(checked ? mergeAccent : Color.secondary)
                        .accessibilityHidden(true)
                    Text((index + 1).formatted())
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(
                checked ? mergeAccent : Color.secondary.opacity(0.18), lineWidth: checked ? 2 : 1
            ))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L.f("photo.page", index + 1))
        .accessibilityAddTraits(checked ? .isSelected : [])
        .accessibilityIdentifier("photo.page.\(index)")
    }

    private func save() {
        guard pageCount != nil, !saving, savedCount == nil else { return }
        guard model.pro else { close(); model.purchaseSheet = true; return }
        guard let screen = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.keyWindow != nil })?.screen else { issue = .photoSaveFailed; return }
        let pages: Set<Int>? = selected.isEmpty ? nil : selected
        let screenPixels = screen.nativeBounds.size
        issue = nil
        saving = true
        Task {
            defer { saving = false }
            do {
                try await PhotoLibraryWriter.authorize()
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: directory) }
                let files = try await pdf.render(selected: pages, screenPixels: screenPixels, to: directory)
                try await PhotoLibraryWriter.save(files)
                savedCount = files.count
            } catch { issue = Issue.storage(error) }
        }
    }
}

private struct PhotoPagePreview: View {
    let pdf: PhotoPDF
    let index: Int
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "doc").foregroundStyle(.secondary) }
        }
        .task {
            let rendered = await pdf.thumbnail(at: index)
            if !Task.isCancelled { image = rendered }
        }
        .onDisappear { image = nil }
    }
}

private enum PhotoLibraryWriter {
    static func authorize() async throws {
        guard !Launch.testing else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized else { throw Issue.photoPermission }
    }

    static func save(_ files: [URL]) async throws {
        guard !Launch.testing else { return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for file in files {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: nil)
                }
            }
        } catch {
            let issue = Issue.storage(error)
            throw issue == .noSpace ? issue : Issue.photoSaveFailed
        }
    }
}
