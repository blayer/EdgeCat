import SwiftUI
import PhotosUI
import AVFoundation
import UIKit

// 1:1 port of android-app/.../ui/common/chat/MessageInputText.kt — input row
// with image (Library + Camera menu), audio (push-to-record), and send/stop
// button. Mirrors the Android layout: thumbnails on top, action buttons left,
// text field center, send right.

struct MessageInputText: View {
    @Binding var text: String
    @Binding var attachedImages: [Data]
    @Binding var attachedAudio: [Data]
    let isStreaming: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onStop: () -> Void
    let showImageButton: Bool
    let showAudioButton: Bool

    @FocusState private var focused: Bool
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @StateObject private var recorder = AudioRecorderModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachedImages.isEmpty || !attachedAudio.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(attachedImages.enumerated()), id: \.offset) { idx, data in
                            ImageThumb(data: data, onRemove: { attachedImages.remove(at: idx) })
                        }
                        ForEach(Array(attachedAudio.enumerated()), id: \.offset) { idx, data in
                            AudioThumb(bytes: data.count, onRemove: { attachedAudio.remove(at: idx) })
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                if showImageButton {
                    Menu {
                        PhotosPicker(selection: $pickerItems,
                                     maxSelectionCount: 1,
                                     matching: .images,
                                     photoLibrary: .shared()) {
                            Label("Photo Library", systemImage: "photo.on.rectangle")
                        }
                        Button {
                            showCamera = true
                        } label: {
                            Label("Camera", systemImage: "camera")
                        }
                    } label: {
                        MIcon(name: MIconName.image, size: 24, weight: .regular)
                            .foregroundStyle(AppColors.onSurfaceVariant)
                    }
                    .onChange(of: pickerItems) { _, items in loadPicked(items) }
                }
                if showAudioButton {
                    Button {
                        if recorder.isRecording {
                            if let data = recorder.stop() { attachedAudio.append(data) }
                        } else {
                            recorder.start()
                        }
                    } label: {
                        MIcon(name: MIconName.mic, size: 24, weight: .regular)
                            .foregroundStyle(recorder.isRecording ? .red : AppColors.onSurfaceVariant)
                    }
                }

                HStack {
                    if recorder.isRecording {
                        Text(formatRecordingTime(recorder.elapsed))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.red)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TextField("Type prompt…", text: $text, axis: .vertical)
                            .focused($focused)
                            .lineLimit(1...5)
                            .submitLabel(.send)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(AppColors.surfaceVariant)
                )

                if isStreaming {
                    Button(action: onStop) {
                        MIcon(name: MIconName.stop, size: 22, weight: .bold)
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(AppColors.primary))
                    }
                } else {
                    Button(action: onSend) {
                        MIcon(name: MIconName.send, size: 20, weight: .bold)
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
        .sheet(isPresented: $showCamera) {
            CameraPicker { data in
                if let data { attachedImages.append(data) }
                showCamera = false
            }
            .ignoresSafeArea()
        }
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

    private func formatRecordingTime(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return String(format: "● Recording  %d:%02d", s / 60, s % 60)
    }
}

// MARK: - Audio recorder

@MainActor
private final class AudioRecorderModel: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var url: URL?
    private var startedAt: Date?
    private var ticker: Timer?

    func start() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? session.setActive(true)
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mc-rec-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        guard let recorder = try? AVAudioRecorder(url: outURL, settings: settings) else { return }
        recorder.delegate = self
        recorder.record()
        self.recorder = recorder
        self.url = outURL
        self.startedAt = Date()
        self.elapsed = 0
        self.isRecording = true
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(s)
            }
        }
    }

    @discardableResult
    func stop() -> Data? {
        recorder?.stop()
        ticker?.invalidate(); ticker = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        guard let url else { return nil }
        let data = try? Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        self.url = nil
        return data
    }
}

// MARK: - Camera picker

private struct CameraPicker: UIViewControllerRepresentable {
    let onCaptured: (Data?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCaptured: onCaptured) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onCaptured: (Data?) -> Void
        init(onCaptured: @escaping (Data?) -> Void) { self.onCaptured = onCaptured }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            let img = info[.originalImage] as? UIImage
            onCaptured(img?.pngData())
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCaptured(nil)
        }
    }
}

// MARK: - Thumbnails

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
                MIcon(name: MIconName.cancel, size: 20, weight: .regular)
                    .foregroundStyle(.white)
                    .background(Circle().fill(.black.opacity(0.6)))
            }
            .offset(x: 6, y: -6)
        }
    }
}

private struct AudioThumb: View {
    let bytes: Int
    let onRemove: () -> Void
    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 6) {
                MIcon(name: MIconName.graphicEq, size: 22, weight: .regular)
                Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                    .font(.caption)
            }
            .frame(width: 96, height: 64)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppColors.surfaceVariant)
            )
            .foregroundStyle(AppColors.onSurfaceVariant)
            Button(action: onRemove) {
                MIcon(name: MIconName.cancel, size: 20, weight: .regular)
                    .foregroundStyle(.white)
                    .background(Circle().fill(.black.opacity(0.6)))
            }
            .offset(x: 6, y: -6)
        }
    }
}
