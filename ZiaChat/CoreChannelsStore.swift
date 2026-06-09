import Foundation
import Combine

@MainActor
final class CoreChannelsStore: ObservableObject {
    @Published var configuration: CoreAppConfiguration
    @Published var channels: [CoreChannel] = CorePreviewData.channels
    @Published var messages: [String: [CoreMessage]] = CorePreviewData.messages
    @Published var selectedChannelId: CoreChannel.ID?
    @Published var favoriteChannelIds: Set<CoreChannel.ID> = []
    @Published var isLoading = false
    @Published var isSending = false
    @Published var isCreatingChannel = false
    @Published var isLoggingIn = false
    @Published var isLoadingMessages: [String: Bool] = [:]
    @Published var lastError: String?

    private var realtimeService: CoreRealtimeService?
    private var realtimeConversationId: String?
    private var reactionRefreshTask: Task<Void, Never>?
    private let optimisticMessagePrefix = "local-pending-"

    init(configuration: CoreAppConfiguration) {
        self.configuration = configuration
        self.selectedChannelId = channels.first?.id
    }

    convenience init() {
        self.init(configuration: CoreConfigurationStore.load())
    }

    var selectedChannel: CoreChannel? {
        selectedChannelId.flatMap(channel(with:))
    }

    var textChannels: [CoreChannel] {
        channels.filter { !$0.isVoice }
    }

    var voiceChannels: [CoreChannel] {
        channels.filter(\.isVoice)
    }

    var favoriteChannels: [CoreChannel] {
        channels.filter { favoriteChannelIds.contains($0.id) && !$0.isVoice }
    }

    func channel(with id: CoreChannel.ID) -> CoreChannel? {
        channels.first { $0.id == id }
    }

    func save(configuration: CoreAppConfiguration) {
        self.configuration = configuration
        CoreConfigurationStore.save(configuration)
    }

    func login(email: String, password: String) async {
        isLoggingIn = true
        lastError = nil
        do {
            let environment = CoreEnvironment.load()
            var loginConfiguration = configuration
            loginConfiguration.supabaseURL = environment.supabaseURL
            loginConfiguration.anonKey = environment.supabaseAnonKey
            save(configuration: loginConfiguration)

            let service = try CoreAuthService(configuration: loginConfiguration)
            let result = try await service.login(email: email, password: password)
            save(configuration: result.configuration)
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
        isLoggingIn = false
    }

    func signOut() {
        stopRealtime()
        var next = configuration
        next.clearSession()
        save(configuration: next)
        channels = CorePreviewData.channels
        messages = CorePreviewData.messages
        selectedChannelId = channels.first?.id
    }

    func toggleFavorite(_ channelId: CoreChannel.ID) {
        if favoriteChannelIds.contains(channelId) {
            favoriteChannelIds.remove(channelId)
        } else {
            favoriteChannelIds.insert(channelId)
        }
    }

    func refresh() async {
        guard configuration.isUsable else {
            channels = CorePreviewData.channels
            messages = CorePreviewData.messages
            selectedChannelId = selectedChannelId ?? channels.first?.id
            lastError = nil
            return
        }

        isLoading = true
        lastError = nil
        do {
            let client = try SupabaseCoreClient(configuration: configuration)
            channels = try await client.listChannels()
            selectedChannelId = selectedChannelId.flatMap(channel(with:))?.id ?? channels.first?.id
        } catch {
            lastError = error.localizedDescription
        }
        isLoading = false
    }

    func open(_ channel: CoreChannel, force: Bool = false) async {
        guard let conversationId = channel.conversationId else { return }
        selectedChannelId = channel.id
        guard configuration.isUsable else { return }
        startRealtime(for: channel)
        if !force, messages[conversationId]?.isEmpty == false {
            Task {
                if let client = try? SupabaseCoreClient(configuration: configuration) {
                    try? await client.markRead(conversationId: conversationId, lastReadMessageId: messages[conversationId]?.last?.id)
                }
            }
            clearUnread(for: channel.id)
            return
        }

        isLoadingMessages[conversationId] = true
        lastError = nil
        do {
            let client = try SupabaseCoreClient(configuration: configuration)
            Task {
                try? await client.ensureChannelMembership(channelId: channel.id, conversationId: conversationId)
            }
            let loaded = try await client.listMessagePage(conversationId: conversationId)
            messages[conversationId] = loaded
            clearUnread(for: channel.id)
            isLoadingMessages[conversationId] = false

            Task {
                try? await client.markRead(conversationId: conversationId, lastReadMessageId: loaded.last?.id)
            }
            if let enriched = try? await client.enrichMessages(loaded), !enriched.isEmpty {
                messages[conversationId] = enriched
            }
        } catch {
            lastError = error.localizedDescription
            isLoadingMessages[conversationId] = false
        }
    }

    func send(_ text: String, in channel: CoreChannel, parentMessageId: String? = nil) async {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, let conversationId = channel.conversationId else { return }
        guard configuration.isUsable else {
            appendPreviewMessage(content, channel: channel, parentMessageId: parentMessageId)
            return
        }

        let optimisticMessage = makeOptimisticMessage(
            content: content,
            channel: channel,
            conversationId: conversationId,
            parentMessageId: parentMessageId
        )
        upsertMessage(optimisticMessage)

        isSending = true
        lastError = nil
        do {
            let client = try SupabaseCoreClient(configuration: configuration)
            var message = try await client.sendMessage(
                empresaId: channel.empresaId,
                conversationId: conversationId,
                channelId: channel.id,
                parentMessageId: parentMessageId,
                content: content
            )
            message.author = optimisticMessage.author
            removeMessage(id: optimisticMessage.id, conversationId: conversationId)
            upsertMessage(message)
            Task {
                try? await client.markRead(conversationId: conversationId, lastReadMessageId: message.id)
            }
        } catch {
            removeMessage(id: optimisticMessage.id, conversationId: conversationId)
            lastError = error.localizedDescription
        }
        isSending = false
    }

    func createChannel(name: String, description: String, visibility: CoreChannelVisibility) async {
        guard configuration.isUsable else { return }
        isCreatingChannel = true
        lastError = nil
        do {
            let client = try SupabaseCoreClient(configuration: configuration)
            let channel = try await client.createChannel(name: name, description: description, visibility: visibility)
            channels.append(channel)
            channels.sort { $0.slug < $1.slug }
            selectedChannelId = channel.id
        } catch {
            lastError = error.localizedDescription
        }
        isCreatingChannel = false
    }

    func react(to message: CoreMessage, emoji: String) async {
        guard configuration.isUsable else { return }
        lastError = nil
        do {
            let client = try SupabaseCoreClient(configuration: configuration)
            try await client.react(
                empresaId: message.empresaId,
                conversationId: message.conversationId,
                messageId: message.id,
                emoji: emoji
            )
            if let channel = channels.first(where: { $0.conversationId == message.conversationId }) {
                await open(channel, force: true)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func clearUnread(for channelId: CoreChannel.ID) {
        guard let index = channels.firstIndex(where: { $0.id == channelId }) else { return }
        channels[index].unreadCount = 0
        channels[index].mentionCount = 0
    }

    private func appendPreviewMessage(_ content: String, channel: CoreChannel, parentMessageId: String?) {
        guard let conversationId = channel.conversationId else { return }
        let message = CoreMessage(
            id: UUID().uuidString,
            empresaId: channel.empresaId,
            conversationId: conversationId,
            channelId: channel.id,
            parentMessageId: parentMessageId,
            userId: configuration.userId.isEmpty ? "preview-user" : configuration.userId,
            content: content,
            createdAt: Date(),
            author: CoreUserLite(id: configuration.userId.isEmpty ? "preview-user" : configuration.userId, fullName: "You")
        )
        messages[conversationId, default: []].append(message)
    }

    private func makeOptimisticMessage(
        content: String,
        channel: CoreChannel,
        conversationId: String,
        parentMessageId: String?
    ) -> CoreMessage {
        CoreMessage(
            id: "\(optimisticMessagePrefix)\(UUID().uuidString)",
            empresaId: channel.empresaId,
            conversationId: conversationId,
            channelId: channel.id,
            parentMessageId: parentMessageId,
            userId: configuration.userId,
            content: content,
            createdAt: Date(),
            author: CoreUserLite(
                id: configuration.userId,
                fullName: configuration.displayName.isEmpty ? "You" : configuration.displayName
            )
        )
    }

    private func startRealtime(for channel: CoreChannel) {
        guard let conversationId = channel.conversationId else { return }
        guard realtimeConversationId != conversationId else { return }

        stopRealtime()
        realtimeConversationId = conversationId

        Task {
            do {
                let service = try CoreRealtimeService(configuration: configuration)
                realtimeService = service
                try await service.subscribe(
                    conversationId: conversationId,
                    onInsert: { [weak self] message in
                        await self?.handleRealtimeInsert(message)
                    },
                    onUpdate: { [weak self] message in
                        await self?.handleRealtimeUpdate(message)
                    },
                    onReactionChange: { [weak self] reaction, deletedReactionId in
                        await self?.handleRealtimeReaction(reaction, deletedReactionId: deletedReactionId)
                    }
                )
            } catch {
                await MainActor.run {
                    if self.realtimeConversationId == conversationId {
                        self.lastError = error.localizedDescription
                    }
                }
            }
        }
    }

    private func stopRealtime() {
        reactionRefreshTask?.cancel()
        reactionRefreshTask = nil
        realtimeConversationId = nil

        guard let realtimeService else { return }
        self.realtimeService = nil
        Task {
            await realtimeService.stop()
        }
    }

    private func handleRealtimeInsert(_ message: CoreMessage) async {
        guard message.conversationId == realtimeConversationId else { return }
        guard message.parentMessageId == nil, message.deletedAt == nil else { return }

        removeMatchingOptimisticMessage(for: message)
        upsertMessage(message)
        clearUnreadForActiveConversation(message.conversationId)

        if let client = try? SupabaseCoreClient(configuration: configuration) {
            try? await client.markRead(conversationId: message.conversationId, lastReadMessageId: message.id)
            if let enriched = try? await client.enrichMessages([message]).first {
                upsertMessage(enriched)
            }
        }
    }

    private func handleRealtimeUpdate(_ message: CoreMessage) async {
        guard message.conversationId == realtimeConversationId else { return }

        if message.deletedAt != nil || message.parentMessageId != nil {
            removeMessage(id: message.id, conversationId: message.conversationId)
            return
        }

        upsertMessage(message)
        if let client = try? SupabaseCoreClient(configuration: configuration),
           let enriched = try? await client.enrichMessages([message]).first {
            upsertMessage(enriched)
        }
    }

    private func handleRealtimeReaction(_ reaction: CoreReaction?, deletedReactionId: String?) async {
        guard let reaction else {
            scheduleReactionRefresh()
            return
        }

        var patched = false
        for (conversationId, conversationMessages) in messages where conversationId == realtimeConversationId {
            guard let messageIndex = conversationMessages.firstIndex(where: { $0.id == reaction.messageId }) else { continue }
            var nextMessages = conversationMessages
            var reactions = nextMessages[messageIndex].reactions ?? []

            if let deletedReactionId {
                reactions.removeAll { $0.id == deletedReactionId }
            } else if let reactionIndex = reactions.firstIndex(where: { $0.id == reaction.id }) {
                reactions[reactionIndex] = reaction
            } else {
                reactions.append(reaction)
            }

            nextMessages[messageIndex].reactions = reactions
            messages[conversationId] = nextMessages
            patched = true
        }

        if !patched {
            scheduleReactionRefresh()
        }
    }

    private func scheduleReactionRefresh() {
        reactionRefreshTask?.cancel()
        reactionRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await refreshActiveMessages()
        }
    }

    private func refreshActiveMessages() async {
        guard let selectedChannel else { return }
        await open(selectedChannel, force: true)
    }

    private func upsertMessage(_ message: CoreMessage) {
        var current = messages[message.conversationId, default: []]
        if let index = current.firstIndex(where: { $0.id == message.id }) {
            var copy = message
            copy.author = message.author ?? current[index].author
            copy.reactions = message.reactions ?? current[index].reactions
            copy.attachments = message.attachments ?? current[index].attachments
            copy.parent = message.parent ?? current[index].parent
            current[index] = copy
        } else {
            current.append(message)
        }

        current.sort { $0.createdAt < $1.createdAt }
        messages[message.conversationId] = current
    }

    private func removeMessage(id: String, conversationId: String) {
        messages[conversationId, default: []].removeAll { $0.id == id }
    }

    private func removeMatchingOptimisticMessage(for message: CoreMessage) {
        let pendingWindow: TimeInterval = 30
        messages[message.conversationId, default: []].removeAll { candidate in
            candidate.id.hasPrefix(optimisticMessagePrefix) &&
            candidate.userId == message.userId &&
            candidate.content == message.content &&
            abs(candidate.createdAt.timeIntervalSince(message.createdAt)) < pendingWindow
        }
    }

    private func clearUnreadForActiveConversation(_ conversationId: String) {
        guard let channel = channels.first(where: { $0.conversationId == conversationId }) else { return }
        clearUnread(for: channel.id)
    }
}

enum CorePreviewData {
    static let channels: [CoreChannel] = [
        CoreChannel(
            id: "preview-general",
            empresaId: 1,
            name: "general",
            slug: "general",
            description: "Company-wide updates from Azank React Core",
            conversationId: "preview-conversation-general",
            unreadCount: 3
        ),
        CoreChannel(
            id: "preview-private",
            empresaId: 1,
            name: "leadership",
            slug: "leadership",
            description: "Private decisions and follow-ups",
            visibility: .private,
            conversationId: "preview-conversation-leadership",
            mentionCount: 1
        ),
        CoreChannel(
            id: "preview-voice",
            empresaId: 1,
            name: "daily-standup",
            slug: "daily-standup",
            description: "Voice room",
            metadata: CoreChannelMetadata(channelType: "voice", iconImage: nil),
            conversationId: "preview-conversation-voice"
        )
    ]

    static let messages: [String: [CoreMessage]] = [
        "preview-conversation-general": [
            CoreMessage(
                id: "m1",
                empresaId: 1,
                conversationId: "preview-conversation-general",
                channelId: "preview-general",
                parentMessageId: nil,
                userId: "ana",
                content: "This mirrors the Core channel list, unread badges, and chat flow from azank-react.",
                createdAt: Date().addingTimeInterval(-3600),
                author: CoreUserLite(id: "ana", fullName: "Ana Martinez")
            ),
            CoreMessage(
                id: "m2",
                empresaId: 1,
                conversationId: "preview-conversation-general",
                channelId: "preview-general",
                parentMessageId: nil,
                userId: "preview-user",
                content: "Once Supabase settings are saved, these preview messages are replaced by real Core data.",
                createdAt: Date().addingTimeInterval(-1200),
                author: CoreUserLite(id: "preview-user", fullName: "You")
            )
        ],
        "preview-conversation-leadership": [
            CoreMessage(
                id: "m3",
                empresaId: 1,
                conversationId: "preview-conversation-leadership",
                channelId: "preview-private",
                parentMessageId: nil,
                userId: "zia",
                content: "@you review the private-channel membership rules from the React RPC before launch.",
                createdAt: Date().addingTimeInterval(-600),
                author: CoreUserLite(id: "zia", fullName: "Zia Core")
            )
        ]
    ]
}
