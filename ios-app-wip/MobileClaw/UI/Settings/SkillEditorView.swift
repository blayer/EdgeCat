import SwiftUI

// Add/edit form for a single skill. Built-in skills are mostly read-only
// (only the instructions field is editable, persisted as an override in
// `SkillInstructions`). Custom skills (under Documents/skills/) are fully
// editable, including the JS body. Mirrors android-app's
// AddOrEditSkillBottomSheet, scoped to what the iOS UI surfaces today.

struct SkillEditorView: View {
    enum Mode: Equatable {
        case add
        case edit(slug: String, source: SkillManifest.Source)
    }

    let mode: Mode
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var slug: String = ""
    @State private var description: String = ""
    @State private var instructions: String = ""
    @State private var requireSecret: Bool = false
    @State private var requireSecretDescription: String = ""
    @State private var jsBody: String = ""
    @State private var errorMessage: String?
    @State private var showDeleteConfirm = false

    /// Read-only fields when editing a built-in skill — the SKILL.md ships
    /// in the bundle and we don't rewrite it. Only `instructions` is
    /// editable for built-ins (stored as a UserDefaults override).
    private var isBuiltIn: Bool {
        if case .edit(_, .builtIn) = mode { return true }
        return false
    }

    private var isAdd: Bool { mode == .add }

    private var navTitle: String {
        switch mode {
        case .add: return "New Skill"
        case .edit(let s, _): return s
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                instructionsSection
                if !isBuiltIn { secretSection }
                if !isBuiltIn { jsBodySection }
                if let err = errorMessage {
                    Section {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }
                }
                if case .edit(_, .custom) = mode {
                    deleteSection
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(saveDisabled)
                }
            }
            .onAppear { hydrate() }
            .alert("Delete \(slug)?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive, action: confirmDelete)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes the skill folder under Documents/skills/. This can't be undone.")
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var identitySection: some View {
        Section {
            if isAdd {
                TextField("Slug (e.g., custom-fact)", text: $slug)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                LabeledContent("Slug", value: slug)
            }
            if isBuiltIn {
                LabeledContent("Description", value: description)
            } else {
                TextField("Description (one line, planner reads this)",
                          text: $description, axis: .vertical)
                    .lineLimit(2...4)
            }
        } header: {
            Text("Identity")
        } footer: {
            if isAdd {
                Text("Slug must be lowercase ASCII letters, digits, or dashes (2–50 chars). It's how the planner addresses the skill — pick stably.")
                    .font(.caption)
            } else if isBuiltIn {
                Text("Built-in skills ship with the app. Slug + description are read-only; only the instructions below can be customized.")
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var instructionsSection: some View {
        Section {
            TextEditor(text: $instructions)
                .frame(minHeight: 140)
                .font(.callout)
        } header: {
            Text("Instructions")
        } footer: {
            Text("Prose the planner sees. Tell it which args to pass, what the skill returns, and any constraints.")
                .font(.caption)
        }
    }

    @ViewBuilder
    private var secretSection: some View {
        Section {
            Toggle("Requires secret", isOn: $requireSecret)
            if requireSecret {
                TextField("Secret description (shown to the user when they're asked to paste a token)",
                          text: $requireSecretDescription, axis: .vertical)
                    .lineLimit(2...3)
            }
        } header: {
            Text("Secret")
        } footer: {
            Text("If your JS calls an authenticated API, declare the secret here. The user pastes the token in the manager UI; it's injected as `data.secret` at runtime.")
                .font(.caption)
        }
    }

    @ViewBuilder
    private var jsBodySection: some View {
        Section {
            TextEditor(text: $jsBody)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 220)
        } header: {
            Text("JavaScript")
        } footer: {
            Text("Define `window[\"ai_edge_gallery_get_result\"] = async (data) => { ... }`. `data` is a JSON string the bridge passed in. Return a string (or `JSON.stringify(obj)`).")
                .font(.caption)
        }
    }

    @ViewBuilder
    private var deleteSection: some View {
        Section {
            Button(role: .destructive) { showDeleteConfirm = true } label: {
                HStack {
                    Image(systemName: "trash")
                    Text("Delete this skill")
                }
            }
        }
    }

    // MARK: - Actions

    private var saveDisabled: Bool {
        switch mode {
        case .add:
            return !CustomSkillStore.isValidSlug(slug.lowercased())
                   || description.trimmingCharacters(in: .whitespaces).isEmpty
        case .edit:
            return false
        }
    }

    private func hydrate() {
        switch mode {
        case .add:
            slug = ""; description = ""; instructions = ""
            requireSecret = false; requireSecretDescription = ""
            jsBody = ""
        case .edit(let editSlug, let source):
            slug = editSlug
            // Pull the live manifest from disk so edits open with current
            // values rather than a stale snapshot.
            let manifests: [SkillManifest] = {
                switch source {
                case .builtIn: return SkillBundle.scanResources()
                case .custom:  return SkillBundle.scanCustom()
                }
            }()
            if let m = manifests.first(where: { $0.slug == editSlug }) {
                description = m.description
                requireSecret = m.requireSecret
                requireSecretDescription = m.requireSecretDescription
                instructions = SkillInstructions.effective(slug: m.slug,
                                                           default: m.instructions)
                if source == .custom {
                    jsBody = CustomSkillStore.readJsBody(slug: editSlug)
                }
            }
        }
    }

    private func save() {
        errorMessage = nil
        do {
            switch mode {
            case .add:
                let draft = CustomSkillDraft(
                    slug: slug.lowercased().trimmingCharacters(in: .whitespaces),
                    description: description.trimmingCharacters(in: .whitespaces),
                    instructions: instructions,
                    requireSecret: requireSecret,
                    requireSecretDescription: requireSecretDescription,
                    jsBody: jsBody)
                try CustomSkillStore.create(draft)
            case .edit(_, .custom):
                let draft = CustomSkillDraft(
                    slug: slug,
                    description: description.trimmingCharacters(in: .whitespaces),
                    instructions: instructions,
                    requireSecret: requireSecret,
                    requireSecretDescription: requireSecretDescription)
                try CustomSkillStore.updateMetadata(draft)
                try CustomSkillStore.updateJsBody(slug: slug, jsBody: jsBody)
            case .edit(_, .builtIn):
                // Built-in: only the instructions override is writable.
                SkillInstructions.setOverride(instructions, for: slug)
            }
            onSaved()
            dismiss()
        } catch CustomSkillStoreError.alreadyExists(let s) {
            errorMessage = "A custom skill named \"\(s)\" already exists."
        } catch CustomSkillStoreError.slugInvalid {
            errorMessage = "Slug must be 2–50 chars: lowercase letters, digits, or dashes."
        } catch CustomSkillStoreError.notFound {
            errorMessage = "Skill folder vanished between open and save — try again."
        } catch CustomSkillStoreError.directoryUnavailable {
            errorMessage = "Couldn't open the Documents directory."
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func confirmDelete() {
        do {
            try CustomSkillStore.delete(slug: slug)
            // Clear stale sibling state — instructions overrides + Keychain
            // secret + toggle, all keyed by the slug we just removed.
            SkillInstructions.clear(slug: slug)
            SkillSecrets.setToken(nil, for: slug)
            onSaved()
            dismiss()
        } catch {
            errorMessage = "\(error)"
        }
    }
}
