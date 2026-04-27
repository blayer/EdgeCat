import SwiftUI

// 1:1 port of android-app/.../ui/common/ConfigDialog.kt's tab layout. The
// Android dialog has three tabs: "Model configs", "System prompt", "Agent".
// The iOS settings sheet uses a top SegmentedControl for the same three tabs
// and renders the matching content below. The HuggingFace token + per-conv
// override + About section are iOS-specific extras shown above/below the
// tabbed area as separate sections.

struct SettingsView: View {
    /// Optional per-conversation context. When non-nil, the sheet shows a
    /// "This conversation" section at the top with a `systemPromptOverride`
    /// editor. Conversations list calls this with nil.
    let conversation: Conversation?

    enum Tab: String, CaseIterable, Identifiable {
        case model    = "Model configs"
        case prompt   = "System prompt"
        case agent    = "Agent"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: Tab = .model
    @State private var hfToken: String = HuggingFaceAuth.token() ?? ""
    @State private var convPrompt: String = ""
    @State private var memoryClearedAt: Date?
    @State private var showSkills = false

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
    @AppStorage(SamplerSettings.agentTracesKey) private var agentTraces: Bool = SamplerSettings.agentDefaults.traces
    @AppStorage(SamplerSettings.userPortraitKey) private var userPortrait: String = ""

    // Model knobs added in the bridge audit. Defaults sourced from
    // SamplerSettings.modelDefaults so they stay in sync across the app.
    @AppStorage(SamplerSettings.acceleratorKey) private var accelerator: String = SamplerSettings.modelDefaults.accelerator
    @AppStorage(SamplerSettings.visionAcceleratorKey) private var visionAccelerator: String = SamplerSettings.modelDefaults.visionAccelerator
    @AppStorage(SamplerSettings.audioAcceleratorKey) private var audioAccelerator: String = SamplerSettings.modelDefaults.audioAccelerator
    @AppStorage(SamplerSettings.samplerTypeKey) private var samplerType: Int = SamplerSettings.modelDefaults.samplerType
    @AppStorage(SamplerSettings.seedKey) private var seed: Int = SamplerSettings.modelDefaults.seed
    @AppStorage(SamplerSettings.maxOutputTokensKey) private var maxOutputTokens: Int = SamplerSettings.modelDefaults.maxOutputTokens
    @AppStorage(SamplerSettings.applyPromptTemplateKey) private var applyPromptTemplate: Bool = SamplerSettings.modelDefaults.applyPromptTemplate
    @AppStorage(SamplerSettings.enableConstrainedDecodingKey) private var enableConstrainedDecoding: Bool = SamplerSettings.modelDefaults.enableConstrainedDecoding
    @AppStorage(SamplerSettings.parallelFileLoadingKey) private var parallelFileLoading: Bool = SamplerSettings.modelDefaults.parallelFileLoading
    @AppStorage(SamplerSettings.activationDtypeKey) private var activationDtype: Int = SamplerSettings.modelDefaults.activationDtype
    @AppStorage(SamplerSettings.prefillChunkSizeKey) private var prefillChunkSize: Int = SamplerSettings.modelDefaults.prefillChunkSize
    @AppStorage(SamplerSettings.speculativeDecodingKey) private var speculativeDecoding: Bool = SamplerSettings.modelDefaults.speculativeDecoding
    @AppStorage(SamplerSettings.debugLogLevelKey) private var debugLogLevel: Int = SamplerSettings.modelDefaults.debugLogLevel

    init(conversation: Conversation? = nil) {
        self.conversation = conversation
        _convPrompt = State(initialValue: conversation?.systemPromptOverride ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                // Per-conversation header — shown only when a conversation is
                // bound. Mirrors Android's "this chat" surface above the tabs.
                if let conversation {
                    Section {
                        TextEditor(text: $convPrompt)
                            .frame(minHeight: 60)
                            .font(.callout)
                        Button("Use global default") {
                            convPrompt = ""
                            conversation.systemPromptOverride = nil
                            try? conversation.modelContext?.save()
                        }
                        .foregroundStyle(.red)
                    } header: {
                        Text("System prompt — this conversation")
                    } footer: {
                        Text("Overrides the global system prompt for just this chat. Empty + Save = use the global default.")
                            .font(.caption)
                    }
                    .onChange(of: convPrompt) { _, new in
                        conversation.systemPromptOverride = new.isEmpty ? nil : new
                        try? conversation.modelContext?.save()
                    }
                }

                // Tab picker — same three labels as Android's PrimaryTabRow.
                Section {
                    Picker("Tab", selection: $selectedTab) {
                        ForEach(Tab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                switch selectedTab {
                case .model:    modelTab
                case .prompt:   systemPromptTab
                case .agent:    agentTab
                }

                // Advanced — power-user knobs that map to additional
                // litert_lm_engine_settings_* / session_config_* setters.
                // Always visible (not gated to a tab) since these mostly
                // matter only when something's wrong; matches what an
                // Android developer-options menu would surface.
                advancedSection

                skillsSection

                // iOS-only sections kept outside the tabbed area: Account
                // (HuggingFace token) + About. They aren't part of Android's
                // dialog because Android handles HF login on a separate screen.
                accountSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showSkills) { SkillManagerView() }
        }
    }

    /// Entry-point row → opens the SkillManagerView sheet. Mirrors
    /// Android's "Manage Skills" button on the agent settings panel.
    @ViewBuilder
    private var skillsSection: some View {
        Section {
            Button { showSkills = true } label: {
                HStack {
                    MIcon(name: MIconName.extension_, size: 20, weight: .regular)
                    Text("Manage Skills")
                    Spacer()
                    MIcon(name: MIconName.chevronRight, size: 18, weight: .regular)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        } header: {
            Text("Skills")
        } footer: {
            Text("Enable / disable skills the planner can call, and store per-skill API tokens for ones that need them.")
                .font(.caption)
        }
    }

    // MARK: - Tab content

    @ViewBuilder
    private var modelTab: some View {
        // Accelerator — segmented CPU / GPU. Mirrors Android's
        // ConfigKeys.ACCELERATOR (NPU is Android-only, omitted on iOS).
        Section {
            Picker("Accelerator", selection: $accelerator) {
                Text("CPU").tag("cpu")
                Text("GPU").tag("gpu")
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Accelerator")
        } footer: {
            Text("CPU is universally compatible. GPU uses Metal — fastest on this device for most models. Default matches Android (GPU).")
                .font(.caption)
        }

        // Sampler choice. Greedy disables the TopK/TopP/Temperature controls
        // since the runtime ignores them in argmax mode.
        Section {
            Picker("Sampler", selection: $samplerType) {
                Text("Top-P").tag(0)
                Text("Greedy").tag(1)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Sampler")
        } footer: {
            Text("Top-P is nucleus sampling using Top-K + Top-P + Temperature. Greedy picks the maximum-logit token (deterministic, ignores Top-K/Top-P/Temperature).")
                .font(.caption)
        }

        Section {
            HStack {
                Text("Top-K"); Spacer()
                Text("\(topK)").foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: Binding(get: { Double(topK) }, set: { topK = Int($0) }),
                   in: 1...100, step: 1)
                .disabled(samplerType == 1)
            HStack {
                Text("Top-P"); Spacer()
                Text(String(format: "%.2f", topP)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $topP, in: 0...1)
                .disabled(samplerType == 1)
            HStack {
                Text("Temperature"); Spacer()
                Text(String(format: "%.2f", temperature)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $temperature, in: 0...2)
                .disabled(samplerType == 1)
            Stepper("Max tokens (KV cache): \(maxTokens)",
                    value: $maxTokens, in: 128...32768, step: 128)
            Stepper("Max output tokens: \(maxOutputTokens == 0 ? "unset" : "\(maxOutputTokens)")",
                    value: $maxOutputTokens, in: 0...4096, step: 32)
            Stepper("Seed: \(seed == 0 ? "0 (non-deterministic)" : "\(seed)")",
                    value: $seed, in: 0...100_000_000, step: 1)
            Button("Reset to model defaults") {
                let d = SamplerSettings.defaults
                topK = d.topK; topP = d.topP
                temperature = d.temperature; maxTokens = d.maxTokens
                seed = 0; maxOutputTokens = 0; samplerType = 0
            }
            .foregroundStyle(.red)
        } header: {
            Text("Sampler params")
        } footer: {
            Text("Applied on the next chat session. The Gemma 4 metadata recommends Top-P with topK=1, p=0.95, temperature=1. Seed = 0 means non-deterministic; any other value makes responses reproducible. Max output tokens caps a single turn (0 = uncapped); Max tokens caps the whole KV cache.")
                .font(.caption)
        }
    }

    @ViewBuilder
    private var systemPromptTab: some View {
        Section {
            TextEditor(text: $systemPrompt)
                .frame(minHeight: 120)
                .font(.callout)
            Button("Restore default") { systemPrompt = "" }
                .foregroundStyle(.red)
        } header: {
            Text("System prompt")
        } footer: {
            Text("Prepended to every conversation. Leave blank for default.")
                .font(.caption)
        }
    }

    @ViewBuilder
    private var agentTab: some View {
        // Toggle row — mirrors Android's "Agentic Mode" Switch row.
        Section {
            Toggle("Agentic Mode", isOn: $agenticMode)
                .onChange(of: agenticMode) { _, on in
                    if !on { agentTraces = false }
                }
            Toggle("Agent Traces", isOn: $agentTraces)
                .disabled(!agenticMode)
        } header: {
            Text("Behavior")
        } footer: {
            Text("Routes user messages through the Planner → Executor → Evaluator loop. Traces show detailed execution steps in chat. Equivalent to Android's agentic-mode + traces toggles.")
                .font(.caption)
        }

        // Sliders — identical ranges and steps to Android.
        Section {
            VStack(alignment: .leading) {
                HStack {
                    Text("Max Thinking Loops"); Spacer()
                    Text("\(agentMaxLoops)").foregroundStyle(.secondary).monospacedDigit()
                }
                Text("Plan-execute-evaluate iterations")
                    .font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(agentMaxLoops) },
                                      set: { agentMaxLoops = Int($0) }),
                       in: 1...10, step: 1)
                    .disabled(!agenticMode)
            }

            VStack(alignment: .leading) {
                HStack {
                    Text("Max Repair Attempts"); Spacer()
                    Text("\(agentMaxRepair)").foregroundStyle(.secondary).monospacedDigit()
                }
                Text("Retries per failed skill step")
                    .font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(agentMaxRepair) },
                                      set: { agentMaxRepair = Int($0) }),
                       in: 0...5, step: 1)
                    .disabled(!agenticMode)
            }

            VStack(alignment: .leading) {
                HStack {
                    Text("Skill Timeout"); Spacer()
                    Text("\(agentSkillTimeout)s").foregroundStyle(.secondary).monospacedDigit()
                }
                Text("Max seconds per skill execution")
                    .font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(agentSkillTimeout) },
                                      set: { agentSkillTimeout = Int($0) }),
                       in: 15...180, step: 15)
                    .disabled(!agenticMode)
            }
        } header: {
            Text("Loop")
        }

        // Thinking mode picker — same Auto/Off/Aggressive options as Android.
        Section {
            Picker("Thinking Mode", selection: $agentThinkingMode) {
                Text("Auto").tag(0)
                Text("Off").tag(1)
                Text("Aggressive").tag(2)
            }
            .pickerStyle(.segmented)
            .disabled(!agenticMode)
            Text(thinkingModeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Thinking Mode")
        }

        // Your Portrait — Android calls this `userPortrait`. Injected into
        // every chat and plan.
        Section {
            TextEditor(text: $userPortrait)
                .frame(minHeight: 100)
                .font(.callout)
        } header: {
            Text("Your Portrait")
        } footer: {
            Text("Injected into every chat and plan. Describe yourself, your preferences, and recurring context. e.g., \"I live in SF, vegetarian, prefer concise technical answers.\"")
                .font(.caption)
        }

        // Conversation history window — same 0..6 range as Android.
        Section {
            VStack(alignment: .leading) {
                HStack {
                    Text("Conversation Window"); Spacer()
                    Text("\(agentHistoryWindow)").foregroundStyle(.secondary).monospacedDigit()
                }
                Text("Recent exchanges replayed on reopen (0 = off)")
                    .font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(agentHistoryWindow) },
                                      set: { agentHistoryWindow = Int($0) }),
                       in: 0...6, step: 1)
            }
        } header: {
            Text("Memory")
        }

        // Clear Memory — destructive action with a transient confirmation
        // banner, matching Android's "Memory cleared successfully" feedback.
        Section {
            Button(role: .destructive) {
                Task { await MemoryControl.clearAll() }
                memoryClearedAt = Date()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if let at = memoryClearedAt, Date().timeIntervalSince(at) >= 1.9 {
                        memoryClearedAt = nil
                    }
                }
            } label: {
                Text("Clear Memory")
            }
            if memoryClearedAt != nil {
                Text("Memory cleared successfully")
                    .font(.caption)
                    .foregroundStyle(AppColors.primary)
            }
        }
    }

    // MARK: - Advanced — power-user LiteRT-LM knobs

    @ViewBuilder
    private var advancedSection: some View {
        Section {
            // Vision + audio backends. Empty string ("Default") falls back to
            // the compute accelerator, matching Android's behavior where
            // visionAccelerator inherits from defaultConfig.
            Picker("Vision backend", selection: $visionAccelerator) {
                Text("Match compute").tag("")
                Text("CPU").tag("cpu")
                Text("GPU").tag("gpu")
            }
            Picker("Audio backend", selection: $audioAccelerator) {
                Text("Match compute").tag("")
                Text("CPU").tag("cpu")
                Text("GPU").tag("gpu")
            }
            Toggle("Apply prompt template", isOn: $applyPromptTemplate)
            Toggle("Constrained decoding", isOn: $enableConstrainedDecoding)
            Toggle("Speculative decoding", isOn: $speculativeDecoding)
            Toggle("Parallel file loading", isOn: $parallelFileLoading)
            Picker("Activation precision", selection: $activationDtype) {
                Text("Default").tag(-1)
                Text("F32").tag(0)
                Text("F16").tag(1)
                Text("I16").tag(2)
                Text("I8").tag(3)
            }
            Stepper("Prefill chunk size: \(prefillChunkSize == 0 ? "unset" : "\(prefillChunkSize)")",
                    value: $prefillChunkSize, in: 0...4096, step: 64)
            Picker("Debug log level", selection: $debugLogLevel) {
                Text("Silent").tag(1000)
                Text("Error").tag(4)
                Text("Warning").tag(3)
                Text("Info").tag(2)
                Text("Debug").tag(1)
                Text("Verbose").tag(0)
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text("Maps directly to litert_lm_engine_settings_* / session_config_* setters. Defaults are safe; touch only when debugging or chasing speed/quality. Constrained decoding requires a grammar — leave off for normal chat.")
                .font(.caption)
        }
    }

    // MARK: - Always-visible iOS-only sections

    @ViewBuilder
    private var accountSection: some View {
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
            if !HuggingFaceOAuthSession.clientId.isEmpty {
                Button("Sign in with HuggingFace") {
                    Task {
                        try? await HuggingFaceOAuthSession.signIn()
                        hfToken = HuggingFaceAuth.token() ?? ""
                    }
                }
            }
        } header: {
            Text("HuggingFace token")
        } footer: {
            Text("Optional. Required to download gated models like Gemma 3n. Generate one at huggingface.co/settings/tokens. Stored in Keychain.")
                .font(.caption)
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        Section("About") {
            LabeledContent("App", value: "Mobile-Claw")
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
        }
    }

    private var thinkingModeDescription: String {
        switch agentThinkingMode {
        case 1: return "Off — fastest, no chain-of-thought"
        case 2: return "Aggressive — thinking on every reasoning step"
        default: return "Auto — thinking on hard plans and repeat replans"
        }
    }
}

// MARK: - Memory clear shim

/// Tiny indirection so SettingsView can call `MemoryRepository.clearAll()`
/// without holding a SwiftData reference. The app injects a real repo on
/// first use; until then `clearAll` is a no-op.
public enum MemoryControl {
    nonisolated(unsafe) public static var repository: MemoryRepository?

    public static func clearAll() async {
        if let repo = repository {
            await repo.clearAll()
        }
    }
}
