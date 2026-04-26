import SwiftUI

// 1:1 port of android-app/.../ui/common/chat/MessageInputText.kt for Phase A scope.
// Image + audio picker buttons are present (per Android layout) but disabled —
// real implementations land in Phase C.

struct MessageInputText: View {
    @Binding var text: String
    let isStreaming: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onStop: () -> Void
    let showImageButton: Bool
    let showAudioButton: Bool

    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if showImageButton {
                Button(action: {}) {
                    Image(systemName: "photo")
                        .font(.system(size: 22))
                        .foregroundStyle(AppColors.onSurfaceVariant)
                }
                .disabled(true)  // Phase C
            }
            if showAudioButton {
                Button(action: {}) {
                    Image(systemName: "mic")
                        .font(.system(size: 22))
                        .foregroundStyle(AppColors.onSurfaceVariant)
                }
                .disabled(true)  // Phase C
            }

            HStack {
                TextField("Message", text: $text, axis: .vertical)
                    .focused($focused)
                    .lineLimit(1...5)
                    .submitLabel(.send)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(AppColors.surfaceVariant)
            )

            if isStreaming {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(AppColors.primary))
                }
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(canSend ? AppColors.primary : AppColors.outline))
                }
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppColors.surface)
    }
}
