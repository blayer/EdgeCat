import SwiftUI

// 1:1 port of android-app/.../ui/common/ModelPageAppBar.kt. Center-aligned
// title (task icon + label + tappable model chip), back arrow on the leading
// side, settings gear on the trailing side. The gear opens SettingsView as
// a sheet; the chip opens a model-switch sheet — both live in ChatView.

struct ModelPageAppBarContent: View {
    let modelName: String
    let isStreaming: Bool
    let onBack: () -> Void
    let onSettings: () -> Void
    let onSwitchModel: () -> Void

    var body: some View {
        ZStack {
            // Center: task icon + label + tappable model chip below.
            // Mirrors Android's ModelPageAppBar layout: icon + title at the
            // top, chip immediately below — task icon + text both painted
            // in the primary tint.
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppColors.primary)
                    Text("LLM Chat")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AppColors.primary)
                }
                Button(action: onSwitchModel) {
                    ModelChip(label: modelName)
                }
                .buttonStyle(.plain)
                .disabled(isStreaming)
                .opacity(isStreaming ? 0.6 : 1)
            }
            // Leading: back. Trailing: settings (Material's `Tune` ↔ SF
            // `slider.horizontal.3` is the closest visual). Both are
            // disabled during streaming to match Android's behavior of
            // greying every interactive icon while inference is running.
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppColors.onSurface)
                }
                .disabled(isStreaming)
                .opacity(isStreaming ? 0.5 : 1)
                Spacer()
                Button(action: onSettings) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppColors.onSurface)
                }
                .disabled(isStreaming)
                .opacity(isStreaming ? 0.5 : 1)
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 64)
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
