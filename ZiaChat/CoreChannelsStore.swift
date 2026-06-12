import Foundation
import Combine

@MainActor
final class CoreChannelsStore: ObservableObject {
    @Published var configuration: CoreAppConfiguration
    @Published var channels: [CoreChannel] = CorePreviewData.channels
    @Published var directMessages: [CoreDirectMessage] = []
    @Published var messages: [String: [CoreMessage]] = CorePreviewData.messages
    @Published var messagePins: [String: [CoreMessagePin]] = [:]
    @Published var channelPreviews: [String: CoreMessage] = [:]
    @Published var polls: [String: CorePoll] = [:]
    @Published var mentionableUsers: [CoreUserLite] = []
    @Published var internalCompanies: [CoreInternalCompany] = []
    @Published var mutedChannelIds: Set<CoreChannel.ID> = Set(
        UserDefaults.standard.stringArray(forKey: CoreChannelsStore.mutedChannelsDefaultsKey) ?? []
    )
    @Published var channelMembers: [String: [CoreUserLite]] = [:]
    @Published var selectedChannelId: CoreChannel.ID?
    @Published var favoriteChannelIds: Set<CoreChannel.ID> = []
    @Published var isLoading = false
    @Published var isSending = false
    @Published var isCreatingChannel = false
    @Published var isLoggingIn = false
    @Published var isLoadingMessages: [String: Bool] = [:]
    @Published var isLoadingOlderMessages: [String: Bool] = [:]
    @Published var hasOlderMessages: [String: Bool] = [:]
    @Published var threadReplies: [String: [CoreMessage]] = [:]
    @Published var isLoadingThread: [String: Bool] = [:]
    @Published var channelThreads: [String: [CoreThreadSummary]] = [:]
    @Published var isLoadingChannelThreads: [String: Bool] = [:]
    @Published var isLoadingAllThreads = false
    /// conversationId → (userId → lastReadAt). Recibos de lectura por conversación.
    @Published var conversationReads: [String: [String: Date]] = [:]
    @Published var channelSearchQuery = ""
    @Published var channelSearchResults: [CoreChannelSearchHit] = []
    @Published var isSearchingChannels = false
    @Published var lastError: String?

    private var realtimeService: CoreRealtimeService?
    private var channelSearchTask: Task<Void, Never>?
    private var realtimeConversationId: String?
    private var realtimeReconnectTask: Task<Void, Never>?
    private var realtimeMessageRefreshTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var sessionRefreshTask: Task<CoreAppConfiguration, Error>?
    private let optimisticMessagePrefix = "local-pending-"

    init(configuration: CoreAppConfiguration) {
        self.configuration = configuration
        if configuration.isUsable,
           let cachedChannels = CoreChannelCache.load(userId: configuration.userId),
           !cachedChannels.isEmpty {
            self.channels = cachedChannels
        }
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
        if let channel = channels.first(where: { $0.id == id }) {
            return channel
        }
        if let dm = directMessages.first(where: { $0.id == id }) {
            return dmChannel(for: dm)
        }
        return nil
    }

    /// Canal "fantasma" para reutilizar ChatDetailView con un DM.
    func dmChannel(for dm: CoreDirectMessage) -> CoreChannel {
        CoreChannel(
            id: dm.id,
            empresaId: dm.empresaId,
            name: dm.peer.displayName,
            slug: "dm-\(dm.id)",
            description: "Mensaje directo",
            visibility: .private,
            metadata: CoreChannelMetadata(
                channelType: "dm",
                iconImage: dm.peer.avatarURLString
            ),
            conversationId: dm.id,
            unreadCount: dm.unreadCount,
            mentionCount: dm.mentionCount
        )
    }

    func loadDirectMessages() async {
        guard configuration.isUsable else {
            directMessages = []
            return
        }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try SupabaseCoreClient(configuration: activeConfiguration)
            directMessages = try await client.listDirectMessages()
        } catch {
            // RPC no desplegado u otro error: los DMs simplemente quedan vacíos.
        }
    }

    /// Encuentra o crea el DM con otra persona (POST /api/core/dms, igual que
    /// la web) y devuelve el canal fantasma listo para abrir.
    func startDirectMessage(with user: CoreUserLite) async -> CoreChannel? {
        guard configuration.isUsable, user.id != configuration.userId else { return nil }
        lastError = nil
        do {
            let payload = try await coreAPIRequest(
                path: "/api/core/dms",
                method: "POST",
                body: ["peerUserId": user.id]
            )
            guard payload["ok"] as? Bool == true,
                  let dmPayload = payload["dm"] as? [String: Any],
                  let conversationId = dmPayload["id"] as? String else {
                lastError = (payload["error"] as? String) ?? "No se pudo iniciar el DM."
                return nil
            }
            let empresaId = (dmPayload["empresa_id"] as? Int) ?? configuration.empresaId ?? 0
            var peer = user
            if let peerPayload = dmPayload["peer"] as? [String: Any] {
                peer = CoreUserLite(
                    id: (peerPayload["id"] as? String) ?? user.id,
                    fullName: (peerPayload["full_name"] as? String) ?? user.fullName,
                    avatarURLString: (peerPayload["avatar_url"] as? String) ?? user.avatarURLString,
                    roleId: peerPayload["rol_id"] as? Int
                )
            }
            let dm = CoreDirectMessage(
                id: conversationId,
                empresaId: empresaId,
                dmKey: dmPayload["dm_key"] as? String,
                peer: peer
            )
            if !directMessages.contains(where: { $0.id == dm.id }) {
                directMessages.insert(dm, at: 0)
            }
            return dmChannel(for: dm)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func clearDMUnread(_ dmId: String) {
        guard let index = directMessages.firstIndex(where: { $0.id == dmId }) else { return }
        directMessages[index].unreadCount = 0
        directMessages[index].mentionCount = 0
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
        refreshTask?.cancel()
        refreshTask = nil
        sessionRefreshTask?.cancel()
        sessionRefreshTask = nil
        stopRealtime()
        var next = configuration
        next.clearSession()
        save(configuration: next)
        channels = CorePreviewData.channels
        directMessages = []
        messages = CorePreviewData.messages
        channelPreviews = [:]
        mentionableUsers = []
        channelMembers = [:]
        isLoadingOlderMessages = [:]
        hasOlderMessages = [:]
        selectedChannelId = channels.first?.id
    }

    @discardableResult
    func ensureFreshSession(force: Bool = false) async throws -> CoreAppConfiguration {
        guard configuration.isUsable else {
            throw CoreAuthError.missingRefreshToken
        }
        guard force || configuration.accessTokenExpires() else {
            return configuration
        }
        if let sessionRefreshTask {
            return try await sessionRefreshTask.value
        }

        let originalConfiguration = configuration
        let task = Task {
            let service = try CoreAuthService(configuration: originalConfiguration)
            return try await service.refreshSession()
        }
        sessionRefreshTask = task

        do {
            let refreshedConfiguration = try await task.value
            sessionRefreshTask = nil
            guard configuration.userId == originalConfiguration.userId else {
                return configuration
            }

            let activeChannel = realtimeConversationId == nil ? nil : selectedChannel
            save(configuration: refreshedConfiguration)
            if let activeChannel {
                stopRealtime()
                startRealtime(for: activeChannel)
            }
            return refreshedConfiguration
        } catch {
            sessionRefreshTask = nil
            throw error
        }
    }

    func maintainSession() async {
        while !Task.isCancelled, configuration.isUsable {
            do {
                _ = try await ensureFreshSession()
            } catch {
                lastError = error.localizedDescription
            }
            try? await Task.sleep(for: .seconds(120))
        }
    }

    func toggleFavorite(_ channelId: CoreChannel.ID) {
        if favoriteChannelIds.contains(channelId) {
            favoriteChannelIds.remove(channelId)
        } else {
            favoriteChannelIds.insert(channelId)
        }
    }

    // MARK: - Silenciar canal (local, persiste en UserDefaults)

    static let mutedChannelsDefaultsKey = "zia.mutedChannelIds"

    func isMuted(_ channelId: CoreChannel.ID) -> Bool {
        mutedChannelIds.contains(channelId)
    }

    func toggleMuted(_ channelId: CoreChannel.ID) {
        if mutedChannelIds.contains(channelId) {
            mutedChannelIds.remove(channelId)
        } else {
            mutedChannelIds.insert(channelId)
        }
        UserDefaults.standard.set(Array(mutedChannelIds), forKey: Self.mutedChannelsDefaultsKey)
    }

    /// Marca todo el canal como leído sin abrirlo (upsert en core_message_reads,
    /// igual que la web).
    func markChannelAsRead(_ channel: CoreChannel) async {
        guard configuration.isUsable, let conversationId = channel.conversationId else { return }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try SupabaseCoreClient(configuration: activeConfiguration)
            let lastMessageId = channelPreviews[conversationId]?.id ?? messages[conversationId]?.last?.id
            try await client.markRead(conversationId: conversationId, lastReadMessageId: lastMessageId)
            clearUnread(for: channel.id)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func updateChannelSearch(_ query: String) {
        channelSearchQuery = query
        channelSearchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            channelSearchResults = []
            isSearchingChannels = false
            return
        }

        channelSearchTask = Task {
            isSearchingChannels = true
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            await performChannelSearch(trimmed)
            guard !Task.isCancelled else { return }
            isSearchingChannels = false
        }
    }

    func clearChannelSearch() {
        channelSearchTask?.cancel()
        channelSearchQuery = ""
        channelSearchResults = []
        isSearchingChannels = false
    }

    func refresh() async {
        guard configuration.isUsable else {
            channels = CorePreviewData.channels
            messages = CorePreviewData.messages
            selectedChannelId = selectedChannelId ?? channels.first?.id
            lastError = nil
            return
        }

        if let refreshTask {
            await refreshTask.value
            return
        }

        let task = Task { @MainActor in
            isLoading = true
            lastError = nil
            defer {
                isLoading = false
                refreshTask = nil
            }

            do {
                let activeConfiguration = try await ensureFreshSession()
                let client = try SupabaseCoreClient(configuration: activeConfiguration)
                let fastChannels: [CoreChannel]
                do {
                    fastChannels = try await client.listChannelsFast()
                } catch {
                    fastChannels = try await client.listChannels()
                }
                applyChannels(fastChannels)
                if let loadedDirectMessages = try? await client.listDirectMessages() {
                    directMessages = loadedDirectMessages
                }
                await loadChannelPreviews(using: client)
                if let users = try? await client.listMentionableUsers() {
                    mentionableUsers = users
                }

                Task { @MainActor [weak self] in
                    guard let self, self.configuration.isUsable else { return }
                    do {
                        let enrichedChannels = try await client.listChannels()
                        self.applyChannels(enrichedChannels)
                    } catch {
                        // Fast channel data is already visible; stale counters are preferable to blocking the list.
                    }
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        refreshTask = task
        await task.value
    }

    private func applyChannels(_ loadedChannels: [CoreChannel]) {
        // The fast list RPC (core_list_zia_channels) does not return channel
        // metadata, so the icon (metadata.iconImage) would be lost on the quick
        // render until the enriched fetch arrives. Carry the previously known
        // icon forward so it does not flash or disappear.
        let previousIcons = Dictionary(
            channels.compactMap { channel -> (String, String)? in
                guard let icon = channel.metadata?.iconImage, !icon.isEmpty else { return nil }
                return (channel.id, icon)
            },
            uniquingKeysWith: { first, _ in first }
        )

        let mergedChannels = loadedChannels.map { channel -> CoreChannel in
            guard channel.metadata?.iconImage?.isEmpty != false,
                  let previousIcon = previousIcons[channel.id] else {
                return channel
            }
            var updated = channel
            var metadata = updated.metadata ?? CoreChannelMetadata()
            metadata.iconImage = previousIcon
            updated.metadata = metadata
            return updated
        }

        channels = mergedChannels
        selectedChannelId = selectedChannelId.flatMap(channel(with:))?.id ?? channels.first?.id
        CoreChannelCache.save(mergedChannels, userId: configuration.userId)
    }

    private func loadChannelPreviews(using client: SupabaseCoreClient) async {
        let conversationIds = channels.compactMap(\.conversationId)
        guard !conversationIds.isEmpty else {
            channelPreviews = [:]
            return
        }

        if let previews = try? await client.listChannelPreviews(conversationIds: conversationIds) {
            channelPreviews = previews
        }
    }

    func channelForNotification(channelId: String?, conversationId: String?) async throws -> CoreChannel? {
        if let channel = resolveChannel(channelId: channelId, conversationId: conversationId) {
            return channel
        }

        let activeConfiguration = try await ensureFreshSession()
        let client = try SupabaseCoreClient(configuration: activeConfiguration)
        let loadedChannels: [CoreChannel]
        do {
            loadedChannels = try await client.listChannelsFast()
        } catch {
            loadedChannels = try await client.listChannels()
        }
        applyChannels(loadedChannels)
        return resolveChannel(channelId: channelId, conversationId: conversationId)
    }

    private func resolveChannel(channelId: String?, conversationId: String?) -> CoreChannel? {
        if let channelId, let channel = channel(with: channelId) {
            return channel
        }
        if let conversationId {
            return channels.first { $0.conversationId == conversationId }
                ?? directMessages.first { $0.id == conversationId }?.chatTarget
        }
        return nil
    }

    func open(_ channel: CoreChannel, force: Bool = false) async {
        guard let conversationId = channel.conversationId else { return }
        selectedChannelId = channel.id
        guard configuration.isUsable else { return }
        do {
            _ = try await ensureFreshSession()
        } catch {
            lastError = error.localizedDescription
            return
        }
        await loadChannelMembers(for: channel, force: force)
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
            let pageLimit = force ? max(21, messages[conversationId]?.count ?? 0) : 21
            let loaded = try await client.listMessagePage(
                conversationId: conversationId,
                limit: pageLimit
            )
            messages[conversationId] = loaded
            hasOlderMessages[conversationId] = loaded.count == pageLimit
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

    // MARK: - Recibos de lectura

    /// Carga las marcas de lectura de todos los miembros de la conversación.
    func loadConversationReads(for channel: CoreChannel) async {
        guard let conversationId = channel.conversationId, configuration.isUsable else { return }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try SupabaseCoreClient(configuration: activeConfiguration)
            let reads = try await client.listConversationReads(conversationId: conversationId)
            conversationReads[conversationId] = Dictionary(
                reads.map { ($0.userId, $0.lastReadAt) },
                uniquingKeysWith: max
            )
        } catch {
            // Los recibos de lectura no son críticos; no se reporta el error.
        }
    }

    /// Miembros (excluyendo al autor) que ya leyeron un mensaje: su marca de
    /// lectura es posterior o igual a la fecha del mensaje.
    func readers(of message: CoreMessage, in channel: CoreChannel) -> [CoreUserLite] {
        let reads = conversationReads[message.conversationId] ?? [:]
        return members(for: channel).filter { member in
            guard member.id != message.userId else { return false }
            guard let readAt = reads[member.id] else { return false }
            return readAt >= message.createdAt
        }
    }

    /// Palomitas de un mensaje propio: ✓ enviado, ✓✓ gris leído por algunos,
    /// ✓✓ azul leído por todos los demás miembros.
    func receipt(for message: CoreMessage, in channel: CoreChannel) -> MessageReceipt {
        let recipients = members(for: channel).filter { $0.id != message.userId }
        guard !recipients.isEmpty else { return .sent }
        let readCount = readers(of: message, in: channel).count
        if readCount == 0 { return .sent }
        return readCount < recipients.count ? .readBySome : .readByAll
    }

    func members(for channel: CoreChannel) -> [CoreUserLite] {
        if channel.isDirect,
           let directMessage = directMessages.first(where: { $0.id == channel.id }) {
            return [directMessage.peer]
        }
        return channelMembers[channel.id] ?? []
    }

    private func loadChannelMembers(for channel: CoreChannel, force: Bool) async {
        if channel.isDirect {
            if let directMessage = directMessages.first(where: { $0.id == channel.id }) {
                channelMembers[channel.id] = [directMessage.peer]
            }
            return
        }
        if !force, channelMembers[channel.id] != nil { return }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try SupabaseCoreClient(configuration: activeConfiguration)
            channelMembers[channel.id] = try await client.listChannelMembers(channelId: channel.id)
        } catch {
            channelMembers[channel.id] = []
        }
    }

    func loadOlderMessages(in channel: CoreChannel) async {
        guard configuration.isUsable,
              let conversationId = channel.conversationId,
              hasOlderMessages[conversationId] != false,
              isLoadingMessages[conversationId] != true,
              isLoadingOlderMessages[conversationId] != true,
              let oldestMessage = messages[conversationId]?.first else {
            return
        }

        isLoadingOlderMessages[conversationId] = true
        defer { isLoadingOlderMessages[conversationId] = false }

        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try SupabaseCoreClient(configuration: activeConfiguration)
            let page = try await client.listMessagePage(
                conversationId: conversationId,
                before: oldestMessage.createdAt
            )

            hasOlderMessages[conversationId] = page.count == 21
            mergeMessagePage(page, conversationId: conversationId)

            if let enriched = try? await client.enrichMessages(page) {
                mergeMessagePage(enriched, conversationId: conversationId)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadMessagePins(for channel: CoreChannel) async {
        guard configuration.isUsable, let conversationId = channel.conversationId else { return }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try SupabaseCoreClient(configuration: activeConfiguration)
            messagePins[conversationId] = try await client.listMessagePins(conversationId: conversationId)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func isPinned(_ message: CoreMessage) -> Bool {
        messagePins[message.conversationId]?.contains(where: { $0.messageId == message.id }) == true
    }

    func togglePin(_ message: CoreMessage) async {
        guard configuration.isUsable else { return }
        lastError = nil
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try SupabaseCoreClient(configuration: activeConfiguration)
            if isPinned(message) {
                try await client.unpinMessage(message)
                messagePins[message.conversationId]?.removeAll { $0.messageId == message.id }
            } else {
                let pin = try await client.pinMessage(message)
                var pins = messagePins[message.conversationId] ?? []
                pins.removeAll { $0.messageId == message.id }
                pins.insert(pin, at: 0)
                messagePins[message.conversationId] = pins
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func send(
        _ text: String,
        attachments: [CorePendingAttachment] = [],
        in channel: CoreChannel,
        parentMessageId: String? = nil,
        replyTo quotedMessage: CoreMessage? = nil
    ) async {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !attachments.isEmpty,
              let conversationId = channel.conversationId else {
            return
        }
        guard configuration.isUsable else {
            appendPreviewMessage(content, channel: channel, parentMessageId: parentMessageId)
            return
        }

        // Igual que la web: la cita (metadata.replyTo) solo aplica a mensajes
        // del timeline, no a respuestas dentro de un thread.
        let replyQuote: CoreMessageReplyTo? = (parentMessageId == nil)
            ? quotedMessage.map { quoted in
                CoreMessageReplyTo(
                    messageId: quoted.id,
                    authorId: quoted.userId,
                    authorName: quoted.author?.displayName ?? "Usuario Core",
                    content: String(quoted.content.prefix(240)),
                    createdAt: ISO8601DateFormatter().string(from: quoted.createdAt),
                    hasAttachments: quoted.attachments?.isEmpty == false
                )
            }
            : nil

        var optimisticMessage = makeOptimisticMessage(
            content: content,
            channel: channel,
            conversationId: conversationId,
            parentMessageId: parentMessageId
        )
        if let replyQuote {
            optimisticMessage.metadata = CoreMessageMetadata(replyTo: replyQuote)
        }
        // Thread replies must not be inserted into the main channel timeline.
        let insertedOptimisticMessage = !content.isEmpty && parentMessageId == nil
        if insertedOptimisticMessage {
            upsertMessage(optimisticMessage)
        }

        isSending = true
        lastError = nil
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try SupabaseCoreClient(configuration: activeConfiguration)
            var message: CoreMessage
            if content.hasPrefix("/"), parentMessageId == nil, attachments.isEmpty {
                message = try await sendSlashCommand(content, conversationId: conversationId)
            } else {
                message = try await client.sendMessage(
                    empresaId: channel.empresaId,
                    conversationId: conversationId,
                    // Los DMs no tienen canal: el mensaje va solo a la conversación.
                    channelId: channel.isDirectMessage ? nil : channel.id,
                    parentMessageId: parentMessageId,
                    content: content,
                    attachments: attachments,
                    replyTo: replyQuote
                )
            }
            message.author = optimisticMessage.author
            if insertedOptimisticMessage {
                removeMessage(id: optimisticMessage.id, conversationId: conversationId)
            }
            if let parentMessageId {
                if upsertThreadReply(message, parentMessageId: parentMessageId) {
                    incrementReplyCount(for: parentMessageId, conversationId: conversationId)
                }
            } else {
                upsertMessage(message)
                updateChannelPreview(with: message)
            }
            await realtimeService?.broadcast(message: message)
            Task {
                try? await client.markRead(conversationId: conversationId, lastReadMessageId: message.id)
            }
        } catch {
            if insertedOptimisticMessage {
                removeMessage(id: optimisticMessage.id, conversationId: conversationId)
            }
            lastError = error.localizedDescription
        }
        isSending = false
    }

    func loadThread(for message: CoreMessage, force: Bool = false) async {
        if !force, threadReplies[message.id] != nil { return }
        guard configuration.isUsable else { return }

        isLoadingThread[message.id] = true
        defer { isLoadingThread[message.id] = false }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try SupabaseCoreClient(configuration: activeConfiguration)
            threadReplies[message.id] = try await client.listThreadReplies(
                conversationId: message.conversationId,
                parentMessageId: message.id
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func sendSlashCommand(_ content: String, conversationId: String) async throws -> CoreMessage {
        let response = try await coreAPIRequest(
            path: "/api/core/messages/send",
            method: "POST",
            body: [
                "conversationId": conversationId,
                "content": content,
                "metadata": [:],
                "attachments": []
            ]
        )
        guard let rawMessage = response["message"] as? [String: Any] else {
            throw SupabaseCoreError.emptyResponse
        }
        let data = try JSONSerialization.data(withJSONObject: rawMessage)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) {
                return date
            }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Fecha inválida")
        }
        return try decoder.decode(CoreMessage.self, from: data)
    }

    /// Loads the list of threads (root messages with replies) for a channel.
    func loadChannelThreads(for channel: CoreChannel, force: Bool = false) async {
        guard let conversationId = channel.conversationId else { return }
        if !force, channelThreads[conversationId] != nil { return }
        guard configuration.isUsable else { return }

        isLoadingChannelThreads[conversationId] = true
        defer { isLoadingChannelThreads[conversationId] = false }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try SupabaseCoreClient(configuration: activeConfiguration)
            channelThreads[conversationId] = try await client.listChannelThreads(conversationId: conversationId)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Carga los threads de todos los canales de texto (filtro "Hilos" del index).
    /// Con `force == false` solo consulta los canales que aún no tienen threads
    /// en memoria, así el refresco incremental es barato.
    func loadAllChannelThreads(force: Bool = false) async {
        guard configuration.isUsable else { return }
        let targets = textChannels.filter { channel in
            guard let conversationId = channel.conversationId else { return false }
            return force || channelThreads[conversationId] == nil
        }
        guard !targets.isEmpty else { return }

        isLoadingAllThreads = true
        defer { isLoadingAllThreads = false }
        await withTaskGroup(of: Void.self) { group in
            for channel in targets {
                group.addTask { [weak self] in
                    await self?.loadChannelThreads(for: channel, force: force)
                }
            }
        }
    }

    func sendThreadReply(
        _ text: String,
        attachments: [CorePendingAttachment] = [],
        to root: CoreMessage,
        in channel: CoreChannel
    ) async {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !attachments.isEmpty,
              let conversationId = channel.conversationId else {
            return
        }

        isSending = true
        lastError = nil
        defer { isSending = false }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try SupabaseCoreClient(configuration: activeConfiguration)
            var reply = try await client.sendMessage(
                empresaId: channel.empresaId,
                conversationId: conversationId,
                channelId: channel.isDirect ? nil : channel.id,
                parentMessageId: root.id,
                content: content,
                attachments: attachments
            )
            reply.author = CoreUserLite(
                id: configuration.userId,
                fullName: configuration.displayName.isEmpty ? "You" : configuration.displayName
            )
            if upsertThreadReply(reply, parentMessageId: root.id) {
                incrementReplyCount(for: root.id, conversationId: conversationId)
            }
            await realtimeService?.broadcast(message: reply)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func forward(_ message: CoreMessage, to channel: CoreChannel) async {
        guard configuration.isUsable else { return }
        isSending = true
        lastError = nil
        defer { isSending = false }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try SupabaseCoreClient(configuration: activeConfiguration)
            var forwarded = try await client.forwardMessage(message, to: channel)
            forwarded.author = CoreUserLite(
                id: configuration.userId,
                fullName: configuration.displayName.isEmpty ? "You" : configuration.displayName
            )
            upsertMessage(forwarded)
            updateChannelPreview(with: forwarded)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func createChannel(
        name: String,
        description: String,
        visibility: CoreChannelVisibility,
        channelType: String = "text",
        iconImage: String? = nil,
        theme: CoreChannelTheme? = nil,
        businessUnitId: Int? = nil,
        memberIds: [String] = [],
        adminIds: [String] = []
    ) async {
        guard configuration.isUsable else { return }
        isCreatingChannel = true
        lastError = nil
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try SupabaseCoreClient(configuration: activeConfiguration)
            let trimmedIcon = iconImage?.trimmingCharacters(in: .whitespacesAndNewlines)
            let metadata = CoreChannelMetadata(
                channelType: channelType,
                iconImage: (trimmedIcon?.isEmpty == false) ? trimmedIcon : nil,
                theme: theme,
                businessUnitId: businessUnitId
            )
            let channel = try await client.createChannel(
                name: name,
                description: description,
                visibility: visibility,
                channelType: channelType,
                metadata: metadata
            )
            // Same as the web: after creating, sync the selected members/admins.
            let allMemberIds = Array(Set(memberIds + [configuration.userId])).filter { !$0.isEmpty }
            let allAdminIds = Array(Set(adminIds + [configuration.userId])).filter { !$0.isEmpty }
            if allMemberIds.count > 1 || allAdminIds.count > 1 {
                do {
                    try await client.syncChannelMembers(
                        channelId: channel.id,
                        userIds: allMemberIds,
                        adminIds: allAdminIds
                    )
                } catch {
                    // The channel exists; member sync failure should not hide it.
                    lastError = "Canal creado, pero no se pudieron sincronizar los miembros: \(error.localizedDescription)"
                }
            }
            channels.append(channel)
            channels.sort { $0.slug < $1.slug }
            selectedChannelId = channel.id
        } catch {
            lastError = error.localizedDescription
        }
        isCreatingChannel = false
    }

    /// Actualiza un canal con la misma lógica del modal "Configurar canal" de la
    /// web: update de la fila + merge de metadata + sincronización de miembros.
    /// Devuelve true si todo salió bien.
    @discardableResult
    func updateChannel(
        _ channel: CoreChannel,
        name: String,
        description: String,
        visibility: CoreChannelVisibility,
        iconImage: String?,
        theme: CoreChannelTheme?,
        businessUnitId: Int?,
        memberIds: [String],
        adminIds: [String]
    ) async -> Bool {
        guard configuration.isUsable else { return false }
        isCreatingChannel = true
        lastError = nil
        defer { isCreatingChannel = false }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try SupabaseCoreClient(configuration: activeConfiguration)

            // Partimos de la metadata fresca del servidor (la lista rápida no la
            // trae) para no pisar claves como el token de invitación.
            var metadata = (try? await client.fetchChannelMetadata(channelId: channel.id))
                ?? channel.metadata
                ?? CoreChannelMetadata()
            metadata.theme = theme
            metadata.iconImage = (iconImage?.isEmpty == false) ? iconImage : nil
            metadata.channelType = metadata.channelType ?? (channel.isVoice ? "voice" : "text")
            metadata.businessUnitId = businessUnitId

            try await client.updateChannel(
                channelId: channel.id,
                name: name,
                description: description,
                visibility: visibility,
                metadata: metadata
            )

            let allMemberIds = Array(Set(memberIds + [configuration.userId])).filter { !$0.isEmpty }
            let allAdminIds = Array(Set(adminIds + [configuration.userId])).filter { !$0.isEmpty }
            do {
                try await client.syncChannelMembers(
                    channelId: channel.id,
                    userIds: allMemberIds,
                    adminIds: allAdminIds
                )
            } catch {
                lastError = "Canal actualizado, pero no se pudieron sincronizar los miembros: \(error.localizedDescription)"
            }

            // Refleja el cambio localmente de inmediato.
            if let index = channels.firstIndex(where: { $0.id == channel.id }) {
                var updated = channels[index]
                updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.slug = SupabaseCoreClient.slugifyCoreName(name)
                updated.description = description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : description.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.visibility = visibility
                updated.metadata = metadata
                channels[index] = updated
                channels.sort { $0.slug < $1.slug }
            }
            channelMembers[channel.id] = nil
            return lastError == nil
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Elimina (archiva) un canal igual que la web y limpia el estado local.
    @discardableResult
    func deleteChannel(_ channel: CoreChannel) async -> Bool {
        guard configuration.isUsable else { return false }
        lastError = nil
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try SupabaseCoreClient(configuration: activeConfiguration)
            try await client.archiveChannel(channel)
            channels.removeAll { $0.id == channel.id }
            favoriteChannelIds.remove(channel.id)
            if selectedChannelId == channel.id {
                selectedChannelId = nil
            }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func fetchChannelMetadata(_ channel: CoreChannel) async -> CoreChannelMetadata? {
        guard configuration.isUsable else { return nil }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try SupabaseCoreClient(configuration: activeConfiguration)
            return try await client.fetchChannelMetadata(channelId: channel.id)
        } catch {
            return nil
        }
    }

    /// Busca mensajes dentro de un canal específico (para la búsqueda in-channel).
    func searchMessages(in channel: CoreChannel, keyword: String) async -> [CoreMessage] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard configuration.isUsable, !trimmed.isEmpty else { return [] }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try SupabaseCoreClient(configuration: activeConfiguration)
            return try await client.searchChannelMessages(keyword: trimmed, channelIds: [channel.id])
        } catch {
            return []
        }
    }

    func loadChannelMemberRoles(channelId: String) async -> [CoreChannelMemberRole] {
        guard configuration.isUsable else { return [] }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try SupabaseCoreClient(configuration: activeConfiguration)
            return try await client.listChannelMemberRoles(channelId: channelId)
        } catch {
            return []
        }
    }

    /// Llama un endpoint del backend Next.js (mismo que usa la web) con el
    /// token de la sesión. Devuelve el JSON de respuesta.
    @discardableResult
    func coreAPIRequest(path: String, method: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        let activeConfiguration = try await ensureFreshSession()
        let environment = CoreEnvironment.load()
        guard let baseURL = URL(string: environment.appURL),
              let url = URL(string: path, relativeTo: baseURL) else {
            throw SupabaseCoreError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(activeConfiguration.accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let payload = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (payload["error"] as? String)
                ?? "Error del servidor (\((response as? HTTPURLResponse)?.statusCode ?? 0))"
            throw SupabaseCoreError.attachmentUpload(message)
        }
        return payload
    }

    /// Crea y devuelve el link de invitación del canal usando el mismo endpoint
    /// de la web (/api/core/channels/invite).
    func createChannelInviteLink(_ channel: CoreChannel) async -> String? {
        guard configuration.isUsable else { return nil }
        do {
            let payload = try await coreAPIRequest(
                path: "/api/core/channels/invite",
                method: "POST",
                body: ["action": "create", "channelId": channel.id]
            )
            guard payload["ok"] as? Bool == true, let inviteUrl = payload["inviteUrl"] as? String else {
                lastError = "No se pudo crear el link de invitación."
                return nil
            }
            return inviteUrl
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Edita un mensaje propio (PATCH /api/core/messages/:id, igual que la web).
    @discardableResult
    func editMessage(_ message: CoreMessage, newContent: String) async -> Bool {
        let content = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, configuration.isUsable else { return false }
        lastError = nil
        do {
            try await coreAPIRequest(
                path: "/api/core/messages/\(message.id)",
                method: "PATCH",
                body: ["content": content]
            )
            applyLocalMessageEdit(messageId: message.id, conversationId: message.conversationId, content: content)
            var updatedMessage = message
            updatedMessage.content = content
            updatedMessage.editedAt = Date()
            await realtimeService?.broadcast(message: updatedMessage)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Elimina (soft delete) un mensaje propio (DELETE /api/core/messages/:id).
    @discardableResult
    func deleteMessage(_ message: CoreMessage) async -> Bool {
        guard configuration.isUsable else { return false }
        lastError = nil
        do {
            try await coreAPIRequest(path: "/api/core/messages/\(message.id)", method: "DELETE")
            removeMessage(id: message.id, conversationId: message.conversationId)
            messagePins[message.conversationId]?.removeAll { $0.messageId == message.id }
            for (rootId, replies) in threadReplies where replies.contains(where: { $0.id == message.id }) {
                threadReplies[rootId] = replies.filter { $0.id != message.id }
            }
            var deletedMessage = message
            deletedMessage.deletedAt = Date()
            await realtimeService?.broadcast(message: deletedMessage)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func applyLocalMessageEdit(messageId: String, conversationId: String, content: String) {
        if var list = messages[conversationId],
           let index = list.firstIndex(where: { $0.id == messageId }) {
            list[index].content = content
            list[index].editedAt = Date()
            messages[conversationId] = list
        }
        for (rootId, replies) in threadReplies {
            guard let index = replies.firstIndex(where: { $0.id == messageId }) else { continue }
            var copy = replies
            copy[index].content = content
            copy[index].editedAt = Date()
            threadReplies[rootId] = copy
        }
        if var preview = channelPreviews[conversationId], preview.id == messageId {
            preview.content = content
            channelPreviews[conversationId] = preview
        }
    }

    func loadMentionableUsersIfNeeded() async {
        guard configuration.isUsable, mentionableUsers.isEmpty else { return }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try SupabaseCoreClient(configuration: activeConfiguration)
            mentionableUsers = try await client.listMentionableUsers()
        } catch {
            // Non-fatal: the member picker simply stays empty.
        }
    }

    func loadInternalCompanies() async {
        guard configuration.isUsable else { return }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try SupabaseCoreClient(configuration: activeConfiguration)
            internalCompanies = try await client.listInternalCompanies()
        } catch {
            internalCompanies = []
        }
    }

    func react(to message: CoreMessage, emoji: String) async {
        guard configuration.isUsable else { return }
        lastError = nil
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try SupabaseCoreClient(configuration: activeConfiguration)
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

    private func performChannelSearch(_ keyword: String) async {
        let loweredKeyword = keyword.lowercased()
        let searchableChannels = channels.filter { !$0.isVoice }

        var metadataMatches = Set<CoreChannel.ID>()
        for channel in searchableChannels {
            let haystack = [
                channel.displayName,
                channel.slug,
                channel.description ?? ""
            ]
            .joined(separator: " ")
            .lowercased()

            if haystack.contains(loweredKeyword) {
                metadataMatches.insert(channel.id)
            }
        }

        var messageMatches: [CoreMessage] = []
        if configuration.isUsable {
            let channelIds = searchableChannels.map(\.id)
            let activeConfiguration = try? await ensureFreshSession()
            if let activeConfiguration,
               let client = try? SupabaseCoreClient(configuration: activeConfiguration),
               let matches = try? await client.searchChannelMessages(keyword: keyword, channelIds: channelIds) {
                messageMatches = matches
            }
        } else {
            messageMatches = searchableChannels.flatMap { channel in
                guard let conversationId = channel.conversationId else { return [CoreMessage]() }
                return (messages[conversationId] ?? []).filter {
                    $0.content.lowercased().contains(loweredKeyword)
                }
            }
        }

        var groupedMessages: [CoreChannel.ID: [CoreMessage]] = [:]
        for message in messageMatches {
            if let channelId = message.channelId {
                groupedMessages[channelId, default: []].append(message)
            } else if let channel = searchableChannels.first(where: { $0.conversationId == message.conversationId }) {
                groupedMessages[channel.id, default: []].append(message)
            }
        }

        var hits: [CoreChannelSearchHit] = []
        let candidateIds = metadataMatches.union(groupedMessages.keys)
        for channelId in candidateIds {
            guard let channel = channel(with: channelId) else { continue }
            let channelMessages = groupedMessages[channelId] ?? []
            let messageCount = channelMessages.count
            let metadataMatch = metadataMatches.contains(channelId)
            let incidenceCount = messageCount > 0 ? messageCount : (metadataMatch ? 1 : 0)
            guard incidenceCount > 0 else { continue }

            let previewSnippet: String?
            if let latestMessage = channelMessages.max(by: { $0.createdAt < $1.createdAt }) {
                previewSnippet = CoreChannelSearchHit.snippet(from: latestMessage.content, keyword: keyword)
            } else if metadataMatch {
                previewSnippet = channel.description?.isEmpty == false ? channel.description : channel.displayName
            } else {
                previewSnippet = nil
            }

            hits.append(
                CoreChannelSearchHit(
                    channel: channel,
                    incidenceCount: incidenceCount,
                    previewSnippet: previewSnippet
                )
            )
        }

        channelSearchResults = hits.sorted {
            if $0.incidenceCount != $1.incidenceCount {
                return $0.incidenceCount > $1.incidenceCount
            }
            return $0.channel.displayName.localizedCaseInsensitiveCompare($1.channel.displayName) == .orderedAscending
        }
    }

    private func clearUnread(for channelId: CoreChannel.ID) {
        if let index = channels.firstIndex(where: { $0.id == channelId }) {
            channels[index].unreadCount = 0
            channels[index].mentionCount = 0
        }
        clearDMUnread(channelId)
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

    private func startRealtime(for channel: CoreChannel, force: Bool = false) {
        guard let conversationId = channel.conversationId else { return }
        guard force || realtimeConversationId != conversationId || realtimeService == nil else { return }

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
                    onDelete: { [weak self] message in
                        await self?.handleRealtimeDelete(message)
                    },
                    onReactionChange: { [weak self] reaction, deletedReactionId in
                        await self?.handleRealtimeReaction(reaction, deletedReactionId: deletedReactionId)
                    },
                    onAttachmentChange: { [weak self] attachment, deletedAttachmentId in
                        await self?.handleRealtimeAttachment(
                            attachment,
                            deletedAttachmentId: deletedAttachmentId
                        )
                    },
                    onPinChange: { [weak self] pin, deletedPinId in
                        await self?.handleRealtimePin(pin, deletedPinId: deletedPinId)
                    },
                    onMessageSignal: { [weak self] in
                        await self?.scheduleRealtimeMessageRefresh(conversationId: conversationId)
                    },
                    onError: { [weak self] message in
                        await self?.setRealtimeError(message)
                    },
                    onDisconnect: { [weak self] in
                        await self?.scheduleRealtimeReconnect(for: channel)
                    }
                )
            } catch {
                await MainActor.run {
                    if self.realtimeConversationId == conversationId {
                        self.lastError = error.localizedDescription
                        self.realtimeService = nil
                    }
                }
                self.scheduleRealtimeReconnect(for: channel)
            }
        }
    }

    private func stopRealtime() {
        realtimeReconnectTask?.cancel()
        realtimeReconnectTask = nil
        realtimeMessageRefreshTask?.cancel()
        realtimeMessageRefreshTask = nil
        realtimeConversationId = nil

        guard let realtimeService else { return }
        self.realtimeService = nil
        Task {
            await realtimeService.stop()
        }
    }

    func reconnectRealtimeIfNeeded() {
        guard let conversationId = realtimeConversationId,
              let channel = channels.first(where: { $0.conversationId == conversationId })
                ?? directMessages.first(where: { $0.id == conversationId })?.chatTarget else {
            return
        }
        startRealtime(for: channel, force: true)
    }

    private func scheduleRealtimeReconnect(for channel: CoreChannel) {
        guard realtimeConversationId == channel.conversationId else { return }
        realtimeReconnectTask?.cancel()
        realtimeReconnectTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled,
                  self.realtimeConversationId == channel.conversationId else { return }
            self.startRealtime(for: channel, force: true)
        }
    }

    private func scheduleRealtimeMessageRefresh(conversationId: String) {
        guard realtimeConversationId == conversationId else { return }
        realtimeMessageRefreshTask?.cancel()
        realtimeMessageRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, self.realtimeConversationId == conversationId else { return }
            await self.resyncRealtimeMessages(conversationId: conversationId)
        }
    }

    private func resyncRealtimeMessages(conversationId: String) async {
        guard realtimeConversationId == conversationId,
              let client = try? SupabaseCoreClient(configuration: configuration) else {
            return
        }

        let limit = max(21, messages[conversationId, default: []].count + 5)
        guard let loaded = try? await client.listMessagePage(
            conversationId: conversationId,
            limit: limit
        ) else {
            return
        }

        if let enriched = try? await client.enrichMessages(loaded) {
            mergeMessagePage(enriched, conversationId: conversationId)
        } else {
            mergeMessagePage(loaded, conversationId: conversationId)
        }
        if let latest = loaded.last {
            updateChannelPreview(with: latest)
            clearUnreadForActiveConversation(conversationId)
            try? await client.markRead(
                conversationId: conversationId,
                lastReadMessageId: latest.id
            )
        }
    }

    private func handleRealtimeInsert(_ message: CoreMessage) async {
        guard message.conversationId == realtimeConversationId else { return }
        guard message.deletedAt == nil else { return }

        if let parentMessageId = message.parentMessageId {
            if threadReplies[parentMessageId] != nil,
               let client = try? SupabaseCoreClient(configuration: configuration) {
                let enriched = await client.enrichRealtimeMessage(message)
                if upsertThreadReply(enriched, parentMessageId: parentMessageId) {
                    incrementReplyCount(for: parentMessageId, conversationId: message.conversationId)
                }
            } else {
                // Thread not loaded locally: still refresh counts and the
                // threads overview so unread indicators stay accurate.
                incrementReplyCount(for: parentMessageId, conversationId: message.conversationId)
                bumpThreadSummary(with: message, parentMessageId: parentMessageId)
            }
            return
        }

        if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updateChannelPreview(with: message)
        }
        removeMatchingOptimisticMessage(for: message)
        let isAttachmentOnly = message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !isAttachmentOnly {
            upsertMessage(message)
        }
        clearUnreadForActiveConversation(message.conversationId)

        if let client = try? SupabaseCoreClient(configuration: configuration) {
            try? await client.markRead(conversationId: message.conversationId, lastReadMessageId: message.id)
            let enriched = await client.enrichRealtimeMessage(message)
            if !isAttachmentOnly || enriched.attachments?.isEmpty == false {
                upsertMessage(enriched)
                updateChannelPreview(with: enriched)
            }
        }

        // Poll announcements ("📊 …") need their poll loaded so the voting UI
        // renders instead of plain text.
        if message.content.hasPrefix("📊"),
           polls[message.id] == nil,
           let channel = channels.first(where: { $0.conversationId == message.conversationId }) {
            await loadPolls(for: channel)
        }
    }

    private func handleRealtimeUpdate(_ message: CoreMessage) async {
        guard message.conversationId == realtimeConversationId else { return }

        if message.deletedAt != nil || message.parentMessageId != nil {
            removeMessage(id: message.id, conversationId: message.conversationId)
            return
        }

        upsertMessage(message)
        updateChannelPreview(with: message)
        if let client = try? SupabaseCoreClient(configuration: configuration) {
            let enriched = await client.enrichRealtimeMessage(message)
            upsertMessage(enriched)
            updateChannelPreview(with: enriched)
        }
    }

    private func handleRealtimeDelete(_ message: CoreMessage) {
        guard message.conversationId == realtimeConversationId else { return }
        removeMessage(id: message.id, conversationId: message.conversationId)
        messagePins[message.conversationId]?.removeAll { $0.messageId == message.id }
    }

    private func setRealtimeError(_ message: String) {
        lastError = message
    }

    private func handleRealtimeReaction(_ reaction: CoreReaction?, deletedReactionId: String?) async {
        guard let reaction else { return }

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
            return
        }

        // The reactions stream is company-wide because the table has no
        // conversation_id column. Ignore events for messages outside this chat.
    }

    private func handleRealtimeAttachment(
        _ attachment: CoreAttachment?,
        deletedAttachmentId: String?
    ) async {
        guard let attachment,
              let messageId = attachment.messageId,
              let conversationId = realtimeConversationId,
              let messageIndex = messages[conversationId]?.firstIndex(where: { $0.id == messageId }) else {
            return
        }

        if let deletedAttachmentId {
            messages[conversationId]?[messageIndex].attachments?.removeAll {
                $0.id == deletedAttachmentId
            }
            return
        }

        var attachments = messages[conversationId]?[messageIndex].attachments ?? []
        if let attachmentIndex = attachments.firstIndex(where: { $0.id == attachment.id }) {
            attachments[attachmentIndex] = attachment
        } else {
            attachments.append(attachment)
        }
        messages[conversationId]?[messageIndex].attachments = attachments

        // Storage rows may need a short-lived signed URL. Hydrate only this
        // message after the realtime event, never the full conversation.
        if attachment.resolvedURL == nil,
           let client = try? SupabaseCoreClient(configuration: configuration),
           let message = messages[conversationId]?[messageIndex] {
            let enriched = await client.enrichRealtimeMessage(message)
            upsertMessage(enriched)
        }
    }

    private func handleRealtimePin(_ pin: CoreMessagePin?, deletedPinId: String?) {
        guard let pin, pin.conversationId == realtimeConversationId else { return }
        var pins = messagePins[pin.conversationId] ?? []

        if let deletedPinId {
            pins.removeAll { $0.id == deletedPinId || $0.messageId == pin.messageId }
        } else if let index = pins.firstIndex(where: { $0.id == pin.id || $0.messageId == pin.messageId }) {
            pins[index] = pin
        } else {
            pins.append(pin)
        }

        pins.sort { $0.createdAt > $1.createdAt }
        messagePins[pin.conversationId] = pins
    }

    private func upsertMessage(_ message: CoreMessage) {
        var current = messages[message.conversationId, default: []]
        if let index = current.firstIndex(where: { $0.id == message.id }) {
            var copy = message
            copy.author = message.author ?? current[index].author
            copy.reactions = message.reactions ?? current[index].reactions
            if message.attachments?.isEmpty != false,
               current[index].attachments?.isEmpty == false {
                copy.attachments = current[index].attachments
            }
            copy.parent = message.parent ?? current[index].parent
            current[index] = copy
        } else {
            current.append(message)
        }

        current.sort { $0.createdAt < $1.createdAt }
        messages[message.conversationId] = current
    }

    private func mergeMessagePage(_ page: [CoreMessage], conversationId: String) {
        guard !page.isEmpty else { return }
        var byID = Dictionary(
            uniqueKeysWithValues: messages[conversationId, default: []].map { ($0.id, $0) }
        )

        for message in page {
            if let existing = byID[message.id] {
                var copy = message
                copy.author = message.author ?? existing.author
                copy.reactions = message.reactions ?? existing.reactions
                if message.attachments?.isEmpty != false,
                   existing.attachments?.isEmpty == false {
                    copy.attachments = existing.attachments
                }
                copy.parent = message.parent ?? existing.parent
                byID[message.id] = copy
            } else {
                byID[message.id] = message
            }
        }

        messages[conversationId] = byID.values.sorted { $0.createdAt < $1.createdAt }
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

    private func updateChannelPreview(with message: CoreMessage) {
        guard message.parentMessageId == nil, message.deletedAt == nil else { return }
        if let index = directMessages.firstIndex(where: { $0.id == message.conversationId }) {
            if let currentDate = directMessages[index].lastMessageAt,
               currentDate > message.createdAt {
                return
            }
            directMessages[index].lastMessageUserId = message.userId
            directMessages[index].lastMessageContent = message.content
            directMessages[index].lastMessageAt = message.createdAt
            directMessages.sort { first, second in
                (first.lastMessageAt ?? .distantPast) > (second.lastMessageAt ?? .distantPast)
            }
            return
        }
        if let current = channelPreviews[message.conversationId],
           current.createdAt > message.createdAt {
            return
        }
        channelPreviews[message.conversationId] = message
    }

    private func incrementReplyCount(for messageId: String, conversationId: String) {
        guard let index = messages[conversationId]?.firstIndex(where: { $0.id == messageId }) else { return }
        messages[conversationId]?[index].replyCount = (messages[conversationId]?[index].replyCount ?? 0) + 1
    }

    @discardableResult
    private func upsertThreadReply(_ reply: CoreMessage, parentMessageId: String) -> Bool {
        var replies = threadReplies[parentMessageId, default: []]
        if let index = replies.firstIndex(where: { $0.id == reply.id }) {
            replies[index] = reply
            threadReplies[parentMessageId] = replies
            return false
        }

        replies.append(reply)
        replies.sort { $0.createdAt < $1.createdAt }
        threadReplies[parentMessageId] = replies
        bumpThreadSummary(with: reply, parentMessageId: parentMessageId)
        return true
    }

    /// Keeps the channel threads overview in sync when a new reply arrives
    /// (sent locally or received via realtime).
    private func bumpThreadSummary(with reply: CoreMessage, parentMessageId: String) {
        var summaries = channelThreads[reply.conversationId] ?? []
        if let index = summaries.firstIndex(where: { $0.id == parentMessageId }) {
            summaries[index].replyCount += 1
            if reply.createdAt >= summaries[index].lastReplyAt {
                summaries[index].lastReplyAt = reply.createdAt
                summaries[index].lastReplyUserId = reply.userId
            }
        } else if let root = messages[reply.conversationId]?.first(where: { $0.id == parentMessageId }) {
            summaries.append(
                CoreThreadSummary(
                    root: root,
                    replyCount: max(root.replyCount ?? 0, 1),
                    lastReplyAt: reply.createdAt,
                    lastReplyUserId: reply.userId
                )
            )
        } else {
            return
        }
        summaries.sort { $0.lastReplyAt > $1.lastReplyAt }
        channelThreads[reply.conversationId] = summaries
    }
}

// MARK: - Polls

extension CoreChannelsStore {
    /// Creates a poll, posts an announcement message it's linked to, and shows
    /// the voting UI inline.
    func createPoll(question: String, options: [String], in channel: CoreChannel) async {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanOptions = options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmedQuestion.isEmpty, cleanOptions.count >= 2,
              let conversationId = channel.conversationId else { return }
        guard configuration.isUsable else { return }

        let announcementText = "📊 \(trimmedQuestion)"
        let optimistic = makeOptimisticMessage(
            content: announcementText,
            channel: channel,
            conversationId: conversationId,
            parentMessageId: nil
        )
        upsertMessage(optimistic)
        polls[optimistic.id] = CorePoll(
            id: "local-\(optimistic.id)",
            messageId: optimistic.id,
            question: trimmedQuestion,
            options: cleanOptions.enumerated().map { index, label in
                CorePollOption(id: "local-\(index)", label: label, sortOrder: index, votesCount: 0, votedByMe: false)
            }
        )

        isSending = true
        lastError = nil
        do {
            let config = try await ensureFreshSession()
            let client = try SupabaseCoreClient(configuration: config)
            var message = try await client.sendMessage(
                empresaId: channel.empresaId,
                conversationId: conversationId,
                channelId: channel.id,
                parentMessageId: nil,
                content: announcementText
            )
            message.author = optimistic.author
            _ = try await client.createPoll(
                channelId: channel.id,
                messageId: message.id,
                question: trimmedQuestion,
                options: cleanOptions
            )

            if let staged = polls[optimistic.id] {
                polls[message.id] = CorePoll(
                    id: staged.id,
                    messageId: message.id,
                    question: staged.question,
                    options: staged.options
                )
            }
            polls[optimistic.id] = nil
            removeMessage(id: optimistic.id, conversationId: conversationId)
            upsertMessage(message)
            updateChannelPreview(with: message)
            Task {
                try? await client.markRead(conversationId: conversationId, lastReadMessageId: message.id)
            }
            await loadPolls(for: channel)
        } catch {
            polls[optimistic.id] = nil
            removeMessage(id: optimistic.id, conversationId: conversationId)
            lastError = error.localizedDescription
        }
        isSending = false
    }

    /// Loads the channel's polls and indexes them by their linked message id.
    func loadPolls(for channel: CoreChannel) async {
        guard configuration.isUsable else { return }
        do {
            let config = try await ensureFreshSession()
            let client = try SupabaseCoreClient(configuration: config)
            let loaded = try await client.listPolls(channelId: channel.id)
            for poll in loaded {
                if let messageId = poll.messageId {
                    polls[messageId] = poll
                }
            }
        } catch {
            // Non-fatal: polls simply won't render.
        }
    }

    /// Registers the current user's vote with an optimistic local update.
    func votePoll(_ poll: CorePoll, optionId: String) async {
        guard let messageId = poll.messageId else { return }

        if var current = polls[messageId] {
            for index in current.options.indices {
                let isTarget = current.options[index].id == optionId
                let wasVoted = current.options[index].votedByMe
                if isTarget, !wasVoted {
                    current.options[index].votesCount += 1
                    current.options[index].votedByMe = true
                } else if !isTarget, wasVoted {
                    current.options[index].votesCount = max(0, current.options[index].votesCount - 1)
                    current.options[index].votedByMe = false
                }
            }
            polls[messageId] = current
        }

        guard configuration.isUsable, !poll.id.hasPrefix("local-") else { return }
        do {
            let config = try await ensureFreshSession()
            let client = try SupabaseCoreClient(configuration: config)
            try await client.votePoll(pollId: poll.id, optionId: optionId)
        } catch {
            lastError = error.localizedDescription
        }
    }
}

private enum CoreChannelCache {
    private static let keyPrefix = "zia-chat.channels."

    static func load(userId: String) -> [CoreChannel]? {
        guard !userId.isEmpty,
              let data = UserDefaults.standard.data(forKey: keyPrefix + userId) else {
            return nil
        }
        return try? JSONDecoder().decode([CoreChannel].self, from: data)
    }

    static func save(_ channels: [CoreChannel], userId: String) {
        guard !userId.isEmpty, let data = try? JSONEncoder().encode(channels) else { return }
        UserDefaults.standard.set(data, forKey: keyPrefix + userId)
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
