import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = CoreChannelsStore()
    @StateObject private var voiceStore = CoreVoiceRoomStore()
    @StateObject private var pushService = PushNotificationService.shared
    @State private var showingSettings = false
    @State private var showingNewChannel = false
    @State private var navigationPath: [CoreChannel.ID] = []
    @State private var pushNavigationTask: Task<Void, Never>?

    var body: some View {
        Group {
            if store.configuration.isUsable {
                NavigationStack(path: $navigationPath) {
                    ChannelListView(
                        store: store,
                        voiceStore: voiceStore,
                        showingSettings: $showingSettings,
                        showingNewChannel: $showingNewChannel,
                        navigationPath: $navigationPath
                    )
                    .navigationDestination(for: CoreChannel.ID.self) { channelId in
                        if let channel = store.channel(with: channelId) {
                            if channel.isVoice {
                                VoiceChannelView(
                                    store: store,
                                    voiceStore: voiceStore,
                                    channel: channel
                                )
                            } else {
                                ChatDetailView(store: store, channel: channel)
                            }
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
                Task { await voiceStore.leave() }
            } else {
                Task {
                    await pushService.requestAuthorizationAndRegister()
                    await pushService.registerCurrentToken(configuration: store.configuration)
                    schedulePendingPushNavigation()
                }
            }
        }
        .onChange(of: pushService.deviceToken) { _, token in
            guard token != nil else { return }
            Task { await pushService.registerCurrentToken(configuration: store.configuration) }
        }
        .onChange(of: pushService.pendingDestination) { _, destination in
            guard destination != nil else { return }
            schedulePendingPushNavigation()
        }
        .onChange(of: store.channels) { _, _ in
            schedulePendingPushNavigation()
        }
        .onChange(of: store.configuration.accessToken) { _, _ in
            Task { await pushService.registerCurrentToken(configuration: store.configuration) }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, store.configuration.isUsable else { return }
            Task {
                _ = try? await store.ensureFreshSession()
                schedulePendingPushNavigation()
            }
        }
        .task(id: store.configuration.userId) {
            guard store.configuration.isUsable else { return }
            await store.maintainSession()
        }
        .task {
            if store.configuration.isUsable {
                _ = try? await store.ensureFreshSession()
                await store.refresh()
                await pushService.requestAuthorizationAndRegister()
                await pushService.registerCurrentToken(configuration: store.configuration)
                schedulePendingPushNavigation()
            }
        }
        .preferredColorScheme(.light)
    }

    private func schedulePendingPushNavigation() {
        guard scenePhase == .active,
              pushService.pendingDestination != nil,
              pushNavigationTask == nil else {
            return
        }
        pushNavigationTask = Task {
            // Let SwiftUI finish restoring the NavigationStack after a notification launch.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, scenePhase == .active else {
                pushNavigationTask = nil
                return
            }
            await openPendingPushDestination()
            pushNavigationTask = nil
        }
    }

    private func openPendingPushDestination() async {
        guard let destination = pushService.pendingDestination,
              store.configuration.isUsable else {
            return
        }

        var latestError: Error?
        for attempt in 0..<3 {
            guard !Task.isCancelled,
                  pushService.pendingDestination == destination else {
                return
            }

            do {
                if let channel = try await store.channelForNotification(
                    channelId: destination.channelId,
                    conversationId: destination.conversationId
                ) {
                    store.selectedChannelId = channel.id
                    navigationPath = [channel.id]
                    pushService.consume(destination)
                    pushService.lastError = nil
                    return
                }
            } catch {
                latestError = error
            }

            if attempt < 2 {
                try? await Task.sleep(for: .milliseconds(450 * (attempt + 1)))
            }
        }

        pushService.lastError = latestError?.localizedDescription
            ?? "The chat from this notification is not available for this account."
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
    @ObservedObject var voiceStore: CoreVoiceRoomStore
    @Binding var showingSettings: Bool
    @Binding var showingNewChannel: Bool
    @Binding var navigationPath: [CoreChannel.ID]
    @State private var searchText = ""
    @State private var selectedSection: ChannelListSection = .channels

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        List {
            if !store.configuration.isUsable {
                ConfigurationBanner {
                    showingSettings = true
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            if selectedSection == .direct {
                directMessageContent
            } else if isSearching {
                channelSearchContent
            } else {
                defaultChannelContent
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.white)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .listSectionSpacing(0)
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
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: selectedSection == .channels ? "Buscar palabras clave en canales" : "Buscar chats directos"
        )
        .onChange(of: searchText) { _, newValue in
            if selectedSection == .channels {
                store.updateChannelSearch(newValue)
            }
        }
        .onChange(of: selectedSection) { _, _ in
            searchText = ""
            store.clearChannelSearch()
        }
        .navigationTitle(selectedSection == .channels ? "ZiaChat" : "Directos")
        .toolbarBackground(Color.white, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if selectedSection == .channels {
                    Button {
                        showingNewChannel = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(!store.configuration.isUsable)
                    .accessibilityLabel("New channel")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if let channel = voiceStore.connectedChannel {
                    ConnectedVoiceBar(
                        voiceStore: voiceStore,
                        channel: channel,
                        onOpen: {
                            store.selectedChannelId = channel.id
                            navigationPath = [channel.id]
                        }
                    )
                }

                ChannelBottomBar(
                    selection: $selectedSection,
                    onSettings: { showingSettings = true },
                    onSignOut: { store.signOut() }
                )
            }
        }
    }

    @ViewBuilder
    private var directMessageContent: some View {
        if filteredDirectMessages.isEmpty {
            ContentUnavailableView(
                searchText.isEmpty ? "No hay chats directos" : "Sin resultados",
                systemImage: searchText.isEmpty ? "person.2" : "magnifyingglass",
                description: Text(
                    searchText.isEmpty
                        ? "Tus conversaciones directas de Azank aparecerán aquí."
                        : "No encontramos un chat directo con ese nombre."
                )
            )
            .listRowSeparator(.hidden)
        } else {
            Section {
                ForEach(filteredDirectMessages) { directMessage in
                    DirectMessageRow(directMessage: directMessage)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            store.selectedChannelId = directMessage.id
                            navigationPath = [directMessage.id]
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        .listRowBackground(Color.white)
                }
            }
        }
    }

    private var filteredDirectMessages: [CoreDirectMessage] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.directMessages }
        return store.directMessages.filter {
            $0.peer.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private var defaultChannelContent: some View {
        Section {
            ForEach(sortedTextChannels) { channel in
                ChannelNavigationRow(store: store, channel: channel, navigationPath: $navigationPath)
            }
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

    private var sortedTextChannels: [CoreChannel] {
        store.textChannels.sorted { first, second in
            let firstFavorite = store.favoriteChannelIds.contains(first.id)
            let secondFavorite = store.favoriteChannelIds.contains(second.id)
            if firstFavorite != secondFavorite {
                return firstFavorite
            }

            let firstDate = first.conversationId.flatMap { store.channelPreviews[$0]?.createdAt }
            let secondDate = second.conversationId.flatMap { store.channelPreviews[$0]?.createdAt }
            if firstDate != secondDate {
                return (firstDate ?? .distantPast) > (secondDate ?? .distantPast)
            }
            return first.displayName.localizedCaseInsensitiveCompare(second.displayName) == .orderedAscending
        }
    }

    @ViewBuilder
    private var channelSearchContent: some View {
        if store.isSearchingChannels {
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Buscando incidencias…")
                        .foregroundStyle(.secondary)
                }
            }
        } else if store.channelSearchResults.isEmpty {
            Section {
                ContentUnavailableView(
                    "Sin resultados",
                    systemImage: "magnifyingglass",
                    description: Text("No hay incidencias de \"\(searchText)\" en tus canales.")
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        } else {
            Section {
                ForEach(store.channelSearchResults) { hit in
                    ChannelSearchResultRow(hit: hit) {
                        store.selectedChannelId = hit.channel.id
                        navigationPath = [hit.channel.id]
                        searchText = ""
                        store.clearChannelSearch()
                    }
                }
            } header: {
                Label("\(store.channelSearchResults.count) canales con incidencias", systemImage: "text.magnifyingglass")
            }
        }
    }
}

private enum ChannelListSection {
    case channels
    case direct
}

private struct ChannelBottomBar: View {
    @Binding var selection: ChannelListSection
    let onSettings: () -> Void
    let onSignOut: () -> Void

    var body: some View {
        HStack {
            Button {
                selection = .channels
            } label: {
                BottomBarItem(
                    title: "Canales",
                    symbol: selection == .channels ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right",
                    selected: selection == .channels
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            Button {
                selection = .direct
            } label: {
                BottomBarItem(
                    title: "Directos",
                    symbol: selection == .direct ? "person.2.fill" : "person.2",
                    selected: selection == .direct
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            Menu {
                Button(action: onSettings) {
                    Label("Settings", systemImage: "gearshape")
                }
                Button(role: .destructive, action: onSignOut) {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 21, weight: .semibold))
                    Text("Profile")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 49)
        .padding(.horizontal, 28)
        .background(Color.white)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

private struct BottomBarItem: View {
    let title: String
    let symbol: String
    let selected: Bool

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
            Text(title)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(selected ? Color.accentColor : .secondary)
    }
}

private struct DirectMessageRow: View {
    let directMessage: CoreDirectMessage

    var body: some View {
        HStack(spacing: 11) {
            AvatarView(name: directMessage.peer.displayName, avatarURL: directMessage.peer.avatarURL)
                .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(directMessage.peer.displayName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(directMessage.lastMessageContent.flatMap(nonBlankText) ?? "Sin mensajes todavía")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 5) {
                if let date = directMessage.lastMessageCreatedAt {
                    Text(CoreFormat.conversationTime(date))
                        .font(.caption2)
                        .foregroundStyle(directMessage.unreadCount > 0 ? Color.green : .secondary)
                }
                if directMessage.unreadCount > 0 {
                    CountBadge(text: CoreFormat.badgeCount(directMessage.unreadCount), color: .green)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func nonBlankText(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct ChannelSearchResultRow: View {
    let hit: CoreChannelSearchHit
    let onOpen: () -> Void

    private var incidenceLabel: String {
        hit.incidenceCount == 1 ? "1 incidencia" : "\(hit.incidenceCount) incidencias"
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                ChannelLogoView(channel: hit.channel, size: 42)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(hit.channel.displayName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if hit.channel.visibility == .private {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let preview = hit.previewSnippet, !preview.isEmpty {
                        Text(preview)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                Text(incidenceLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

private struct ChannelNavigationRow: View {
    @ObservedObject var store: CoreChannelsStore
    let channel: CoreChannel
    @Binding var navigationPath: [CoreChannel.ID]

    var body: some View {
        ChannelRowView(
            channel: channel,
            preview: channel.conversationId.flatMap { store.channelPreviews[$0] },
            isFavorite: store.favoriteChannelIds.contains(channel.id)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedChannelId = channel.id
            navigationPath = [channel.id]
        }
        .accessibilityAddTraits(.isButton)
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .listRowBackground(Color.white)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                store.toggleFavorite(channel.id)
            } label: {
                Label(
                    store.favoriteChannelIds.contains(channel.id) ? "Unpin" : "Pin",
                    systemImage: store.favoriteChannelIds.contains(channel.id) ? "pin.slash.fill" : "pin.fill"
                )
            }
            .tint(.orange)
        }
    }
}

private struct ChannelRowView: View {
    let channel: CoreChannel
    let preview: CoreMessage?
    let isFavorite: Bool

    var body: some View {
        HStack(spacing: 11) {
            ChannelLogoView(channel: channel, size: 40)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(channel.displayName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)

                    if channel.visibility == .private {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                ChannelPreviewText(preview: preview, fallback: channel.subtitle)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 4) {
                if let preview {
                    Text(CoreFormat.conversationTime(preview.createdAt))
                        .font(.caption2)
                        .foregroundStyle(channel.unreadCount > 0 ? Color.green : .secondary)
                }

                HStack(spacing: 6) {
                    if isFavorite {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Pinned")
                    }

                    if channel.mentionCount > 0 {
                        CountBadge(text: "@\(CoreFormat.badgeCount(channel.mentionCount))", color: .red)
                    } else if channel.unreadCount > 0 {
                        CountBadge(text: CoreFormat.badgeCount(channel.unreadCount), color: .green)
                    }
                }

                if channel.visibleAsSuperAdmin {
                    Text("admin")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

private struct ChannelPreviewText: View {
    let preview: CoreMessage?
    let fallback: String

    var body: some View {
        if let preview {
            HStack(spacing: 5) {
                if preview.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let attachment = preview.attachments?.first {
                    Image(systemName: attachment.isGIF ? "sparkles.rectangle.stack" : attachment.systemImage)
                        .font(.caption)
                    Text(attachment.isGIF ? "GIF" : attachment.isImage ? "Photo" : attachment.fileName)
                } else {
                    Text(preview.content)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else {
            Text(fallback)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct ChatDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CoreChannelsStore
    let channel: CoreChannel
    @State private var draft = ""
    @State private var replyTarget: CoreMessage?
    @State private var pendingAttachments: [CorePendingAttachment] = []
    @State private var selectedMessage: CoreMessage?
    @State private var threadRoot: CoreMessage?
    @State private var messageToForward: CoreMessage?
    @FocusState private var isComposerFocused: Bool
    private let bottomID = "chat-bottom-anchor"

    var messages: [CoreMessage] {
        store.messages[channel.conversationId ?? ""] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            ChatTopBar(
                channel: channel,
                onBack: { dismiss() },
                onRefresh: { Task { await store.open(channel, force: true) } }
            )

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
                                    mentionableUsers: store.members(for: channel),
                                    currentUserName: store.configuration.displayName,
                                    onReply: { threadRoot = message },
                                    onLongPress: { selectedMessage = message },
                                    onThread: { threadRoot = message },
                                    onReact: { emoji in
                                        Task { await store.react(to: message, emoji: emoji) }
                                    }
                                )
                                .id(message.id)
                                .scaleEffect(y: -1)
                                .onAppear {
                                    guard message.id == messages.first?.id else { return }
                                    Task { await store.loadOlderMessages(in: channel) }
                                }
                            }

                            if store.isLoadingOlderMessages[channel.conversationId ?? ""] == true {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .scaleEffect(y: -1)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 260)
                    }
                    .scaleEffect(y: -1)
                    .scrollDismissesKeyboard(.interactively)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isComposerFocused = false
                    }
                    .overlay {
                        if messages.isEmpty && store.isLoadingMessages[channel.conversationId ?? ""] != true {
                            ContentUnavailableView(
                                "No messages yet",
                                systemImage: "bubble.left",
                                description: Text(store.lastError ?? "Start the conversation in this channel.")
                            )
                        }
                    }
                    .onChange(of: messages.last?.id) { _, _ in
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
                attachments: $pendingAttachments,
                mentionableUsers: store.members(for: channel),
                isSending: store.isSending,
                isFocused: $isComposerFocused,
                onSend: {
                    let text = draft
                    let parentId = replyTarget?.id
                    let attachments = pendingAttachments
                    draft = ""
                    replyTarget = nil
                    pendingAttachments = []
                    Task {
                        await store.send(
                            text,
                            attachments: attachments,
                            in: channel,
                            parentMessageId: parentId
                        )
                    }
                }
            )
        }
        .toolbar(.hidden, for: .navigationBar)
        .background(Color.white)
        .overlay {
            if let selectedMessage {
                MessageActionOverlay(
                    message: selectedMessage,
                    isMine: selectedMessage.userId == store.configuration.userId,
                    onDismiss: { self.selectedMessage = nil },
                    onReply: {
                        threadRoot = selectedMessage
                        self.selectedMessage = nil
                    },
                    onForward: {
                        messageToForward = selectedMessage
                        self.selectedMessage = nil
                    },
                    onCopy: {
                        UIPasteboard.general.string = selectedMessage.content
                        self.selectedMessage = nil
                    },
                    onThread: {
                        threadRoot = selectedMessage
                        self.selectedMessage = nil
                    },
                    onReact: { emoji in
                        self.selectedMessage = nil
                        Task { await store.react(to: selectedMessage, emoji: emoji) }
                    }
                )
                .transition(.opacity)
                .zIndex(20)
            }
        }
        .sheet(item: $threadRoot) { message in
            ThreadView(store: store, channel: channel, root: message)
        }
        .sheet(item: $messageToForward) { message in
            ForwardMessageView(store: store, message: message)
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

private struct ChatTopBar: View {
    let channel: CoreChannel
    let onBack: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel("Back")

            ChannelLogoView(channel: channel, size: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(channel.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(channel.visibility == .private ? "Private channel" : "Channel")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel("Refresh messages")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct VoiceChannelView: View {
    @ObservedObject var store: CoreChannelsStore
    @ObservedObject var voiceStore: CoreVoiceRoomStore
    let channel: CoreChannel

    var body: some View {
        VStack(spacing: 0) {
            VoiceChannelHeader(channel: channel)

            Group {
                if voiceStore.connectedChannel?.id == channel.id, voiceStore.isConnected {
                    participantList
                } else if voiceStore.connectionState == .requestingAccess ||
                            voiceStore.connectionState == .connecting {
                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.large)
                        Text(voiceStore.connectionState == .requestingAccess
                             ? "Requesting microphone access"
                             : "Connecting to voice")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("Voice unavailable", systemImage: "waveform.slash")
                    } description: {
                        Text(voiceStore.lastError ?? "Join this channel to start talking.")
                    } actions: {
                        Button("Try Again") {
                            Task { await joinVoiceChannel() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

            if voiceStore.connectedChannel?.id == channel.id, voiceStore.isConnected {
                VoiceControls(voiceStore: voiceStore)
            }
        }
        .navigationTitle(channel.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: channel.id) {
            await joinVoiceChannel()
        }
    }

    private func joinVoiceChannel() async {
        do {
            let configuration = try await store.ensureFreshSession()
            await voiceStore.join(channel: channel, configuration: configuration)
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private var participantList: some View {
        List {
            Section {
                ForEach(voiceStore.participants) { participant in
                    VoiceParticipantRow(participant: participant)
                }
            } header: {
                Text("\(voiceStore.participants.count) connected")
            }
        }
        .listStyle(.plain)
        .overlay {
            if voiceStore.participants.isEmpty {
                ProgressView("Loading participants")
            }
        }
    }
}

private struct VoiceChannelHeader: View {
    let channel: CoreChannel

    var body: some View {
        HStack(spacing: 10) {
            ChannelLogoView(channel: channel, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.displayName)
                    .font(.subheadline.weight(.semibold))
                Text("Voice channel")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.white)
    }
}

private struct VoiceParticipantRow: View {
    let participant: CoreVoiceParticipant

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.14))
                Text(initials)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.accentColor)
            }
            .overlay {
                Circle()
                    .stroke(participant.isSpeaking ? Color.green : Color.clear, lineWidth: 3)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(participant.name)
                        .font(.body.weight(.semibold))
                    if participant.isLocal {
                        Text("You")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(participant.isSpeaking ? "Speaking" : "Connected")
                    .font(.caption)
                    .foregroundStyle(participant.isSpeaking ? Color.green : .secondary)
            }

            Spacer()

            Image(systemName: participant.isMuted ? "mic.slash.fill" : "mic.fill")
                .foregroundStyle(participant.isMuted ? .secondary : Color.green)
                .frame(width: 28, height: 28)
                .accessibilityLabel(participant.isMuted ? "Muted" : "Microphone on")
        }
        .padding(.vertical, 4)
    }

    private var initials: String {
        let parts = participant.name.split(separator: " ").prefix(2)
        let value = parts.compactMap(\.first).map(String.init).joined()
        return value.isEmpty ? "?" : value.uppercased()
    }
}

private struct VoiceControls: View {
    @ObservedObject var voiceStore: CoreVoiceRoomStore

    var body: some View {
        HStack(spacing: 24) {
            VoiceControlButton(
                title: voiceStore.isMuted ? "Unmute" : "Mute",
                systemImage: voiceStore.isMuted ? "mic.slash.fill" : "mic.fill",
                isActive: voiceStore.isMuted
            ) {
                Task { await voiceStore.toggleMute() }
            }

            VoiceControlButton(
                title: "Speaker",
                systemImage: voiceStore.isSpeakerEnabled ? "speaker.wave.2.fill" : "speaker.fill",
                isActive: voiceStore.isSpeakerEnabled
            ) {
                voiceStore.toggleSpeaker()
            }

            VoiceControlButton(
                title: "Leave",
                systemImage: "phone.down.fill",
                color: .red,
                isActive: true
            ) {
                Task { await voiceStore.leave() }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.vertical, 14)
        .background(.bar)
    }
}

private struct VoiceControlButton: View {
    let title: String
    let systemImage: String
    var color: Color = .accentColor
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .frame(width: 48, height: 48)
                    .background(isActive ? color : Color(.tertiarySystemFill))
                    .foregroundStyle(isActive ? .white : .primary)
                    .clipShape(Circle())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            .frame(width: 68)
        }
        .buttonStyle(.plain)
    }
}

private struct ConnectedVoiceBar: View {
    @ObservedObject var voiceStore: CoreVoiceRoomStore
    let channel: CoreChannel
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    ChannelLogoView(channel: channel, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(channel.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                Task { await voiceStore.toggleMute() }
            } label: {
                Image(systemName: voiceStore.isMuted ? "mic.slash.fill" : "mic.fill")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(voiceStore.isMuted ? "Unmute" : "Mute")

            Button(role: .destructive) {
                Task { await voiceStore.leave() }
            } label: {
                Image(systemName: "phone.down.fill")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Leave voice channel")
        }
        .padding(.horizontal)
        .padding(.vertical, 9)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var statusText: String {
        switch voiceStore.connectionState {
        case .reconnecting:
            return "Reconnecting"
        case .connected:
            return "\(voiceStore.participants.count) connected"
        default:
            return "Voice channel"
        }
    }
}

private struct MessageBubble: View {
    let message: CoreMessage
    let isMine: Bool
    let mentionableUsers: [CoreUserLite]
    let currentUserName: String
    let onReply: () -> Void
    let onLongPress: () -> Void
    let onThread: () -> Void
    let onReact: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isMine {
                Spacer(minLength: 52)
            } else {
                AvatarView(name: message.authorName, avatarURL: message.author?.avatarURL)
            }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 5) {
                if !isMine {
                    Text(message.authorName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(authorColor)
                }

                if let parent = message.parent {
                    Text("Replying to \(parent.authorName): \(parent.content)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.horizontal, 10)
                }

                if !message.content.isEmpty {
                    EmojiAwareText(
                        message.content,
                        font: .body,
                        color: .primary,
                        mentionableUsers: mentionableUsers,
                        currentUserName: currentUserName
                    )
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isMine ? Color(red: 0.85, green: 0.97, blue: 0.82) : Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        if !isMine {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.black.opacity(0.06), lineWidth: 1)
                        }
                    }
                    .shadow(color: .black.opacity(isMine ? 0.03 : 0.06), radius: 1, y: 1)
                }

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

                if let replyCount = message.replyCount, replyCount > 0 {
                    Button(action: onThread) {
                        Label(
                            "\(replyCount) \(replyCount == 1 ? "reply" : "replies")",
                            systemImage: "bubble.left.and.bubble.right"
                        )
                        .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.35, perform: onLongPress)

            if !isMine {
                Spacer(minLength: 52)
            }
        }
    }

    private var authorColor: Color {
        let colors: [Color] = [
            Color(red: 0.07, green: 0.45, blue: 0.73),
            Color(red: 0.63, green: 0.20, blue: 0.58),
            Color(red: 0.84, green: 0.32, blue: 0.18),
            Color(red: 0.10, green: 0.55, blue: 0.38),
            Color(red: 0.72, green: 0.42, blue: 0.05)
        ]
        let value = message.userId.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return colors[value % colors.count]
    }
}

private struct MessageActionOverlay: View {
    let message: CoreMessage
    let isMine: Bool
    let onDismiss: () -> Void
    let onReply: () -> Void
    let onForward: () -> Void
    let onCopy: () -> Void
    let onThread: () -> Void
    let onReact: (String) -> Void

    private let reactions = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    var body: some View {
        ZStack {
            Color.black.opacity(0.46)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(alignment: isMine ? .trailing : .leading, spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(reactions, id: \.self) { emoji in
                        Button {
                            onReact(emoji)
                        } label: {
                            EmojiGlyph(emoji, size: 28)
                                .frame(width: 40, height: 40)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.regularMaterial)
                .clipShape(Capsule())

                MessageContextPreview(message: message, isMine: isMine)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(spacing: 0) {
                    MessageActionRow(title: "Reply in thread", systemImage: "arrowshape.turn.up.left", action: onReply)
                    Divider().padding(.leading, 16)
                    MessageActionRow(title: "Forward", systemImage: "arrowshape.turn.up.right", action: onForward)
                    Divider().padding(.leading, 16)
                    MessageActionRow(title: "Copy", systemImage: "doc.on.doc", action: onCopy)
                    Divider().padding(.leading, 16)
                    MessageActionRow(title: "Open thread", systemImage: "bubble.left.and.bubble.right", action: onThread)
                }
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .frame(maxWidth: 300, alignment: isMine ? .trailing : .leading)
            .padding(.horizontal, 24)
        }
        .animation(nil, value: message.id)
    }
}

private struct MessageActionRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: systemImage)
                    .font(.title3)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MessageContextPreview: View {
    let message: CoreMessage
    let isMine: Bool

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 6) {
            if !isMine {
                Text(message.authorName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if !message.content.isEmpty {
                EmojiAwareText(
                    message.content,
                    font: .body,
                    color: .primary
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(isMine ? Color(red: 0.85, green: 0.97, blue: 0.82) : Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            if let attachment = message.attachments?.first,
               attachment.isImage,
               let url = attachment.resolvedURL {
                AttachmentMediaView(url: url, isGIF: attachment.isGIF)
                    .frame(width: 220, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Text(CoreFormat.relativeTime(message.createdAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: 280, alignment: isMine ? .trailing : .leading)
        .background(Color(.systemBackground))
    }
}

private struct ForwardMessageView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CoreChannelsStore
    let message: CoreMessage

    var body: some View {
        NavigationStack {
            List(store.textChannels) { channel in
                Button {
                    Task {
                        await store.forward(message, to: channel)
                        if store.lastError == nil {
                            dismiss()
                        }
                    }
                } label: {
                    HStack(spacing: 12) {
                        ChannelLogoView(channel: channel, size: 38)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(channel.displayName)
                                .foregroundStyle(.primary)
                            Text(channel.descriptionText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .disabled(store.isSending)
            }
            .navigationTitle("Forward to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct ChannelLogoView: View {
    let channel: CoreChannel
    let size: CGFloat

    var body: some View {
        Group {
            if let iconURL = channel.metadata?.iconImage.flatMap(URL.init(string:)) {
                AsyncImage(url: iconURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: min(10, size * 0.24), style: .continuous))
    }

    private var fallback: some View {
        ZStack {
            RoundedRectangle(cornerRadius: min(10, size * 0.24), style: .continuous)
                .fill(channel.tint.gradient)
            Image(systemName: channel.symbolName)
                .foregroundStyle(.white)
                .font(.system(size: max(13, size * 0.4), weight: .semibold))
        }
    }
}

private struct ThreadView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CoreChannelsStore
    let channel: CoreChannel
    let root: CoreMessage

    @State private var draft = ""
    @State private var attachments: [CorePendingAttachment] = []
    @State private var unusedReplyTarget: CoreMessage?
    @FocusState private var isFocused: Bool
    private let bottomID = "thread-bottom"

    private var replies: [CoreMessage] {
        store.threadReplies[root.id] ?? []
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ThreadMessageRow(
                                message: root,
                                isRoot: true,
                                mentionableUsers: store.members(for: channel),
                                currentUserName: store.configuration.displayName
                            )

                            if store.isLoadingThread[root.id] == true {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .padding()
                            } else if replies.isEmpty {
                                Text("Be the first to reply in this thread.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 28)
                            } else {
                                ForEach(replies) { reply in
                                    ThreadMessageRow(
                                        message: reply,
                                        isRoot: false,
                                        mentionableUsers: store.members(for: channel),
                                        currentUserName: store.configuration.displayName
                                    )
                                }
                            }

                            Color.clear.frame(height: 1).id(bottomID)
                        }
                        .padding()
                    }
                    .onChange(of: replies.last?.id) { _, _ in
                        withAnimation(.snappy) {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    }
                }

                ComposerView(
                    channel: channel,
                    draft: $draft,
                    replyTarget: $unusedReplyTarget,
                    attachments: $attachments,
                    mentionableUsers: store.members(for: channel),
                    isSending: store.isSending,
                    isFocused: $isFocused,
                    onSend: {
                        let text = draft
                        let pending = attachments
                        draft = ""
                        attachments = []
                        Task {
                            await store.sendThreadReply(
                                text,
                                attachments: pending,
                                to: root,
                                in: channel
                            )
                        }
                    }
                )
            }
            .navigationTitle("Thread")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: root.id) {
                await store.loadThread(for: root)
            }
        }
    }
}

private struct ThreadMessageRow: View {
    let message: CoreMessage
    let isRoot: Bool
    let mentionableUsers: [CoreUserLite]
    let currentUserName: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(name: message.authorName, avatarURL: message.author?.avatarURL)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(message.authorName)
                        .font(.subheadline.weight(.semibold))
                    Text(CoreFormat.relativeTime(message.createdAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !message.content.isEmpty {
                    EmojiAwareText(
                        message.content,
                        font: .body,
                        color: .primary,
                        mentionableUsers: mentionableUsers,
                        currentUserName: currentUserName
                    )
                }

                if let attachments = message.attachments, !attachments.isEmpty {
                    AttachmentStrip(attachments: attachments)
                }

                if isRoot {
                    Text("Thread")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }

            Spacer()
        }
        .padding(.bottom, isRoot ? 12 : 0)
        .overlay(alignment: .bottom) {
            if isRoot { Divider() }
        }
    }
}

private struct ComposerView: View {
    let channel: CoreChannel
    @Binding var draft: String
    @Binding var replyTarget: CoreMessage?
    @Binding var attachments: [CorePendingAttachment]
    let mentionableUsers: [CoreUserLite]
    let isSending: Bool
    var isFocused: FocusState<Bool>.Binding
    let onSend: () -> Void
    @State private var showEmojiPicker = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isLoadingPhotos = false
    @State private var attachmentError: String?

    var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) &&
        !isLoadingPhotos &&
        !isSending
    }

    private var mentionSuggestions: [CoreUserLite] {
        guard let query = mentionQuery else { return [] }
        return Array(
            mentionableUsers
                .filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) }
                .prefix(6)
        )
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

            if !attachments.isEmpty || isLoadingPhotos || attachmentError != nil {
                PendingAttachmentStrip(
                    attachments: attachments,
                    isLoading: isLoadingPhotos,
                    error: attachmentError,
                    onRemove: { id in
                        attachments.removeAll { $0.id == id }
                    }
                )
            }

            if !mentionSuggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(mentionSuggestions) { user in
                        Button {
                            insertMention(user)
                        } label: {
                            HStack(spacing: 10) {
                                AvatarView(name: user.displayName, avatarURL: user.avatarURL)
                                Text(user.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 46)
                        }
                        .buttonStyle(.plain)

                        if user.id != mentionSuggestions.last?.id {
                            Divider().padding(.leading, 54)
                        }
                    }
                }
                .background(Color.white)
                .overlay(alignment: .top) { Divider() }
            }

            HStack(alignment: .bottom, spacing: 8) {
                HStack(alignment: .bottom, spacing: 4) {
                    Button {
                        withAnimation(.snappy) {
                            if showEmojiPicker {
                                showEmojiPicker = false
                                isFocused.wrappedValue = true
                            } else {
                                isFocused.wrappedValue = false
                                showEmojiPicker = true
                            }
                        }
                    } label: {
                        Image(systemName: showEmojiPicker ? "keyboard" : "face.smiling")
                            .font(.system(size: 20))
                            .frame(width: 34, height: 38)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(showEmojiPicker ? Color.accentColor : .secondary)
                    .accessibilityLabel("Emojis")

                    TextField("Message", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .focused(isFocused)
                        .lineLimit(1...5)
                        .padding(.vertical, 9)
                        .submitLabel(.send)
                        .onSubmit {
                            if canSend {
                                onSend()
                            }
                        }
                        .onTapGesture {
                            showEmojiPicker = false
                        }

                    PhotosPicker(
                        selection: $selectedPhotos,
                        maxSelectionCount: max(1, 5 - attachments.count),
                        matching: .images
                    ) {
                        Image(systemName: "photo")
                            .font(.system(size: 19))
                            .frame(width: 34, height: 38)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(attachments.count >= 5 || isLoadingPhotos || isSending)
                    .accessibilityLabel("Add photos or GIFs")
                }
                .padding(.horizontal, 4)
                .background(Color(red: 0.95, green: 0.96, blue: 0.96))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                Button(action: onSend) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color(red: 0.08, green: 0.65, blue: 0.42))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.35)
                .accessibilityLabel("Send message")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(Color.white)

            if showEmojiPicker {
                WhatsAppEmojiPicker(
                    onSelect: { draft.append($0) },
                    onDelete: {
                        guard !draft.isEmpty else { return }
                        draft.removeLast()
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPhotos(items) }
        }
        .onChange(of: isFocused.wrappedValue) { _, focused in
            if focused {
                showEmojiPicker = false
            }
        }
    }

    private var mentionQuery: String? {
        guard let atIndex = draft.lastIndex(of: "@") else { return nil }
        if atIndex > draft.startIndex {
            let previous = draft[draft.index(before: atIndex)]
            guard previous.isWhitespace else { return nil }
        }

        let query = String(draft[draft.index(after: atIndex)...])
        guard !query.contains(where: \.isWhitespace) else { return nil }
        return query
    }

    private func insertMention(_ user: CoreUserLite) {
        guard let atIndex = draft.lastIndex(of: "@") else { return }
        draft.replaceSubrange(atIndex..<draft.endIndex, with: "@\(user.displayName) ")
        isFocused.wrappedValue = true
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        isLoadingPhotos = true
        attachmentError = nil
        defer {
            selectedPhotos = []
            isLoadingPhotos = false
        }

        for item in items.prefix(max(0, 5 - attachments.count)) {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                guard data.count <= 15 * 1_024 * 1_024 else {
                    attachmentError = "Each image or GIF must be 15 MB or smaller."
                    continue
                }

                let contentType = item.supportedContentTypes.first(where: {
                    $0.conforms(to: .gif)
                }) ?? item.supportedContentTypes.first(where: {
                    $0.conforms(to: .image)
                }) ?? .jpeg
                let extensionName = contentType.preferredFilenameExtension ?? "jpg"
                attachments.append(
                    CorePendingAttachment(
                        data: data,
                        fileName: "image-\(UUID().uuidString).\(extensionName)",
                        mimeType: contentType.preferredMIMEType ?? "image/jpeg"
                    )
                )
            } catch {
                attachmentError = error.localizedDescription
            }
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

private struct AttachmentStrip: View {
    let attachments: [CoreAttachment]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(attachments) { attachment in
                if attachment.isImage, let url = attachment.resolvedURL {
                    Link(destination: url) {
                        AttachmentMediaView(url: url, isGIF: attachment.isGIF)
                            .frame(width: 220, height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(alignment: .bottomLeading) {
                                Text(attachment.fileName)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .padding(6)
                                    .foregroundStyle(.white)
                                    .background(.black.opacity(0.65))
                            }
                    }
                    .buttonStyle(.plain)
                } else {
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
}

private struct PendingAttachmentStrip: View {
    let attachments: [CorePendingAttachment]
    let isLoading: Bool
    let error: String?
    let onRemove: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        ZStack(alignment: .topTrailing) {
                            PendingAttachmentPreview(attachment: attachment)
                                .frame(width: 74, height: 74)
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                            Button {
                                onRemove(attachment.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.75))
                            }
                            .offset(x: 5, y: -5)
                            .accessibilityLabel("Remove attachment")
                        }
                    }

                    if isLoading {
                        ProgressView()
                            .frame(width: 74, height: 74)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
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
