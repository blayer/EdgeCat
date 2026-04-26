import SwiftUI

// Mirrors android-app/.../MobileClawNavHost.kt:
//   conversations -> model_select -> agent_chat/{model}/{conversation}
// Phase A scope: model_select shows sideloaded .litertlm files from Documents/Models/,
// chat is text-only. Conversation list lands in Phase B.
enum Route: Hashable {
    case modelSelect
    case chat(modelPath: String)
}

struct AppRouter: View {
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(onStart: { path.append(.modelSelect) })
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .modelSelect:
                        ModelPickerView { url in
                            path.append(.chat(modelPath: url.path))
                        }
                    case let .chat(modelPath):
                        ChatView(modelURL: URL(fileURLWithPath: modelPath))
                    }
                }
        }
    }
}

private struct HomeView: View {
    let onStart: () -> Void
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Mobile-Claw").font(.largeTitle).bold()
            Text("On-device chat with Gemma via LiteRT-LM").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
            Spacer()
            Button(action: onStart) {
                Label("Choose model", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .navigationTitle("Conversations")
        .navigationBarTitleDisplayMode(.inline)
    }
}
