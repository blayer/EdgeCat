import SwiftUI

// Phase A model picker. Mirrors the structural intent of android-app/.../ui/modelmanager/ModelList.kt
// but trimmed to "browse .litertlm files sideloaded into Documents/Models/" — Android's full
// ModelManagerViewModel (HF download, OAuth, allowlist) lands in Phase B.

struct ModelPickerView: View {
    @State private var models: [URL] = []
    @State private var refreshTick = 0
    let onModelChosen: (URL) -> Void

    var body: some View {
        List {
            Section {
                if models.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No models found").font(.headline)
                        Text("Drop a .litertlm file into the app's Documents/Models/ folder via Finder (USB) or the Files app, then pull to refresh.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } else {
                    ForEach(models, id: \.self) { url in
                        Button(action: { onModelChosen(url) }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.deletingPathExtension().lastPathComponent).font(.body).foregroundStyle(.primary)
                                    Text(formatSize(url)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            } header: {
                Text("Sideloaded models")
            } footer: {
                if let dir = modelsDirectory {
                    Text("Path: \(dir.path)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .refreshable { reload() }
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
    }

    private var modelsDirectory: URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return docs?.appendingPathComponent("Models", isDirectory: true)
    }

    private func reload() {
        guard let dir = modelsDirectory else { models = []; return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        models = contents.filter { $0.pathExtension.lowercased() == "litertlm" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        refreshTick += 1
    }

    private func formatSize(_ url: URL) -> String {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
