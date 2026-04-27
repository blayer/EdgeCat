import SwiftUI

// 1:1 port of the user-facing surface in
// android-app/.../customtasks/agentchat/SkillManagerBottomSheet.kt:
// search-filtered list of every shipped skill, per-row enable toggle,
// "Turn On All / Off All" header buttons, per-row "key" affordance for
// skills whose SKILL.md declares `require-secret: true`, plus + button
// to add custom skills, tap-row to edit, and swipe-to-delete on custom
// rows. Custom and built-in skills live in separate sections.

struct SkillManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var search: String = ""
    @State private var rows: [Row] = SkillManagerView.loadRows()
    @State private var secretEditorTarget: Row?
    @State private var editorMode: SkillEditorView.Mode?
    @State private var customExpanded: Bool = true
    @State private var builtInExpanded: Bool = true
    @State private var showAddSheet: Bool = false
    @State private var showFolderImporter: Bool = false
    @State private var importErrorMessage: String?

    fileprivate struct Row: Identifiable, Equatable {
        let id: String      // skill slug — stable across launches
        let displayName: String
        let description: String
        let source: SkillManifest.Source
        let requireSecret: Bool
        let requireSecretDescription: String
        var enabled: Bool
        var hasSecret: Bool
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Button("Turn On All") { setAll(true) }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button("Turn Off All") { setAll(false) }
                            .buttonStyle(.bordered)
                            .tint(.red)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                } footer: {
                    Text("Disabled skills are hidden from the planner. Enable a skill again to make it eligible on the next chat turn.")
                        .font(.caption)
                }

                if !customRows.isEmpty {
                    Section {
                        if customExpanded {
                            ForEach(customRows) { row in
                                rowView(row)
                            }
                            .onDelete(perform: deleteCustom)
                        }
                    } header: {
                        sectionHeader(title: "Custom",
                                      count: customRows.count,
                                      expanded: customExpanded) {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                customExpanded.toggle()
                            }
                        }
                    } footer: {
                        if customExpanded {
                            Text("Stored under Documents/skills/ — fully editable. Swipe a row to delete it.")
                                .font(.bodySmallNunito)
                        }
                    }
                }

                Section {
                    if builtInExpanded {
                        ForEach(builtInRows) { row in
                            rowView(row)
                        }
                    }
                } header: {
                    sectionHeader(title: "Built-in",
                                  count: builtInRows.count,
                                  expanded: builtInExpanded) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            builtInExpanded.toggle()
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Manage Skills")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAddSheet = true } label: {
                        MIcon(name: MIconName.add, size: 22, weight: .regular)
                    }
                }
            }
            .confirmationDialog("Add a skill", isPresented: $showAddSheet,
                                titleVisibility: .visible) {
                Button("Add manually") {
                    editorMode = .add
                }
                Button("Import from local folder…") {
                    showFolderImporter = true
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Add a custom skill manually, or import a folder containing SKILL.md and scripts/.")
            }
            .fileImporter(isPresented: $showFolderImporter,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                handleFolderImport(result)
            }
            .alert("Import failed",
                   isPresented: Binding(get: { importErrorMessage != nil },
                                        set: { if !$0 { importErrorMessage = nil } })) {
                Button("OK", role: .cancel) { importErrorMessage = nil }
            } message: {
                Text(importErrorMessage ?? "")
            }
            .sheet(item: $secretEditorTarget) { row in
                SkillSecretEditor(skillName: row.id,
                                  prompt: row.requireSecretDescription.isEmpty
                                          ? "Paste the API token \(row.displayName) needs."
                                          : row.requireSecretDescription,
                                  onSaved: { reloadOne(row.id) })
            }
            .sheet(item: $editorMode) { mode in
                SkillEditorView(mode: mode, onSaved: { reloadAll() })
            }
        }
    }

    private func handleFolderImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let src = urls.first else { return }
            do {
                _ = try SkillFolderImporter.importFolder(at: src)
                reloadAll()
            } catch SkillFolderImportError.notADirectory {
                importErrorMessage = "Pick a folder, not a file."
            } catch SkillFolderImportError.missingManifest {
                importErrorMessage = "The folder doesn't have a SKILL.md at its root."
            } catch SkillFolderImportError.alreadyExists(let slug) {
                importErrorMessage = "A custom skill named \"\(slug)\" already exists. Delete it first."
            } catch SkillFolderImportError.directoryUnavailable {
                importErrorMessage = "Couldn't open the Documents directory."
            } catch SkillFolderImportError.copyFailed(let detail) {
                importErrorMessage = "Copy failed: \(detail)"
            } catch {
                importErrorMessage = "\(error)"
            }
        case .failure(let error):
            let nsErr = error as NSError
            if nsErr.code == NSUserCancelledError { return }
            importErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Row composition

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        SkillRow(row: row,
                 onToggle: { setEnabled($0, for: row.id) },
                 onTapSecret: { secretEditorTarget = row },
                 onTapEdit: { editorMode = .edit(slug: row.id, source: row.source) },
                 onTapView: { editorMode = .edit(slug: row.id, source: row.source) })
    }

    /// Tappable section header with caret + per-section item count.
    /// Mirrors Android's `SkillManagerBottomSheet` collapsible-section
    /// styling: caret on the leading side, label, count chip on trailing.
    @ViewBuilder
    private func sectionHeader(title: String, count: Int, expanded: Bool,
                               onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                MIcon(name: expanded ? MIconName.expandLess : MIconName.expandMore,
                      size: 18, weight: .regular)
                    .foregroundStyle(AppColors.onSurfaceVariant)
                Text(title)
                    .font(.labelLargeNunito.weight(.semibold))
                    .foregroundStyle(AppColors.onSurface)
                Text("\(count)")
                    .font(.labelMediumNunito)
                    .foregroundStyle(AppColors.onSurfaceVariant)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(AppColors.surfaceVariant))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Filtering

    private var filteredRows: [Row] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter {
            $0.displayName.lowercased().contains(q)
                || $0.description.lowercased().contains(q)
        }
    }

    private var customRows:  [Row] { filteredRows.filter { $0.source == .custom } }
    private var builtInRows: [Row] { filteredRows.filter { $0.source == .builtIn } }

    // MARK: - Actions

    private func setEnabled(_ enabled: Bool, for slug: String) {
        SkillToggles.setEnabled(enabled, for: slug)
        if let idx = rows.firstIndex(where: { $0.id == slug }) {
            rows[idx].enabled = enabled
        }
    }

    private func setAll(_ enabled: Bool) {
        SkillToggles.setAllEnabled(enabled, in: rows.map(\.id))
        for i in rows.indices { rows[i].enabled = enabled }
    }

    private func reloadOne(_ slug: String) {
        guard let idx = rows.firstIndex(where: { $0.id == slug }) else { return }
        rows[idx].hasSecret = SkillSecrets.hasToken(for: slug)
    }

    private func reloadAll() { rows = Self.loadRows() }

    private func deleteCustom(at offsets: IndexSet) {
        let targets = offsets.map { customRows[$0].id }
        for slug in targets {
            try? CustomSkillStore.delete(slug: slug)
            SkillInstructions.clear(slug: slug)
            SkillSecrets.setToken(nil, for: slug)
        }
        reloadAll()
    }

    // MARK: - Row hydration

    /// Pull the merged catalog (built-ins + custom from Documents/) and
    /// decorate every row with enabled + secret state. Done at open and
    /// after each save/delete; we don't watch the filesystem for changes
    /// since edits go through this view's own Save buttons.
    @MainActor fileprivate static func loadRows() -> [Row] {
        let summaries = SkillRegistry.defaultSet().allSkills()
        let manifestsBySlug = Dictionary(uniqueKeysWithValues:
            SkillBundle.scanAll().map { ($0.slug, $0) })
        return summaries.map { summary in
            let manifest = manifestsBySlug[summary.name]
            return Row(
                id: summary.name,
                displayName: summary.name,
                description: summary.description,
                // Native (non-JS) skills don't have a manifest in the
                // Documents-or-bundle scan and aren't editable, so they
                // always count as built-in here.
                source: manifest?.source ?? .builtIn,
                requireSecret: manifest?.requireSecret ?? false,
                requireSecretDescription: manifest?.requireSecretDescription ?? "",
                enabled: SkillToggles.isEnabled(summary.name),
                hasSecret: SkillSecrets.hasToken(for: summary.name)
            )
        }
    }
}

// MARK: - Editor mode → Identifiable for sheet(item:)

extension SkillEditorView.Mode: Identifiable {
    public var id: String {
        switch self {
        case .add: return "_add"
        case .edit(let slug, _): return slug
        }
    }
}

// MARK: - Row

private struct SkillRow: View {
    let row: SkillManagerView.Row
    let onToggle: (Bool) -> Void
    let onTapSecret: () -> Void
    let onTapEdit: () -> Void
    let onTapView: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.displayName)
                            .font(.bodyMediumNunito.weight(.semibold))
                            .foregroundStyle(AppColors.onSurface)
                        if row.source == .custom {
                            Text("CUSTOM")
                                .font(.labelSmallNunito.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(AppColors.primary.opacity(0.15))
                                .foregroundStyle(AppColors.primary)
                                .clipShape(Capsule())
                        }
                    }
                    if !row.description.isEmpty {
                        Text(row.description)
                            .font(.bodySmallNunito)
                            .foregroundStyle(AppColors.onSurfaceVariant)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("", isOn: Binding(get: { row.enabled }, set: onToggle))
                    .labelsHidden()
            }

            // Action button row, Android parity: View (always), Secret
            // (when require-secret), and an implicit Delete on swipe.
            // Tapping View opens the editor — built-ins are read-only
            // except instructions; custom skills are fully editable.
            HStack(spacing: 8) {
                Button(action: onTapView) {
                    HStack(spacing: 4) {
                        MIcon(name: row.source == .custom
                                    ? MIconName.tune
                                    : MIconName.visibility,
                              size: 16, weight: .regular)
                        Text(row.source == .custom ? "Edit" : "View")
                            .font(.labelMediumNunito)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(AppColors.surfaceVariant))
                    .foregroundStyle(AppColors.onSurface)
                }
                .buttonStyle(.plain)

                if row.requireSecret {
                    Button(action: onTapSecret) {
                        HStack(spacing: 4) {
                            MIcon(name: MIconName.key, size: 16, weight: .regular)
                                .foregroundStyle(row.hasSecret ? AppColors.primary : AppColors.onSurfaceVariant)
                            Text(row.hasSecret ? "Edit secret" : "Add secret")
                                .font(.labelMediumNunito)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(AppColors.surfaceVariant))
                        .foregroundStyle(AppColors.onSurface)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Secret editor

private struct SkillSecretEditor: View {
    let skillName: String
    let prompt: String
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var token: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Paste secret here", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text(prompt).font(.caption)
                }
                Section {
                    Button("Save") {
                        SkillSecrets.setToken(token.isEmpty ? nil : token, for: skillName)
                        onSaved()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    if SkillSecrets.hasToken(for: skillName) {
                        Button("Remove", role: .destructive) {
                            SkillSecrets.setToken(nil, for: skillName)
                            onSaved()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(skillName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { token = SkillSecrets.token(for: skillName) ?? "" }
        }
    }
}
