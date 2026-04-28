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
                    MIcon(name: MIconName.rocketLaunch, size: 20, weight: .semibold)
                        .foregroundStyle(AppColors.primary)
                    Text("Mobile Agent")
                        .font(.titleMediumNunito.weight(.semibold))
                        .foregroundStyle(AppColors.primary)
                }
                Button(action: onSwitchModel) {
                    ModelChip(label: modelName)
                }
                .buttonStyle(.plain)
                .disabled(isStreaming)
                .opacity(isStreaming ? 0.6 : 1)
            }
            // Leading: back. Trailing: settings (`tune` is the same Material
            // glyph Android's `Icons.Rounded.Tune` resolves to). Both are
            // disabled during streaming to match Android's behavior of
            // greying every interactive icon while inference is running.
            HStack {
                Button(action: onBack) {
                    MIcon(name: MIconName.arrowBack, size: 22, weight: .regular)
                        .foregroundStyle(AppColors.onSurface)
                }
                .disabled(isStreaming)
                .opacity(isStreaming ? 0.5 : 1)
                Spacer()
                Button(action: onSettings) {
                    MIcon(name: MIconName.tune, size: 22, weight: .regular)
                        .foregroundStyle(AppColors.onSurface)
                }
                .disabled(isStreaming)
                .opacity(isStreaming ? 0.5 : 1)
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 64)
        .padding(.horizontal, 4)
        .background(AppColors.surface)
    }
}

private struct ModelChip: View {
    let label: String
    var body: some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.bodySmallNunito)
                .lineLimit(1)
                .truncationMode(.middle)
            MIcon(name: MIconName.arrowDropDown, size: 16, weight: .regular)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(AppColors.surfaceVariant)
        )
        .foregroundStyle(AppColors.onSurfaceVariant)
    }
}
