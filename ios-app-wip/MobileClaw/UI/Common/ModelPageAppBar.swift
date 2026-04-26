import SwiftUI

// 1:1 port of android-app/.../ui/common/ModelPageAppBar.kt for Phase A scope.
// Center-aligned title (task icon + label + model chip), back arrow on the
// leading side, reset-session button on the trailing side. Config gear and
// model picker sheet land in Phase B alongside the real ModelManager.

struct ModelPageAppBarContent: View {
    let modelName: String
    let isStreaming: Bool
    let onBack: () -> Void
    let onReset: () -> Void

    var body: some View {
        ZStack {
            // Center: task label + model chip
            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppColors.primary)
                    Text("LLM Chat")
                        .font(.headline)
                        .foregroundStyle(AppColors.onSurface)
                }
                ModelChip(label: modelName)
            }
            // Leading: back
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 17, weight: .semibold))
                }
                .disabled(isStreaming)
                .opacity(isStreaming ? 0.5 : 1)
                Spacer()
                // Trailing: reset session
                Button(action: onReset) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 17, weight: .semibold))
                }
                .disabled(isStreaming)
                .opacity(isStreaming ? 0.5 : 1)
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 56)
        .padding(.horizontal, 4)
        .background(AppColors.surface)
    }
}

private struct ModelChip: View {
    let label: String
    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(AppColors.surfaceVariant)
        )
        .foregroundStyle(AppColors.onSurfaceVariant)
    }
}
