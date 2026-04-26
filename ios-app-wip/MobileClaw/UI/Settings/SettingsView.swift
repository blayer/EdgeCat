import SwiftUI

// Mirrors android-app/.../ui/common/ConfigDialog (subset). For Phase D scope
// we surface the HuggingFace token paste-in (so gated models like Gemma 3n
// become downloadable) plus a placeholder Agentic-mode toggle. Sampler
// params + system-prompt edit + agent-settings tab land in a follow-up.

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var hfToken: String = HuggingFaceAuth.token() ?? ""
    @AppStorage(SamplerSettings.agenticKey) private var agenticMode: Bool = false
    @AppStorage(SamplerSettings.topKKey) private var topK: Int = SamplerSettings.defaults.topK
    @AppStorage(SamplerSettings.topPKey) private var topP: Double = SamplerSettings.defaults.topP
    @AppStorage(SamplerSettings.temperatureKey) private var temperature: Double = SamplerSettings.defaults.temperature
    @AppStorage(SamplerSettings.maxTokensKey) private var maxTokens: Int = SamplerSettings.defaults.maxTokens
    @AppStorage(SamplerSettings.systemPromptKey) private var systemPrompt: String = ""
    @AppStorage(SamplerSettings.agentMaxLoopsKey) private var agentMaxLoops: Int = SamplerSettings.agentDefaults.maxLoops
    @AppStorage(SamplerSettings.agentMaxRepairKey) private var agentMaxRepair: Int = SamplerSettings.agentDefaults.maxRepair
    @AppStorage(SamplerSettings.agentSkillTimeoutKey) private var agentSkillTimeout: Int = SamplerSettings.agentDefaults.skillTimeoutSecs
    @AppStorage(SamplerSettings.agentThinkingModeKey) private var agentThinkingMode: Int = SamplerSettings.agentDefaults.thinkingMode
    @AppStorage(SamplerSettings.agentHistoryWindowKey) private var agentHistoryWindow: Int = SamplerSettings.agentDefaults.historyWindow

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
                    HStack {
                        Text("Top-K"); Spacer()
                        Text("\(topK)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: Binding(get: { Double(topK) }, set: { topK = Int($0) }),
                           in: 1...100, step: 1)
                    HStack {
                        Text("Top-P"); Spacer()
                        Text(String(format: "%.2f", topP)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $topP, in: 0...1)
                    HStack {
                        Text("Temperature"); Spacer()
                        Text(String(format: "%.2f", temperature)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $temperature, in: 0...2)
                    Stepper("Max tokens: \(maxTokens)",
                            value: $maxTokens, in: 128...4096, step: 128)
                    Button("Reset to model defaults") {
                        let d = SamplerSettings.defaults
                        topK = d.topK; topP = d.topP
                        temperature = d.temperature; maxTokens = d.maxTokens
                    }
                    .foregroundStyle(.red)
                } header: {
                    Text("Sampler")
                } footer: {
                    Text("Applied on the next chat session. The Gemma 4 metadata recommends Top-P with topK=1, p=0.95, temperature=1.")
                        .font(.caption)
                }

                Section {
                    TextEditor(text: $systemPrompt)
                        .frame(minHeight: 80)
                        .font(.callout)
                } header: {
                    Text("System prompt")
                } footer: {
                    Text("Prepended to every conversation. Leave blank for default.")
                        .font(.caption)
                }

                Section {
                    Stepper("Max planning loops: \(agentMaxLoops)",
                            value: $agentMaxLoops, in: 1...10)
                    Stepper("Max repair attempts: \(agentMaxRepair)",
                            value: $agentMaxRepair, in: 0...5)
                    Stepper("Skill timeout: \(agentSkillTimeout)s",
                            value: $agentSkillTimeout, in: 10...300, step: 10)
                    Picker("Thinking mode", selection: $agentThinkingMode) {
                        Text("Auto").tag(0)
                        Text("Off").tag(1)
                        Text("Aggressive").tag(2)
                    }
                    .pickerStyle(.segmented)
                    Stepper("Conversation history window: \(agentHistoryWindow)",
                            value: $agentHistoryWindow, in: 1...20)
                } header: {
                    Text("Agent")
                } footer: {
                    Text("Applied when Agentic mode is on. Mirrors the Agent tab on Android's ModelPageAppBar.")
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
