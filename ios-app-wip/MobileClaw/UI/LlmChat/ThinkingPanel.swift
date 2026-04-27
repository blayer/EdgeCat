import SwiftUI

// 1:1 port of android-app/.../ui/common/chat/MessageBodyThinking.kt — a
// collapsible panel that renders the LLM's chain-of-thought inline above
// the assistant's final answer.

struct ThinkingPanel: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        if !text.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(AppColors.onSurfaceVariant)
                    .padding(.top, 6)
                    .textSelection(.enabled)
            } label: {
                HStack(spacing: 6) {
                    MIcon(name: MIconName.lightbulb, size: 14, weight: .regular)
                    Text("Thinking")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(AppColors.primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppColors.surfaceVariant.opacity(0.5))
            )
        }
    }
}
