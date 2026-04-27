import SwiftUI
import SwiftData

// 1:1 port of android-app/.../ui/conversations/ConversationListScreen.kt.
// Top bar shows rocket icon + "Mobile Agent" branded title (primary color)
// with a tap-to-change model chip below — matching Android exactly. The
// settings gear is intentionally absent on this screen; on Android too,
// settings is reachable only from inside a chat (chat top bar's gear). The
// list itself is empty state + pinned/recent rows + Extended FAB ("New").

struct ConversationListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversationsRaw: [Conversation]

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

    /// Mirrors Android's "current model" chip — shows the most-recent
    /// conversation's model (Android tracks this on the activity; we
    /// derive it from SwiftData since the list view has no separate state).
    private var currentModelLabel: String {
        guard let recent = conversationsRaw.first(where: { !$0.modelPath.isEmpty }) else {
            return "empty"
        }
        return URL(fileURLWithPath: recent.modelPath)
            .deletingPathExtension().lastPathComponent
    }

    var body: some View {
        VStack(spacing: 0) {
            ConversationListHeader(modelLabel: currentModelLabel,
                                   onTapModel: onOpenModelSelect)
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
                        .listRowBackground(AppColors.surface)
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
                .scrollContentBackground(.hidden)
            }
        }
        .background(AppColors.surface.ignoresSafeArea())
        .overlay(alignment: .bottomTrailing) {
            NewConversationFAB(onTap: createConversation)
                .padding(.trailing, 16)
                .padding(.bottom, 16)
        }
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
    let modelLabel: String
    let onTapModel: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            // Rocket task-icon + "Mobile Agent" — Android paints both in the
            // task tint (primary). The rocket is Material's `RocketLaunch`;
            // the closest SF Symbol is `paperplane.fill` rotated, but
            // `arrow.up.right.circle.fill` with a tilt also reads close.
            // SF Symbols ship a `figure.run` style "rocket" — use SF
            // Symbols' actual `airplane.departure` / fall back to
            // `paperplane.fill` for the closest visual.
            HStack(spacing: 6) {
                MIcon(name: MIconName.rocketLaunch, size: 22, weight: .semibold)
                    .foregroundStyle(AppColors.primary)
                Text("Mobile Agent")
                    .font(.titleMediumNunito.weight(.semibold))
                    .foregroundStyle(AppColors.primary)
            }
            ModelPickerChip(label: modelLabel, onTap: onTapModel)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(AppColors.surface)
    }
}

/// Pill-shaped chip showing the current model. Tap → model select.
/// Mirrors Android's `ModelPickerChip` styling: surface-variant container,
/// caret on the right, accent text color.
private struct ModelPickerChip: View {
    let label: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 2) {
                Text(label)
                    .font(.bodyMediumNunito)
                    .foregroundStyle(AppColors.onSurface)
                MIcon(name: MIconName.arrowDropDown, size: 18,
                      weight: .regular)
                    .foregroundStyle(AppColors.onSurfaceVariant)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(AppColors.surfaceVariant)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Current model is \(label). Tap to change model.")
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            MIcon(name: MIconName.chatBubbleOutline, size: 36, weight: .regular)
                .foregroundStyle(AppColors.onSurfaceVariant)
            Text("No conversations yet")
                .font(.bodyMediumNunito)
                .foregroundStyle(AppColors.onSurfaceVariant)
            Text("Tap \"New\" to start chatting")
                .font(.bodySmallNunito)
                .foregroundStyle(AppColors.onSurfaceVariant)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(AppColors.surface)
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
                MIcon(name: MIconName.add, size: 20, weight: .semibold)
                Text("New")
                    .font(.labelLargeNunito.weight(.semibold))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Capsule().fill(AppColors.primary))
            .foregroundStyle(AppColors.onPrimary)
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        }
    }
}
