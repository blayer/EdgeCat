import SwiftUI

// 1:1 port of android-app/.../ModelSelectScreen.kt — gradient hero header,
// "Choose a model" + count chip, per-model cards with RECOMMENDED badge,
// size pill, capability badges (Vision / Audio / Thinking), description,
// and a full-width Download button. The Sideloaded section is iOS-only
// (Android doesn't expose drag-drop import the same way) and lives above
// the catalog cards.

private enum CatalogColors {
    static let cardBg     = Color(red: 0x1A/255.0, green: 0x1A/255.0, blue: 0x24/255.0)
    static let cardBorder = Color.white.opacity(0.09)
    static let badgeBg    = Color(red: 0x25/255.0, green: 0x25/255.0, blue: 0x30/255.0)
    static let accentTeal = Color(red: 0x3E/255.0, green: 0xCF/255.0, blue: 0xCF/255.0)
    static let accentBlue = Color(red: 0x4F/255.0, green: 0xC3/255.0, blue: 0xF7/255.0)
}

struct ModelManagerView: View {
    let onModelChosen: (URL) -> Void

    @State private var sideloaded: [URL] = []
    @State private var catalog: [CatalogModel] = ModelCatalog.load()
    @State private var downloader = ModelDownloader()
    @State private var inFlightModelId: String?
    @State private var pendingDelete: URL?
    @State private var importer = LitertlmImporter()
    @State private var showFileImporter = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                heroHeader
                if !sideloaded.isEmpty || true {
                    sideloadedSection
                }
                ForEach(catalog) { model in
                    ModelCard(
                        model: model,
                        isInstalled: isInstalled(model),
                        isInFlight: inFlightModelId == model.id,
                        downloader: downloader,
                        onDownload: { startDownload(model) },
                        onUse: onModelChosen
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .background(AppColors.surface.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.litertlm, .data],
                      allowsMultipleSelection: false) { result in
            handleFileImport(result)
        }
        .onChange(of: importer.status) { _, status in
            if case .succeeded = status {
                reload()
            }
        }
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

    // MARK: - Hero header (gradient title + tagline + section label)

    @ViewBuilder
    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mobile Claw")
                .font(AppFont.nunito(.black, size: 34))
                .foregroundStyle(
                    LinearGradient(
                        colors: [AppColors.primary, CatalogColors.accentBlue, CatalogColors.accentTeal],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            Text("On-device AI agent")
                .font(.titleMediumNunito)
                .foregroundStyle(AppColors.onSurfaceVariant)
            Spacer().frame(height: 22)
            HStack(spacing: 10) {
                Text("Choose a model")
                    .font(.titleSmallNunito)
                    .foregroundStyle(AppColors.onSurface)
                Text("\(catalog.count)")
                    .font(.labelSmallNunito.weight(.bold))
                    .padding(.horizontal, 10).padding(.vertical, 2)
                    .background(Capsule().fill(AppColors.primary.opacity(0.15)))
                    .foregroundStyle(AppColors.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Sideloaded section (iOS-specific affordance kept above the catalog)

    @ViewBuilder
    private var sideloadedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sideloaded")
                    .font(.titleSmallNunito)
                    .foregroundStyle(AppColors.onSurface)
                Spacer()
                importButton
            }
            .padding(.bottom, 2)
            if case .copying = importer.status {
                importProgressCard
            } else if case let .failed(msg) = importer.status {
                importErrorCard(msg)
            } else if sideloaded.isEmpty {
                emptySideloadedCard
            } else {
                ForEach(sideloaded, id: \.self) { url in
                    sideloadedCard(url)
                }
            }
        }
    }

    @ViewBuilder
    private var importButton: some View {
        Button(action: { showFileImporter = true }, label: {
            HStack(spacing: 4) {
                MIcon(name: MIconName.add, size: 16, weight: .semibold)
                Text("Import")
                    .font(.labelMediumNunito.weight(.semibold))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(AppColors.primary.opacity(0.15)))
            .foregroundStyle(AppColors.primary)
        })
        .buttonStyle(.plain)
        .disabled(isCopyingActive)
        .opacity(isCopyingActive ? 0.5 : 1)
    }

    private var isCopyingActive: Bool {
        if case .copying = importer.status { return true }
        return false
    }

    @ViewBuilder
    private var importProgressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Importing…")
                .font(.bodyMediumNunito.weight(.semibold))
                .foregroundStyle(AppColors.onSurface)
            if case let .copying(progress) = importer.status {
                ProgressView(value: progress).tint(AppColors.primary)
                Text("\(Int(progress * 100))% — \(formatBytes(importer.bytesCopied)) / \(formatBytes(importer.totalBytes))")
                    .font(.labelSmallNunito)
                    .foregroundStyle(AppColors.onSurfaceVariant)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(CatalogColors.cardBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(CatalogColors.cardBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func importErrorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Import failed")
                .font(.bodyMediumNunito.weight(.semibold))
                .foregroundStyle(.red)
            Text(message)
                .font(.bodySmallNunito)
                .foregroundStyle(AppColors.onSurfaceVariant)
            Button("Dismiss") { importer.reset() }
                .font(.labelMediumNunito)
                .foregroundStyle(AppColors.primary)
                .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(CatalogColors.cardBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.red.opacity(0.3), lineWidth: 1)
        )
    }

    private func formatBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let src = urls.first else { return }
            importer.start(from: src)
        case .failure(let error):
            // User cancellation surfaces here too — treat both as a soft
            // error so the UI returns to the empty / list state.
            let nsErr = error as NSError
            if nsErr.code == NSUserCancelledError { return }
            // Reflect in the importer so the same UI path renders the error.
            importer.reset()
        }
    }

    @ViewBuilder
    private var emptySideloadedCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("None yet")
                .font(.bodyMediumNunito.weight(.semibold))
                .foregroundStyle(AppColors.onSurface)
            Text("Drop a .litertlm file into Documents/Models/ via Finder or download a catalog model below.")
                .font(.bodySmallNunito)
                .foregroundStyle(AppColors.onSurfaceVariant)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(CatalogColors.cardBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(CatalogColors.cardBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func sideloadedCard(_ url: URL) -> some View {
        Button(action: { onModelChosen(url) }, label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .font(.bodyMediumNunito.weight(.semibold))
                        .foregroundStyle(AppColors.onSurface)
                    Text(formatSize(url))
                        .font(.bodySmallNunito)
                        .foregroundStyle(AppColors.onSurfaceVariant)
                }
                Spacer()
                MIcon(name: MIconName.chevronRight, size: 18, weight: .regular)
                    .foregroundStyle(AppColors.onSurfaceVariant)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(CatalogColors.cardBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(CatalogColors.cardBorder, lineWidth: 1)
            )
        })
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) { pendingDelete = url } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Logic

    private var modelsDirectory: URL {
        do {
            let docs = try FileManager.default.url(for: .documentDirectory,
                                                   in: .userDomainMask,
                                                   appropriateFor: nil,
                                                   create: true)
            let dir = docs.appendingPathComponent("Models", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            fatalError("Failed to access Models directory: \(error)")
        }
    }

    private func reload() {
        let contents = (try? FileManager.default.contentsOfDirectory(at: modelsDirectory,
                                                                     includingPropertiesForKeys: nil)) ?? []
        sideloaded = contents.filter { $0.pathExtension.lowercased() == "litertlm" }
                              .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func isInstalled(_ model: CatalogModel) -> Bool {
        FileManager.default.fileExists(atPath: modelsDirectory
            .appendingPathComponent(model.modelFile).path)
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

// MARK: - Catalog card

private struct ModelCard: View {
    let model: CatalogModel
    let isInstalled: Bool
    let isInFlight: Bool
    let downloader: ModelDownloader
    let onDownload: () -> Void
    let onUse: (URL) -> Void

    private var isRecommended: Bool {
        // Android: `bestForTaskIds.contains(task.id)`. iOS only has the
        // agent-chat task today, so any model that lists `llm_agent_chat`
        // (or a chat-task synonym) gets the badge.
        guard let tags = model.bestForTaskTypes, !tags.isEmpty else { return false }
        return tags.contains(where: { ["llm_agent_chat", "llm_chat"].contains($0) })
    }

    private var sizeText: String {
        let gb = Double(model.sizeInBytes) / (1024 * 1024 * 1024)
        return gb >= 1.0
            ? String(format: "%.1f GB", gb)
            : String(format: "%.0f MB", gb * 1024)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top row: name + size pill
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if isRecommended {
                        Text("RECOMMENDED")
                            .font(.labelSmallNunito.weight(.bold))
                            .tracking(1)
                            .foregroundStyle(CatalogColors.accentTeal)
                    }
                    Text(model.name)
                        .font(.titleMediumNunito.weight(.semibold))
                        .foregroundStyle(AppColors.onSurface)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(sizeText)
                    .font(.labelSmallNunito.weight(.medium))
                    .foregroundStyle(AppColors.onSurfaceVariant)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(CatalogColors.badgeBg)
                    )
            }

            // Capability tags
            if hasCapabilities {
                Spacer().frame(height: 8)
                HStack(spacing: 6) {
                    if model.llmSupportImage == true {
                        CapabilityBadge(icon: MIconName.visibility, label: "Vision",
                                        color: CatalogColors.accentBlue)
                    }
                    if model.llmSupportAudio == true {
                        CapabilityBadge(icon: "hearing", label: "Audio",
                                        color: CatalogColors.accentTeal)
                    }
                    if model.llmSupportThinking == true {
                        CapabilityBadge(icon: "psychology", label: "Thinking",
                                        color: AppColors.primary)
                    }
                }
            }

            // Description (first line of the multiline `info` markdown).
            if !model.description.isEmpty {
                Spacer().frame(height: 10)
                Text(stripMarkdown(model.description))
                    .font(.bodySmallNunito)
                    .foregroundStyle(AppColors.onSurfaceVariant.opacity(0.85))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            // Inline progress / error feedback for in-flight downloads
            if isInFlight, case let .downloading(progress) = downloader.status {
                Spacer().frame(height: 10)
                ProgressView(value: progress).tint(AppColors.primary)
                Text("\(Int(progress * 100))% — \(formatBytes(downloader.bytesDownloaded)) / \(formatBytes(downloader.totalBytes))")
                    .font(.labelSmallNunito)
                    .foregroundStyle(AppColors.onSurfaceVariant)
            } else if isInFlight, case let .failed(msg) = downloader.status {
                Spacer().frame(height: 10)
                Text(msg)
                    .font(.bodySmallNunito)
                    .foregroundStyle(.red)
            }

            Spacer().frame(height: 14)
            actionButton
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(CatalogColors.cardBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(CatalogColors.cardBorder, lineWidth: 1)
        )
    }

    private var hasCapabilities: Bool {
        model.llmSupportImage == true ||
        model.llmSupportAudio == true ||
        model.llmSupportThinking == true
    }

    @ViewBuilder
    private var actionButton: some View {
        if isInstalled {
            Button(action: useInstalledModel) {
                HStack(spacing: 6) {
                    MIcon(name: MIconName.check, size: 18, weight: .semibold)
                    Text("Use this model")
                        .font(.labelLargeNunito.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(
                            colors: [AppColors.primary, CatalogColors.accentTeal],
                            startPoint: .leading, endPoint: .trailing
                        ))
                )
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        } else if isInFlight, case .downloading = downloader.status {
            Button(action: { downloader.cancel() }, label: {
                Text("Cancel")
                    .font(.labelLargeNunito.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.red.opacity(0.6), lineWidth: 1)
                    )
                    .foregroundStyle(.red)
            })
            .buttonStyle(.plain)
        } else if isInFlight, case let .succeeded(url) = downloader.status {
            Button(action: { onUse(url) }, label: {
                HStack(spacing: 6) {
                    MIcon(name: MIconName.check, size: 18, weight: .semibold)
                    Text("Use this model")
                        .font(.labelLargeNunito.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(
                            colors: [AppColors.primary, CatalogColors.accentTeal],
                            startPoint: .leading, endPoint: .trailing
                        ))
                )
                .foregroundStyle(.white)
            })
            .buttonStyle(.plain)
        } else {
            Button(action: onDownload, label: {
                HStack(spacing: 6) {
                    Text("download_for_offline")
                        .font(.custom("MaterialSymbolsRounded-Regular", size: 18))
                    Text("Download")
                        .font(.labelLargeNunito.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(
                            colors: [AppColors.primary, CatalogColors.accentTeal],
                            startPoint: .leading, endPoint: .trailing
                        ))
                )
                .foregroundStyle(.white)
            })
            .buttonStyle(.plain)
        }
    }

    private func useInstalledModel() {
        guard let docs = try? FileManager.default.url(for: .documentDirectory,
                                                       in: .userDomainMask,
                                                       appropriateFor: nil,
                                                       create: true) else { return }
        onUse(docs.appendingPathComponent("Models")
                  .appendingPathComponent(model.modelFile))
    }

    private func stripMarkdown(_ s: String) -> String {
        s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#,
                               with: "$1", options: .regularExpression)
    }

    private func formatBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}

// MARK: - Capability badge

private struct CapabilityBadge: View {
    let icon: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            MIcon(name: icon, size: 13, weight: .regular)
                .foregroundStyle(color)
            Text(label)
                .font(.labelSmallNunito)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.opacity(0.1))
        )
    }
}
