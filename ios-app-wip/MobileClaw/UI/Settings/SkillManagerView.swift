import SwiftUI

// 1:1 port of the user-facing surface in
// android-app/.../customtasks/agentchat/SkillManagerBottomSheet.kt:
// search-filtered list of every shipped skill, per-row enable toggle,
// "Turn On All / Off All" header buttons, and per-row "key" affordance for
// skills whose SKILL.md declares `require-secret: true`. We deliberately
// skip Android's "Add Custom Skill" / multi-select-delete / inline-script
// editor — none of those are wired up here yet (deferred for a follow-up).

struct SkillManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var search: String = ""
    @State private var rows: [Row] = SkillManagerView.loadRows()
    @State private var secretEditorTarget: Row?

    fileprivate struct Row: Identifiable, Equatable {
        let id: String      // skill slug — stable across launches
        let displayName: String
        let description: String
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

                Section {
                    ForEach(filteredRows) { row in
                        SkillRow(row: row,
                                 onToggle: { setEnabled($0, for: row.id) },
                                 onTapSecret: { secretEditorTarget = row })
                    }
                } header: {
                    Text("Skills")
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Skills")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $secretEditorTarget) { row in
                SkillSecretEditor(skillName: row.id,
                                  prompt: row.requireSecretDescription.isEmpty
                                          ? "Paste the API token \(row.displayName) needs."
                                          : row.requireSecretDescription,
                                  onSaved: { reloadOne(row.id) })
            }
        }
    }

    // MARK: - Filtering + state mutation

    private var filteredRows: [Row] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter {
            $0.displayName.lowercased().contains(q)
                || $0.description.lowercased().contains(q)
        }
    }

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

    // MARK: - Row hydration

    /// Load the catalog from the same pipeline the planner uses, then
    /// decorate with per-row state (enabled, secret-set). Done once at sheet
    /// open; the manager doesn't re-scan in response to live filesystem
    /// changes since the bundle is read-only.
    @MainActor fileprivate static func loadRows() -> [Row] {
        let summaries = SkillRegistry.defaultSet().allSkills()
        let manifestsBySlug = Dictionary(uniqueKeysWithValues:
            SkillBundle.scanResources().map { ($0.slug, $0) })
        return summaries.map { summary in
            let manifest = manifestsBySlug[summary.name]
            return Row(
                id: summary.name,
                displayName: summary.name,
                description: summary.description,
                requireSecret: manifest?.requireSecret ?? false,
                requireSecretDescription: manifest?.requireSecretDescription ?? "",
                enabled: SkillToggles.isEnabled(summary.name),
                hasSecret: SkillSecrets.hasToken(for: summary.name)
            )
        }
    }
}

// MARK: - Row

private struct SkillRow: View {
    let row: SkillManagerView.Row
    let onToggle: (Bool) -> Void
    let onTapSecret: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.displayName)
                        .font(.body.weight(.medium))
                    if !row.description.isEmpty {
                        Text(row.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(get: { row.enabled }, set: onToggle))
                    .labelsHidden()
            }
            if row.requireSecret {
                Button(action: onTapSecret) {
                    HStack(spacing: 6) {
                        Image(systemName: row.hasSecret ? "key.fill" : "key")
                            .foregroundStyle(row.hasSecret ? AppColors.primary : .secondary)
                        Text(row.hasSecret ? "Secret set — tap to edit"
                                            : "Secret required — tap to set")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
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
