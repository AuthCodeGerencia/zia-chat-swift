import SwiftUI

struct ContentView: View {
    @StateObject private var store = CoreChannelsStore()
    @State private var showingSettings = false
    @State private var showingNewChannel = false
    @State private var navigationPath: [CoreChannel.ID] = []

    var body: some View {
        Group {
            if store.configuration.isUsable {
                NavigationStack(path: $navigationPath) {
                    ChannelListView(
                        store: store,
                        showingSettings: $showingSettings,
                        showingNewChannel: $showingNewChannel,
                        navigationPath: $navigationPath
                    )
                    .navigationDestination(for: CoreChannel.ID.self) { channelId in
                        if let channel = store.channel(with: channelId) {
                            ChatDetailView(store: store, channel: channel)
                        } else {
                            MissingChannelView()
                        }
                    }
                }
            } else {
                LoginView(store: store, showingSettings: $showingSettings)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(store: store)
        }
        .sheet(isPresented: $showingNewChannel) {
            NewChannelView(store: store)
        }
        .onChange(of: store.configuration.isUsable) { _, isUsable in
            if !isUsable {
                navigationPath.removeAll()
            }
        }
        .task {
            if store.configuration.isUsable {
                await store.refresh()
            }
        }
    }
}

private struct LoginView: View {
    @ObservedObject var store: CoreChannelsStore
    @Binding var showingSettings: Bool
    @State private var email = ""
    @State private var password = ""

    private var canLogin: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !password.isEmpty &&
        !store.isLoggingIn
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ZiaChat")
                            .font(.largeTitle.weight(.bold))
                        Text("Sign in with your Azank account to load Core channels.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }

                Section("Azank Login") {
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                }

                Section {
                    Button {
                        Task { await store.login(email: email, password: password) }
                    } label: {
                        HStack {
                            if store.isLoggingIn {
                                ProgressView()
                            }
                            Text(store.isLoggingIn ? "Signing in" : "Sign In")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canLogin)
                }

                if let error = store.lastError {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Login")
        }
    }
}

private struct ChannelListView: View {
    @ObservedObject var store: CoreChannelsStore
    @Binding var showingSettings: Bool
    @Binding var showingNewChannel: Bool
    @Binding var navigationPath: [CoreChannel.ID]

    var body: some View {
        List {
            if !store.configuration.isUsable {
                ConfigurationBanner {
                    showingSettings = true
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            Section {
                ForEach(store.favoriteChannels) { channel in
                    ChannelNavigationRow(store: store, channel: channel, navigationPath: $navigationPath)
                }
            } header: {
                if !store.favoriteChannels.isEmpty {
                    Label("Favorites", systemImage: "star.fill")
                }
            }

            Section {
                ForEach(store.textChannels) { channel in
                    ChannelNavigationRow(store: store, channel: channel, navigationPath: $navigationPath)
                }
            } header: {
                Label("Channels", systemImage: "number")
            }

            if !store.voiceChannels.isEmpty {
                Section {
                    ForEach(store.voiceChannels) { channel in
                        ChannelNavigationRow(store: store, channel: channel, navigationPath: $navigationPath)
                    }
                } header: {
                    Label("Voice", systemImage: "speaker.wave.2.fill")
                }
            }
        }
        .overlay {
            if store.isLoading && store.channels.isEmpty {
                ProgressView("Loading channels")
            } else if store.channels.isEmpty && store.configuration.isUsable {
                ContentUnavailableView(
                    "No channels yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Create the first Core channel for this company.")
                )
            }
        }
        .refreshable {
            await store.refresh()
        }
        .navigationTitle("ZiaChat")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    Button(role: .destructive) {
                        store.signOut()
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Image(systemName: "person.crop.circle")
                }
                .accessibilityLabel("Account")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNewChannel = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .disabled(!store.configuration.isUsable)
                .accessibilityLabel("New channel")
            }
        }
        .safeAreaInset(edge: .bottom) {
            SyncStatusBar(store: store)
        }
    }
}

private struct ChannelNavigationRow: View {
    @ObservedObject var store: CoreChannelsStore
    let channel: CoreChannel
    @Binding var navigationPath: [CoreChannel.ID]

    var body: some View {
        ChannelRowView(
            channel: channel,
            isFavorite: store.favoriteChannelIds.contains(channel.id),
            onToggleFavorite: {
                store.toggleFavorite(channel.id)
            }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedChannelId = channel.id
            navigationPath = [channel.id]
        }
        .accessibilityAddTraits(.isButton)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                store.toggleFavorite(channel.id)
            } label: {
                Label("Favorite", systemImage: store.favoriteChannelIds.contains(channel.id) ? "star.slash" : "star")
            }
            .tint(.yellow)
        }
    }
}

private struct ChannelRowView: View {
    let channel: CoreChannel
    let isFavorite: Bool
    let onToggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isFavorite ? .yellow : .secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(channel.tint.gradient)
                Image(systemName: channel.symbolName)
                    .foregroundStyle(.white)
                    .font(.headline)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(channel.displayName)
                        .font(.headline)
                        .lineLimit(1)

                    if channel.visibility == .private {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(channel.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                if channel.mentionCount > 0 {
                    CountBadge(text: "@\(CoreFormat.badgeCount(channel.mentionCount))", color: .red)
                } else if channel.unreadCount > 0 {
                    CountBadge(text: CoreFormat.badgeCount(channel.unreadCount), color: .green)
                }

                if channel.visibleAsSuperAdmin {
                    Text("admin")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ChatDetailView: View {
    @ObservedObject var store: CoreChannelsStore
    let channel: CoreChannel
    @State private var draft = ""
    @State private var replyTarget: CoreMessage?
    private let bottomID = "chat-bottom-anchor"

    var messages: [CoreMessage] {
        store.messages[channel.conversationId ?? ""] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            ChannelHeader(channel: channel)

            if channel.conversationId == nil {
                ContentUnavailableView(
                    "No conversation",
                    systemImage: "exclamationmark.bubble",
                    description: Text("This channel does not have a Core conversation attached.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            Color.clear
                                .frame(height: 1)
                                .id(bottomID)

                            if store.isLoadingMessages[channel.conversationId ?? ""] == true {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .scaleEffect(y: -1)
                            }

                            ForEach(messages.reversed()) { message in
                                MessageBubble(
                                    message: message,
                                    isMine: message.userId == store.configuration.userId,
                                    onReply: { replyTarget = message },
                                    onReact: { emoji in
                                        Task { await store.react(to: message, emoji: emoji) }
                                    }
                                )
                                .id(message.id)
                                .scaleEffect(y: -1)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 260)
                    }
                    .scaleEffect(y: -1)
                    .overlay {
                        if messages.isEmpty && store.isLoadingMessages[channel.conversationId ?? ""] != true {
                            ContentUnavailableView(
                                "No messages yet",
                                systemImage: "bubble.left",
                                description: Text(store.lastError ?? "Start the conversation in this channel.")
                            )
                        }
                    }
                    .onChange(of: messages.count) { _, _ in
                        scrollToBottom(proxy: proxy, animated: true)
                    }
                    .task(id: channel.id) {
                        await store.open(channel)
                        scrollToBottom(proxy: proxy, animated: false)
                    }
                }
            }

            ComposerView(
                channel: channel,
                draft: $draft,
                replyTarget: $replyTarget,
                isSending: store.isSending,
                onSend: {
                    let text = draft
                    let parentId = replyTarget?.id
                    draft = ""
                    replyTarget = nil
                    Task {
                        await store.send(text, in: channel, parentMessageId: parentId)
                    }
                }
            )
        }
        .navigationTitle(channel.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await store.open(channel, force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh messages")
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        guard !messages.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if animated {
                withAnimation(.snappy) {
                    proxy.scrollTo(bottomID, anchor: .top)
                }
            } else {
                proxy.scrollTo(bottomID, anchor: .top)
            }
        }
    }
}

private struct ChannelHeader: View {
    let channel: CoreChannel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: channel.symbolName)
                .foregroundStyle(.tint)
                .font(.headline)

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.displayName)
                    .font(.subheadline.weight(.semibold))
                Text(channel.descriptionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct MessageBubble: View {
    let message: CoreMessage
    let isMine: Bool
    let onReply: () -> Void
    let onReact: (String) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isMine {
                Spacer(minLength: 52)
            } else {
                AvatarView(name: message.authorName, avatarURL: message.author?.avatarURL)
            }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 5) {
                if !isMine {
                    Text(message.authorName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                if let parent = message.parent {
                    Text("Replying to \(parent.authorName): \(parent.content)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.horizontal, 10)
                }

                EmojiAwareText(
                    message.content.isEmpty ? "Attachment" : message.content,
                    font: .body,
                    color: isMine ? .white : .primary
                )
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isMine ? Color.accentColor : Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                if let attachments = message.attachments, !attachments.isEmpty {
                    AttachmentStrip(attachments: attachments)
                }

                HStack(spacing: 6) {
                    if let reactions = message.reactions, !reactions.isEmpty {
                        ForEach(reactions.groupedByEmoji, id: \.emoji) { item in
                            HStack(spacing: 3) {
                                EmojiGlyph(item.emoji, size: 14)
                                Text(String(item.count))
                                    .font(.caption2.weight(.semibold))
                            }
                            .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.thinMaterial)
                                .clipShape(Capsule())
                        }
                    }

                    Text(CoreFormat.relativeTime(message.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .contextMenu {
                Button {
                    onReply()
                } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }

                ForEach(["\u{1F44D}", "\u{2764}\u{FE0F}", "\u{1F602}", "\u{1F389}"], id: \.self) { emoji in
                    Button {
                        onReact(emoji)
                    } label: {
                        EmojiGlyph(emoji, size: 20)
                    }
                }
            }

            if !isMine {
                Spacer(minLength: 52)
            }
        }
    }
}

private struct ComposerView: View {
    let channel: CoreChannel
    @Binding var draft: String
    @Binding var replyTarget: CoreMessage?
    let isSending: Bool
    let onSend: () -> Void
    @State private var showEmojiPicker = false
    private let emojis = [
        "\u{1F600}", "\u{1F60A}", "\u{1F64C}", "\u{1F44D}", "\u{1F525}",
        "\u{2705}", "\u{1F389}", "\u{1F440}", "\u{1F4A1}", "\u{2764}\u{FE0F}",
        "\u{1F602}", "\u{1F60D}", "\u{1F914}", "\u{1F44F}", "\u{1F680}", "\u{1F4AF}"
    ]

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if let replyTarget {
                HStack {
                    Image(systemName: "arrowshape.turn.up.left")
                    Text(replyTarget.content)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        self.replyTarget = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemGroupedBackground))
            }

            if showEmojiPicker {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(emojis, id: \.self) { emoji in
                            Button {
                                draft.append(emoji)
                            } label: {
                                EmojiGlyph(emoji, size: 22)
                                    .frame(width: 34, height: 34)
                                    .background(Color(.secondarySystemGroupedBackground))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Insert emoji")
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
            }

            HStack(spacing: 10) {
                Button {
                    withAnimation(.snappy) {
                        showEmojiPicker.toggle()
                    }
                } label: {
                    Image(systemName: "face.smiling")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(showEmojiPicker ? Color.accentColor : .secondary)
                .accessibilityLabel("Emojis")

                TextField("Message #\(channel.displayName)", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .submitLabel(.send)
                    .onSubmit {
                        if canSend {
                            onSend()
                        }
                    }

                Button(action: onSend) {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
                .accessibilityLabel("Send message")
            }
            .padding()
            .background(.bar)
        }
    }
}

private struct NewChannelView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CoreChannelsStore
    @State private var name = ""
    @State private var description = ""
    @State private var visibility = CoreChannelVisibility.public

    var body: some View {
        NavigationStack {
            Form {
                Section("Channel") {
                    TextField("Name", text: $name)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                    Picker("Visibility", selection: $visibility) {
                        Text("Public").tag(CoreChannelVisibility.public)
                        Text("Private").tag(CoreChannelVisibility.private)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("New Channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            await store.createChannel(name: name, description: description, visibility: visibility)
                            if store.lastError == nil {
                                dismiss()
                            }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isCreatingChannel)
                }
            }
        }
    }
}

private struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CoreChannelsStore
    @State private var config: CoreAppConfiguration

    init(store: CoreChannelsStore) {
        self.store = store
        _config = State(initialValue: store.configuration)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Supabase") {
                    TextField("Project URL", text: $config.supabaseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    SecureField("Anon key", text: $config.anonKey)
                }

                Section("Session") {
                    SecureField("Access token", text: $config.accessToken)
                    TextField("User ID", text: $config.userId)
                        .textInputAutocapitalization(.never)
                    TextField("Company ID", text: $config.empresaIdText)
                        .keyboardType(.numberPad)
                    TextField("Display name", text: $config.displayName)
                }

                Section {
                    Text("ZiaChat reads Azank React Core channels through `core_list_user_channels`, creates channels through `core_create_channel`, and writes messages to `core_messages`.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Core Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.save(configuration: config)
                        Task { await store.refresh() }
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct ConfigurationBanner: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Connect Azank React Core", systemImage: "link.badge.plus")
                    .font(.headline)
                Text("Add Supabase URL, anon key, access token, user ID, and company ID.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.accentColor.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct SyncStatusBar: View {
    @ObservedObject var store: CoreChannelsStore

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var statusIcon: String {
        if store.isLoading { return "arrow.triangle.2.circlepath" }
        if store.lastError != nil { return "exclamationmark.triangle.fill" }
        return store.configuration.isUsable ? "checkmark.circle.fill" : "gearshape.fill"
    }

    private var statusColor: Color {
        if store.lastError != nil { return .orange }
        return store.configuration.isUsable ? .green : .secondary
    }

    private var statusText: String {
        if let error = store.lastError { return error }
        if store.isLoading { return "Syncing Azank React channels" }
        if store.configuration.isUsable { return "\(store.channels.count) channels synced" }
        return "Starter mode until Core settings are saved"
    }
}

private struct AttachmentStrip: View {
    let attachments: [CoreAttachment]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(attachments) { attachment in
                Link(destination: attachment.resolvedURL ?? URL(string: "about:blank")!) {
                    Label(attachment.fileName, systemImage: attachment.systemImage)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.thinMaterial)
                        .clipShape(Capsule())
                }
                .disabled(attachment.resolvedURL == nil)
            }
        }
    }
}

private struct AvatarView: View {
    let name: String
    let avatarURL: URL?

    var body: some View {
        AsyncImage(url: avatarURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                Circle()
                    .fill(Color.accentColor.gradient)
                    .overlay {
                        Text(CoreFormat.initials(name))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(Circle())
    }
}

private struct CountBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color)
            .clipShape(Capsule())
    }
}

private struct EmptyChannelSelectionView: View {
    let isConfigured: Bool

    var body: some View {
        ContentUnavailableView(
            isConfigured ? "Choose a channel" : "Configure Core",
            systemImage: isConfigured ? "number" : "gearshape",
            description: Text(isConfigured ? "Open an Azank Core channel to start chatting." : "Save your Supabase settings to load channels from Azank React.")
        )
    }
}

private struct MissingChannelView: View {
    var body: some View {
        ContentUnavailableView("Channel unavailable", systemImage: "exclamationmark.bubble")
    }
}

#Preview {
    ContentView()
}
