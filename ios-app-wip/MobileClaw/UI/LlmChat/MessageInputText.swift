import SwiftUI
import PhotosUI

// 1:1 port of android-app/.../ui/common/chat/MessageInputText.kt — input row
// with optional image + audio pickers and send/stop button. Phase C wires the
// image button to PhotosPicker; audio recording stays a stub for now.

struct MessageInputText: View {
    @Binding var text: String
    @Binding var attachedImages: [Data]
    let isStreaming: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onStop: () -> Void
    let showImageButton: Bool
    let showAudioButton: Bool

    @FocusState private var focused: Bool
    @State private var pickerItems: [PhotosPickerItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(attachedImages.enumerated()), id: \.offset) { idx, data in
                            ImageThumb(data: data, onRemove: {
                                attachedImages.remove(at: idx)
                            })
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                if showImageButton {
                    PhotosPicker(selection: $pickerItems,
                                 maxSelectionCount: 1,
                                 matching: .images,
                                 photoLibrary: .shared()) {
                        Image(systemName: "photo")
                            .font(.system(size: 22))
                            .foregroundStyle(AppColors.onSurfaceVariant)
                    }
                    .onChange(of: pickerItems) { _, items in loadPicked(items) }
                }
                if showAudioButton {
                    Button(action: {}) {
                        Image(systemName: "mic")
                            .font(.system(size: 22))
                            .foregroundStyle(AppColors.onSurfaceVariant)
                    }
                    .disabled(true)  // Phase C audio recording
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
        }
        .background(AppColors.surface)
    }

    private func loadPicked(_ items: [PhotosPickerItem]) {
        Task {
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    attachedImages.append(data)
                }
            }
            pickerItems = []
        }
    }
}

private struct ImageThumb: View {
    let data: Data
    let onRemove: () -> Void
    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 10).fill(AppColors.surfaceVariant).frame(width: 64, height: 64)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white, .black.opacity(0.7))
            }
            .offset(x: 6, y: -6)
        }
    }
}
