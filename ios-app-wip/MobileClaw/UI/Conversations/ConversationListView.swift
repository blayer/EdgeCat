import SwiftUI
import SwiftData

// 1:1 port of android-app/.../ui/conversations/ConversationListScreen.kt for
// Phase B scope. Empty state + list of pinned/recent conversations + Extended
// FAB ("New"). Swipe-to-pin/delete uses SwiftUI's swipeActions (functionally
// equivalent to Android's RevealableConversationRow).

struct ConversationListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversationsRaw: [Conversation]
    @State private var showSettings = false

    let onConversationOpened: (Conversation) -> Void
    let onOpenModelSelect: () -> Void

    init(onConversationOpened: @escaping (Conversation) -> Void, onOpenModelSelect: @escaping () -> Void) {
        self.onConversationOpened = onConversationOpened
        self.onOpenModelSelect = onOpenModelSelect
    }

    /// Pinned conversations first, then recent. SwiftData's @Query doesn't
    /// support multi-key sort with a Bool key, so we sort manually after fetch.
    private var conversations: [Conversation] {
        conversationsRaw.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ConversationListHeader(onSettings: { showSettings = true })
            Divider()
            if conversations.isEmpty {
                EmptyState()
            } else {
                List {
                    ForEach(conversations) { conv in
                        Button(action: { onConversationOpened(conv) }, label: {
                            ConversationRow(conv: conv)
                        })
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { delete(conv) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { togglePin(conv) } label: {
                                Label(conv.pinned ? "Unpin" : "Pin", systemImage: "pin.fill")
                            }.tint(.green)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(AppColors.surface.ignoresSafeArea())
        .overlay(alignment: .bottomTrailing) {
            NewConversationFAB(onTap: createConversation)
                .padding(.trailing, 16)
                .padding(.bottom, 16)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private func createConversation() {
        let store = ConversationStore(context: context)
        if let conv = try? store.createConversation() {
            onConversationOpened(conv)
        } else {
            // No model picked yet (or store failure) → fall through to model select.
            onOpenModelSelect()
        }
    }

    private func delete(_ conv: Conversation) {
        try? ConversationStore(context: context).deleteConversation(conv)
    }

    private func togglePin(_ conv: Conversation) {
        try? ConversationStore(context: context).setPinned(conv, !conv.pinned)
    }
}

// MARK: - Pieces

private struct ConversationListHeader: View {
    let onSettings: () -> Void
    var body: some View {
        ZStack {
            Text("Conversations")
                .font(.headline)
                .foregroundStyle(AppColors.onSurface)
            HStack {
                Spacer()
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppColors.onSurface)
                }
                .padding(.trailing, 16)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(AppColors.surface)
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(AppColors.onSurfaceVariant)
            Text("No conversations yet")
                .font(.body)
                .foregroundStyle(AppColors.onSurfaceVariant)
            Text("Tap \"New\" to start chatting")
                .font(.footnote)
                .foregroundStyle(AppColors.onSurfaceVariant)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ConversationRow: View {
    let conv: Conversation
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if conv.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(AppColors.primary)
                }
                Text(conv.title.isEmpty ? "New conversation" : conv.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(AppColors.onSurface)
                Spacer()
            }
            if !conv.lastMessagePreview.isEmpty {
                Text(conv.lastMessagePreview)
                    .font(.caption)
                    .foregroundStyle(AppColors.onSurfaceVariant)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text(conv.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(AppColors.onSurfaceVariant)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface)
    }
}

private struct NewConversationFAB: View {
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                Text("New")
            }
            .font(.body.weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Capsule().fill(AppColors.primary))
            .foregroundStyle(AppColors.onPrimary)
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        }
    }
}
