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

    // Model knobs sourced from SamplerSettings.modelDefaults so they stay
    // in sync with bridge defaults. Only the ones the UI surfaces today
    // are bound; the rest of the audit is reachable code-level via
    // `LlmInitConfig` / `SamplerSettings.current()` for callers that want
    // to override them programmatically.
    @AppStorage(SamplerSettings.acceleratorKey) private var accelerator: String = SamplerSettings.modelDefaults.accelerator
    @AppStorage(SamplerSettings.samplerTypeKey) private var samplerType: Int = SamplerSettings.modelDefaults.samplerType
    @AppStorage(SamplerSettings.seedKey) private var seed: Int = SamplerSettings.modelDefaults.seed
    @AppStorage(SamplerSettings.maxOutputTokensKey) private var maxOutputTokens: Int = SamplerSettings.modelDefaults.maxOutputTokens

    init(conversation: Conversation? = nil) {
        // The conversation parameter is kept for API stability — chat-side
        // callers still pass it, even though we no longer surface a per-
        // conversation system-prompt section here. Removed per user
        // direction so Settings tracks Android's ConfigDialog scope.
        self.conversation = conversation
    }

    var body: some View {
        NavigationStack {
            Form {
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
            HStack(spacing: 12) {
                Button("Use default") {
                    systemPrompt = SamplerSettings.defaultSystemPrompt
                }
                Spacer()
                Button("Clear") { systemPrompt = "" }
                    .foregroundStyle(.red)
            }
            // Show the default text below so the user can see what
            // "blank" actually applies at runtime. Mirrors Android's
            // ConfigDialog where the default prompt is visible.
            Text("Default (used when this field is blank):")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppColors.onSurfaceVariant)
                .padding(.top, 8)
            Text(SamplerSettings.defaultSystemPrompt)
                .font(.caption.monospaced())
                .foregroundStyle(AppColors.onSurfaceVariant)
                .padding(8)
                .background(AppColors.surfaceVariant)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } header: {
            Text("System prompt")
        } footer: {
            Text("Prepended to every conversation. Leave blank to use the default; tap “Use default” to start editing from it.")
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
            LabeledContent("App", value: "EdgeCat")
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
