import SwiftUI

struct ContentView: View {
    private let conversations = Conversation.previewData

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(conversations) { conversation in
                        NavigationLink {
                            ChatDetailView(conversation: conversation)
                        } label: {
                            ConversationRow(conversation: conversation)
                        }
                    }
                } header: {
                    Text("Inbox")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("ZiaChat")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New conversation")
                }
            }
            .safeAreaInset(edge: .bottom) {
                StatusBar()
            }
        }
    }
}

private struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(conversation.tint.gradient)
                .frame(width: 44, height: 44)
                .overlay {
                    Text(conversation.initials)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(conversation.title)
                        .font(.headline)
                    Spacer()
                    Text(conversation.time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(conversation.lastMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ChatDetailView: View {
    let conversation: Conversation
    @State private var draftMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(conversation.messages) { message in
                        MessageBubble(message: message)
                    }
                }
                .padding()
            }

            HStack(spacing: 10) {
                TextField("Message", text: $draftMessage)
                    .textFieldStyle(.roundedBorder)

                Button {
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Send message")
            }
            .padding()
            .background(.bar)
        }
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.isMine {
                Spacer(minLength: 48)
            }

            Text(message.text)
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(message.isMine ? .white : .primary)
                .background(message.isMine ? Color.accentColor : Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            if !message.isMine {
                Spacer(minLength: 48)
            }
        }
    }
}

private struct StatusBar: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            Text("Starter ready for chat services, auth, and persistence.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct Conversation: Identifiable {
    let id = UUID()
    let title: String
    let initials: String
    let lastMessage: String
    let time: String
    let tint: Color
    let messages: [Message]

    static let previewData = [
        Conversation(
            title: "Zia Assistant",
            initials: "ZA",
            lastMessage: "I drafted the onboarding flow and marked the next service hooks.",
            time: "9:42",
            tint: .blue,
            messages: [
                Message(text: "Can you summarize what this starter needs next?", isMine: true),
                Message(text: "Yes. Add authentication, persist conversations, and connect the chat service layer.", isMine: false),
                Message(text: "Perfect. Keep the UI light for now.", isMine: true)
            ]
        ),
        Conversation(
            title: "Product",
            initials: "PR",
            lastMessage: "The empty state should invite the first real conversation.",
            time: "8:15",
            tint: .teal,
            messages: [
                Message(text: "The starter should feel intentional, not default.", isMine: true),
                Message(text: "Agreed. A small inbox and detail view is enough structure.", isMine: false)
            ]
        ),
        Conversation(
            title: "Support",
            initials: "SP",
            lastMessage: "No backend wired yet, but the view hierarchy is ready.",
            time: "Mon",
            tint: .indigo,
            messages: [
                Message(text: "Can this compile without network dependencies?", isMine: true),
                Message(text: "Yes. Everything here uses SwiftUI and local preview data.", isMine: false)
            ]
        )
    ]
}

private struct Message: Identifiable {
    let id = UUID()
    let text: String
    let isMine: Bool
}

#Preview {
    ContentView()
}
