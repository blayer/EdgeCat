import SwiftUI

// Mirrors android-app/.../ui/common/ConfigDialog (subset). For Phase D scope
// we surface the HuggingFace token paste-in (so gated models like Gemma 3n
// become downloadable) plus a placeholder Agentic-mode toggle. Sampler
// params + system-prompt edit + agent-settings tab land in a follow-up.

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var hfToken: String = HuggingFaceAuth.token() ?? ""
    @AppStorage("MOBILECLAW_AGENTIC_MODE") private var agenticMode: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Agentic mode", isOn: $agenticMode)
                } header: {
                    Text("Behavior")
                } footer: {
                    Text("Routes user messages through the Planner → Executor → Evaluator loop. Equivalent to Android's agentic-mode toggle on ModelPageAppBar.")
                        .font(.caption)
                }

                Section {
                    SecureField("hf_xxx…", text: $hfToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Button("Save") { HuggingFaceAuth.setToken(hfToken) }
                            .buttonStyle(.borderedProminent)
                        if HuggingFaceAuth.hasToken {
                            Button("Clear", role: .destructive) {
                                HuggingFaceAuth.setToken(nil); hfToken = ""
                            }
                        }
                    }
                } header: {
                    Text("HuggingFace token")
                } footer: {
                    Text("Optional. Required to download gated models like Gemma 3n. Generate one at huggingface.co/settings/tokens. Stored in Keychain.")
                        .font(.caption)
                }

                Section("About") {
                    LabeledContent("App", value: "Mobile-Claw")
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
