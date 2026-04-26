import SwiftUI

// 1:1 mirror of android-app/.../ui/modelmanager/ModelList.kt for Phase B —
// shows two sections: sideloaded local files, and the curated catalog from
// model_allowlist.json with download buttons. HF-gated models surface a
// failure state until OAuth lands.

struct ModelManagerView: View {
    let onModelChosen: (URL) -> Void

    @State private var sideloaded: [URL] = []
    @State private var catalog: [CatalogModel] = ModelCatalog.load()
    @State private var downloader = ModelDownloader()
    @State private var inFlightModelId: String?
    @State private var pendingDelete: URL?

    var body: some View {
        List {
            sideloadedSection
            catalogSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .refreshable { reload() }
        .alert("Delete model?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } })) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let url = pendingDelete {
                    try? FileManager.default.removeItem(at: url)
                    pendingDelete = nil
                    reload()
                }
            }
        } message: {
            if let url = pendingDelete {
                Text("\(url.lastPathComponent) will be permanently removed.")
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var sideloadedSection: some View {
        Section("Sideloaded") {
            if sideloaded.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("None yet").font(.callout).foregroundStyle(.secondary)
                    Text("Drop a .litertlm file into Documents/Models/ via Finder or download a catalog model below.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            } else {
                ForEach(sideloaded, id: \.self) { url in
                    Button(action: { onModelChosen(url) }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.deletingPathExtension().lastPathComponent)
                                    .font(.body).foregroundStyle(.primary)
                                Text(formatSize(url)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { pendingDelete = url } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var catalogSection: some View {
        Section("Available to download") {
            ForEach(catalog) { model in
                CatalogRow(
                    model: model,
                    isInstalled: isInstalled(model),
                    isInFlight: inFlightModelId == model.id,
                    downloader: downloader,
                    onDownload: { startDownload(model) },
                    onUse: { url in onModelChosen(url) }
                )
            }
        }
    }

    // MARK: - Logic

    private var modelsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func reload() {
        let contents = (try? FileManager.default.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil)) ?? []
        sideloaded = contents.filter { $0.pathExtension.lowercased() == "litertlm" }
                              .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func isInstalled(_ model: CatalogModel) -> Bool {
        FileManager.default.fileExists(atPath: modelsDirectory.appendingPathComponent(model.modelFile).path)
    }

    private func startDownload(_ model: CatalogModel) {
        inFlightModelId = model.id
        downloader.start(model: model)
    }

    private func formatSize(_ url: URL) -> String {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - CatalogRow

private struct CatalogRow: View {
    let model: CatalogModel
    let isInstalled: Bool
    let isInFlight: Bool
    let downloader: ModelDownloader
    let onDownload: () -> Void
    let onUse: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name).font(.body.weight(.semibold))
                    Text(ByteCountFormatter.string(fromByteCount: model.sizeInBytes, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                actionButton
            }
            Text(stripMarkdown(model.description))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            if isInFlight, case let .downloading(progress) = downloader.status {
                ProgressView(value: progress).tint(AppColors.primary)
                Text("\(Int(progress * 100))% — \(formatBytes(downloader.bytesDownloaded)) / \(formatBytes(downloader.totalBytes))")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else if isInFlight, case let .failed(msg) = downloader.status {
                Text(msg).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var actionButton: some View {
        if isInstalled {
            Button("Use") {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                onUse(docs.appendingPathComponent("Models").appendingPathComponent(model.modelFile))
            }.buttonStyle(.bordered)
        } else if isInFlight, case .downloading = downloader.status {
            Button("Cancel") { downloader.cancel() }.tint(.red)
        } else if isInFlight, case let .succeeded(url) = downloader.status {
            Button("Use") { onUse(url) }.buttonStyle(.borderedProminent)
        } else {
            Button("Download", action: onDownload).buttonStyle(.bordered)
        }
    }

    private func stripMarkdown(_ s: String) -> String {
        s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
    }

    private func formatBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}
