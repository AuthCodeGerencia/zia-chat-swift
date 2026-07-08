import Foundation
import Combine
import OSLog

@MainActor
final class CoreChannelsStore: ObservableObject {
    private static let realtimeLogger = Logger(subsystem: "authcode.ZiaChat", category: "ConvexRealtime")

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

    private var realtimeResyncTask: Task<Void, Never>?
    private var companyResyncTask: Task<Void, Never>?
    private var convexRealtimeClient: ConvexRealtimeClient?
    private var convexRealtimeKey: String?
    private var realtimeMessagesSubscription: AnyCancellable?
    private var companyChannelsSubscription: AnyCancellable?
    private var companyDirectMessagesSubscription: AnyCancellable?
    private var convexWebSocketSubscription: AnyCancellable?
    private var channelSearchTask: Task<Void, Never>?
    private var realtimeConversationId: String?
    private var refreshTask: Task<Void, Never>?
    private var sessionRefreshTask: Task<CoreAppConfiguration, Error>?
    private var sessionMaintenanceTask: Task<Void, Never>?
    private var realtimeRetryTask: Task<Void, Never>?
    private var pendingRealtimeConversationId: String?
    private var realtimeRetryDelay: TimeInterval = 2
    private var sceneIsActive = true
    private let optimisticMessagePrefix = "local-pending-"

    init(configuration: CoreAppConfiguration) {
        self.configuration = configuration
        if configuration.isUsable,
           let cachedChannels = CoreChannelCache.load(userId: configuration.userId),
           !cachedChannels.isEmpty {
            self.channels = cachedChannels
        }
        if configuration.isUsable,
           let cachedList = CoreChatListCache.load(userId: configuration.userId) {
            self.directMessages = cachedList.directMessages
            self.channelPreviews = cachedList.channelPreviews
        }
        self.selectedChannelId = channels.first?.id
        if configuration.isUsable {
            startSessionMaintenance()
        }
    }

    convenience init() {
        self.init(configuration: CoreConfigurationStore.load())
    }

    func setSceneActive(_ isActive: Bool) {
        sceneIsActive = isActive
        if isActive {
            if isLoading {
                isLoading = false
            }
            if configuration.isUsable {
                startSessionMaintenance()
            }
        } else {
            refreshTask?.cancel()
            refreshTask = nil
            sessionRefreshTask?.cancel()
            sessionRefreshTask = nil
            stopSessionMaintenance()
            channelSearchTask?.cancel()
            channelSearchTask = nil
            realtimeRetryTask?.cancel()
            realtimeRetryTask = nil
            pendingRealtimeConversationId = realtimeConversationId
            stopRealtime()
            stopCompanyRealtime()
            stopConvexRealtimeClient()
        }
    }

    private func canPublishSceneUpdates() -> Bool {
        sceneIsActive && !Task.isCancelled
    }

    private func publishSceneUpdate(_ update: () -> Void) {
        guard canPublishSceneUpdates() else { return }
        update()
    }

    private func publishError(_ message: String) {
        guard canPublishSceneUpdates() else { return }
        lastError = message
    }

    private func setLoadingChannelThreads(_ isLoading: Bool, conversationId: String) {
        guard canPublishSceneUpdates() else { return }
        isLoadingChannelThreads[conversationId] = isLoading
    }

    private func setLoadingAllThreads(_ isLoading: Bool) {
        guard canPublishSceneUpdates() else { return }
        isLoadingAllThreads = isLoading
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
            let client = try ConvexCoreClient(configuration: activeConfiguration)
            applyDirectMessages(try await fetchDirectMessages(using: client))
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Encuentra o crea el DM con otra persona en Convex y devuelve el canal
    /// fantasma listo para abrir.
    func startDirectMessage(with user: CoreUserLite) async -> CoreChannel? {
        guard configuration.isUsable, user.id != configuration.userId else { return nil }
        lastError = nil
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try ConvexCoreClient(configuration: activeConfiguration)
            var dm = try await client.startDirectMessage(peerUserId: user.id)
            if dm.peer.id == user.id, dm.peer.fullName == nil {
                dm.peer = user
            }
            if !directMessages.contains(where: { $0.id == dm.id }) {
                directMessages.insert(dm, at: 0)
                saveChatListCache()
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
        saveChatListCache()
    }

    func save(configuration: CoreAppConfiguration) {
        self.configuration = configuration
        CoreConfigurationStore.save(configuration)
        if configuration.isUsable {
            startSessionMaintenance()
        } else {
            stopSessionMaintenance()
        }
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
            if let client = try? ConvexCoreClient(configuration: result.configuration) {
                try? await client.storeCurrentUser(profile: result.profile)
            }
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
        stopSessionMaintenance()
        realtimeRetryTask?.cancel()
        realtimeRetryTask = nil
        pendingRealtimeConversationId = nil
        realtimeRetryDelay = 2
        stopRealtime()
        stopCompanyRealtime()
        stopConvexRealtimeClient()
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
    func ensureFreshSession(force: Bool = false, restartRealtime: Bool = true) async throws -> CoreAppConfiguration {
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
            guard sceneIsActive else {
                CoreConfigurationStore.save(refreshedConfiguration)
                return refreshedConfiguration
            }

            let activeChannel = realtimeConversationId == nil ? nil : selectedChannel
            save(configuration: refreshedConfiguration)
            if restartRealtime {
                if let activeChannel {
                    stopRealtime()
                    startRealtime(for: activeChannel)
                }
                stopCompanyRealtime()
                startCompanyRealtime()
            }
            startSessionMaintenance()
            return refreshedConfiguration
        } catch {
            sessionRefreshTask = nil
            throw error
        }
    }

    func startSessionMaintenance() {
        guard configuration.isUsable, sessionMaintenanceTask == nil else { return }
        sessionMaintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await MainActor.run {
                    self.configuration.accessTokenRefreshDelay()
                }
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.sessionMaintenanceTask = nil
                }
                do {
                    _ = try await self.ensureFreshSession(force: true)
                } catch {
                    await MainActor.run {
                        self.lastError = error.localizedDescription
                        self.startSessionMaintenance(after: 30)
                    }
                }
                return
            }
        }
    }

    private func startSessionMaintenance(after delay: TimeInterval) {
        guard configuration.isUsable, sessionMaintenanceTask == nil else { return }
        sessionMaintenanceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.sessionMaintenanceTask = nil
                self?.startSessionMaintenance()
            }
        }
    }

    private func stopSessionMaintenance() {
        sessionMaintenanceTask?.cancel()
        sessionMaintenanceTask = nil
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

    /// Marca todo el canal como leído sin abrirlo en Convex.
    func markChannelAsRead(_ channel: CoreChannel) async {
        guard configuration.isUsable, let conversationId = channel.conversationId else { return }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try ConvexCoreClient(configuration: activeConfiguration)
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
            let shouldPublishLoading = sceneIsActive
            if shouldPublishLoading {
                isLoading = true
                lastError = nil
            }
            defer {
                if sceneIsActive {
                    isLoading = false
                }
                refreshTask = nil
            }

            do {
                let activeConfiguration = try await ensureFreshSession()
                let client = try ConvexCoreClient(configuration: activeConfiguration)
                let fastChannels: [CoreChannel]
                do {
                    fastChannels = try await client.listChannelsFast()
                } catch {
                    fastChannels = try await client.listChannels()
                }
                guard sceneIsActive, !Task.isCancelled else { return }
                applyChannels(fastChannels)
                if let loadedDirectMessages = try? await fetchDirectMessages(using: client) {
                    guard sceneIsActive, !Task.isCancelled else { return }
                    applyDirectMessages(loadedDirectMessages)
                }
                if let users = try? await client.listMentionableUsers() {
                    guard sceneIsActive, !Task.isCancelled else { return }
                    mentionableUsers = users
                }
                startCompanyRealtime()

                Task { @MainActor [weak self] in
                    guard let self, self.configuration.isUsable, self.sceneIsActive else { return }
                    do {
                        let enrichedChannels = try await client.listChannels()
                        guard self.sceneIsActive, !Task.isCancelled else { return }
                        self.applyChannels(enrichedChannels)
                    } catch {
                        // Fast channel data is already visible; stale counters are preferable to blocking the list.
                    }
                }
            } catch {
                if sceneIsActive {
                    lastError = error.localizedDescription
                }
            }
        }
        refreshTask = task
        await task.value
    }

    private func applyChannels(_ loadedChannels: [CoreChannel]) {
        // Carry the previously known icon forward so it does not flash or
        // disappear during a refresh.
        let previousChannels = Dictionary(
            uniqueKeysWithValues: channels.map { ($0.id, $0) }
        )
        let previousIcons = Dictionary(
            channels.compactMap { channel -> (String, String)? in
                guard let icon = channel.metadata?.iconImage, !icon.isEmpty else { return nil }
                return (channel.id, icon)
            },
            uniquingKeysWith: { first, _ in first }
        )

        let mergedChannels = loadedChannels.map { channel -> CoreChannel in
            var updated = channel
            if let previous = previousChannels[channel.id] {
                updated.unreadCount = max(updated.unreadCount, previous.unreadCount)
            }
            if updated.metadata?.iconImage?.isEmpty != false,
               let previousIcon = previousIcons[channel.id] {
                var metadata = updated.metadata ?? CoreChannelMetadata()
                metadata.iconImage = previousIcon
                updated.metadata = metadata
            }
            return updated
        }

        channels = mergedChannels
        mergeChannelPreviews(from: mergedChannels)
        selectedChannelId = selectedChannelId.flatMap(channel(with:))?.id ?? channels.first?.id
        CoreChannelCache.save(mergedChannels, userId: configuration.userId)
    }

    private func mergeChannelPreviews(from loadedChannels: [CoreChannel]) {
        var next = channelPreviews
        for channel in loadedChannels {
            guard
                let conversationId = channel.conversationId,
                let lastMessageId = channel.lastMessageId,
                let lastMessageAt = channel.lastMessageAt
            else {
                continue
            }
            let incoming = CoreMessage(
                id: lastMessageId,
                empresaId: channel.empresaId,
                conversationId: conversationId,
                channelId: channel.id,
                parentMessageId: nil,
                userId: channel.lastMessageUserId ?? "",
                content: channel.lastMessageContent ?? "",
                createdAt: lastMessageAt,
                author: channel.lastMessageAuthor
            )
            if let current = next[conversationId], current.createdAt > incoming.createdAt {
                continue
            }
            next[conversationId] = incoming
        }
        channelPreviews = next
        saveChatListCache()
    }

    private func applyDirectMessages(_ loaded: [CoreDirectMessage]) {
        let cachedByID = Dictionary(
            uniqueKeysWithValues: directMessages.map { ($0.id, $0) }
        )
        directMessages = loaded.map { incoming in
            guard let cached = cachedByID[incoming.id] else {
                return incoming
            }
            var merged = incoming
            merged.unreadCount = max(incoming.unreadCount, cached.unreadCount)
            if (cached.lastMessageAt ?? .distantPast) > (incoming.lastMessageAt ?? .distantPast) {
                merged.lastMessageContent = cached.lastMessageContent
                merged.lastMessageAt = cached.lastMessageAt
                merged.lastMessageUserId = cached.lastMessageUserId
            }
            return merged
        }
        .sorted {
            ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast)
        }
        saveChatListCache()
    }

    private func fetchDirectMessages(using client: ConvexCoreClient) async throws -> [CoreDirectMessage] {
        try await client.listDirectMessages()
    }

    private func decodeDirectMessageAPI(_ raw: [String: Any]) -> CoreDirectMessage? {
        guard let id = raw["id"] as? String,
              let empresaId = (raw["empresa_id"] as? NSNumber)?.intValue,
              let peer = raw["peer"] as? [String: Any],
              let peerId = peer["id"] as? String else {
            return nil
        }

        let lastMessage = raw["last_message"] as? [String: Any]
        return CoreDirectMessage(
            id: id,
            empresaId: empresaId,
            dmKey: raw["dm_key"] as? String,
            peer: CoreUserLite(
                id: peerId,
                fullName: peer["full_name"] as? String,
                avatarURLString: peer["avatar_url"] as? String,
                roleId: (peer["rol_id"] as? NSNumber)?.intValue
            ),
            unreadCount: (raw["unread_count"] as? NSNumber)?.intValue ?? 0,
            mentionCount: (raw["mention_count"] as? NSNumber)?.intValue ?? 0,
            lastMessageContent: lastMessage?["content"] as? String,
            lastMessageAt: (lastMessage?["created_at"] as? String).flatMap(Self.parseAPIDate),
            lastMessageUserId: lastMessage?["user_id"] as? String
        )
    }

    private nonisolated static func parseAPIDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func saveChatListCache() {
        CoreChatListCache.save(
            directMessages: directMessages,
            channelPreviews: channelPreviews,
            userId: configuration.userId
        )
    }

    func channelForNotification(channelId: String?, conversationId: String?) async throws -> CoreChannel? {
        if let channel = resolveChannel(channelId: channelId, conversationId: conversationId) {
            return channel
        }

        let activeConfiguration = try await ensureFreshSession(restartRealtime: false)
        let client = try ConvexCoreClient(configuration: activeConfiguration)
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
            let lastReadMessageId = messages[conversationId]?.last?.id
            Task {
                if let client = try? ConvexCoreClient(configuration: configuration) {
                    try? await client.markRead(conversationId: conversationId, lastReadMessageId: lastReadMessageId)
                }
            }
            clearUnread(for: channel.id)
            Task { [weak self] in
                await self?.resyncRealtimeMessages(conversationId: conversationId)
            }
            return
        }

        isLoadingMessages[conversationId] = true
        lastError = nil
        do {
            let client = try ConvexCoreClient(configuration: configuration)
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
            let client = try ConvexCoreClient(configuration: activeConfiguration)
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
            let client = try ConvexCoreClient(configuration: activeConfiguration)
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
            let client = try ConvexCoreClient(configuration: activeConfiguration)
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
            let client = try ConvexCoreClient(configuration: activeConfiguration)
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
            let client = try ConvexCoreClient(configuration: activeConfiguration)
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

        let isDiceCommand = content.range(
            of: #"^/dado(?:\s|$)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil && parentMessageId == nil && attachments.isEmpty
        let diceResult = isDiceCommand ? Int.random(in: 1...6) : nil
        let diceXp = (diceResult ?? 0) * 10
        let diceMultiplierUntil = diceResult == 6
            ? ISO8601DateFormatter().string(from: Date().addingTimeInterval(30 * 60))
            : nil
        let diceFlavor = diceResult == 1
            ? "Mala suerte"
            : diceResult == 6
                ? "XP x2 por 30 minutos activo"
                : "Buen tiro"
        var optimisticMessage = makeOptimisticMessage(
            content: diceResult.map { "🎲 Dado Core: \($0) (+\(diceXp) XP)" } ?? content,
            channel: channel,
            conversationId: conversationId,
            parentMessageId: parentMessageId
        )
        if let diceResult {
            optimisticMessage.metadata = CoreMessageMetadata(
                kind: "command_card",
                cardId: optimisticMessage.id,
                command: "dado",
                status: "finished",
                payload: [
                    "result": .number(Double(diceResult)),
                    "xp": .number(Double(diceXp)),
                    "multiplierUntil": diceMultiplierUntil.map { .string($0) } ?? .string(""),
                    "flavor": .string(diceFlavor),
                ],
                initiatedBy: configuration.userId
            )
        }
        if let replyQuote, !isDiceCommand {
            optimisticMessage.metadata = CoreMessageMetadata(replyTo: replyQuote)
        }
        // Thread replies must not be inserted into the main channel timeline.
        let insertedOptimisticMessage = (!content.isEmpty || isDiceCommand) && parentMessageId == nil
        if insertedOptimisticMessage {
            upsertMessage(optimisticMessage)
        }

        isSending = true
        lastError = nil
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try ConvexCoreClient(configuration: activeConfiguration)
            var message = try await client.sendMessage(
                empresaId: channel.empresaId,
                conversationId: conversationId,
                // Los DMs no tienen canal: el mensaje va solo a la conversación.
                channelId: channel.isDirectMessage ? nil : channel.id,
                parentMessageId: parentMessageId,
                content: diceResult.map { "🎲 Dado Core: \($0) (+\(diceXp) XP)" } ?? content,
                attachments: attachments,
                replyTo: replyQuote,
                metadata: optimisticMessage.metadata
            )
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
            let client = try ConvexCoreClient(configuration: activeConfiguration)
            threadReplies[message.id] = try await client.listThreadReplies(
                conversationId: message.conversationId,
                parentMessageId: message.id
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Loads the list of threads (root messages with replies) for a channel.
    func loadChannelThreads(for channel: CoreChannel, force: Bool = false) async {
        guard let conversationId = channel.conversationId else { return }
        if !force, channelThreads[conversationId] != nil { return }
        guard configuration.isUsable, canPublishSceneUpdates() else { return }

        setLoadingChannelThreads(true, conversationId: conversationId)
        defer { setLoadingChannelThreads(false, conversationId: conversationId) }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try ConvexCoreClient(configuration: activeConfiguration)
            let loadedThreads = try await client.listChannelThreads(conversationId: conversationId)
            publishSceneUpdate {
                channelThreads[conversationId] = loadedThreads
            }
        } catch {
            publishError(error.localizedDescription)
        }
    }

    /// Carga los threads de todos los canales de texto (filtro "Hilos" del index).
    /// Con `force == false` solo consulta los canales que aún no tienen threads
    /// en memoria, así el refresco incremental es barato.
    func loadAllChannelThreads(force: Bool = false) async {
        guard configuration.isUsable, canPublishSceneUpdates() else { return }
        let targets = textChannels.filter { channel in
            guard let conversationId = channel.conversationId else { return false }
            return force || channelThreads[conversationId] == nil
        }
        guard !targets.isEmpty else { return }

        setLoadingAllThreads(true)
        defer { setLoadingAllThreads(false) }
        for channel in targets {
            guard canPublishSceneUpdates() else { return }
            await loadChannelThreads(for: channel, force: force)
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
            let client = try ConvexCoreClient(configuration: activeConfiguration)
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
            let client = try ConvexCoreClient(configuration: activeConfiguration)
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
            let client = try ConvexCoreClient(configuration: activeConfiguration)
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
            let client = try ConvexCoreClient(configuration: activeConfiguration)

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
                updated.slug = ConvexCoreClient.slugifyCoreName(name)
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
            let client = try ConvexCoreClient(configuration: activeConfiguration)
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
            let client = try ConvexCoreClient(configuration: activeConfiguration)
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
            let client = try ConvexCoreClient(configuration: activeConfiguration)
            return try await client.searchChannelMessages(keyword: trimmed, channelIds: [channel.id])
        } catch {
            return []
        }
    }

    func loadChannelMemberRoles(channelId: String) async -> [CoreChannelMemberRole] {
        guard configuration.isUsable else { return [] }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try ConvexCoreClient(configuration: activeConfiguration)
            return try await client.listChannelMemberRoles(channelId: channelId)
        } catch {
            return []
        }
    }

    /// Crea y devuelve el link de invitación del canal usando Convex.
    func createChannelInviteLink(_ channel: CoreChannel) async -> String? {
        guard configuration.isUsable else { return nil }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try ConvexCoreClient(configuration: activeConfiguration)
            let token = try await client.createChannelInviteToken(channelId: channel.id)
            let baseURL = CoreEnvironment.load().appURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return "\(baseURL)/dashboard/core?invite=\(token)"
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Edita un mensaje propio en Convex.
    @discardableResult
    func editMessage(_ message: CoreMessage, newContent: String) async -> Bool {
        let content = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, configuration.isUsable else { return false }
        lastError = nil
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try ConvexCoreClient(configuration: activeConfiguration)
            _ = try await client.updateMessage(messageId: message.id, content: content)
            applyLocalMessageEdit(messageId: message.id, conversationId: message.conversationId, content: content)
            var updatedMessage = message
            updatedMessage.content = content
            updatedMessage.editedAt = Date()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Elimina (soft delete) un mensaje propio en Convex.
    @discardableResult
    func deleteMessage(_ message: CoreMessage) async -> Bool {
        guard configuration.isUsable else { return false }
        lastError = nil
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try ConvexCoreClient(configuration: activeConfiguration)
            _ = try await client.hideMessage(message.id)
            removeMessage(id: message.id, conversationId: message.conversationId)
            messagePins[message.conversationId]?.removeAll { $0.messageId == message.id }
            for (rootId, replies) in threadReplies where replies.contains(where: { $0.id == message.id }) {
                threadReplies[rootId] = replies.filter { $0.id != message.id }
            }
            var deletedMessage = message
            deletedMessage.deletedAt = Date()
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
            let client = try ConvexCoreClient(configuration: activeConfiguration)
            mentionableUsers = try await client.listMentionableUsers()
        } catch {
            // Non-fatal: the member picker simply stays empty.
        }
    }

    func loadInternalCompanies() async {
        guard configuration.isUsable else { return }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try ConvexCoreClient(configuration: activeConfiguration)
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
            let client = try ConvexCoreClient(configuration: activeConfiguration)
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
               let client = try? ConvexCoreClient(configuration: activeConfiguration),
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
        guard sceneIsActive else { return }
        guard let conversationId = channel.conversationId else { return }
        guard force || realtimeConversationId != conversationId else { return }

        stopRealtime()
        realtimeConversationId = conversationId
        realtimeResyncTask = Task { [weak self] in
            guard let self else { return }
            do {
                Self.realtimeLogger.info("Starting message subscription conversation=\(conversationId, privacy: .public)")
                let service = try await self.ensureConvexRealtimeClient()
                let limit = max(21, self.messages[conversationId, default: []].count + 5)
                self.realtimeMessagesSubscription = service
                    .subscribeMessages(conversationId: conversationId, limit: limit)
                    .sink(
                        receiveCompletion: { [weak self] completion in
                            guard case .failure = completion else { return }
                            Task { @MainActor in
                                guard let self,
                                      self.sceneIsActive,
                                      self.realtimeConversationId == conversationId else { return }
                                Self.realtimeLogger.error("Message subscription failed conversation=\(conversationId, privacy: .public)")
                                self.lastError = "Convex message subscription failed"
                                self.scheduleRealtimeReconnect(conversationId: conversationId)
                            }
                        },
                        receiveValue: { [weak self] page in
                            Task { @MainActor in
                                guard let self,
                                      self.sceneIsActive,
                                      self.realtimeConversationId == conversationId else { return }
                                self.resetRealtimeRetry()
                                Self.realtimeLogger.info("Message subscription value conversation=\(conversationId, privacy: .public) count=\(page.messages.count, privacy: .public)")
                                let loaded = page.messages.map(\.coreMessage)
                                self.hasOlderMessages[conversationId] = page.hasMore
                                self.mergeMessagePage(loaded, conversationId: conversationId)
                                if let latest = loaded.last {
                                    self.updateChannelPreview(with: latest)
                                    self.clearUnreadForActiveConversation(conversationId)
                                    Task { [configuration = self.configuration] in
                                        if let client = try? ConvexCoreClient(configuration: configuration) {
                                            try? await client.markRead(
                                                conversationId: conversationId,
                                                lastReadMessageId: latest.id
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    )
            } catch {
                Self.realtimeLogger.error("Message subscription setup failed: \(error.localizedDescription, privacy: .public)")
                self.publishError(error.localizedDescription)
                if self.sceneIsActive {
                    self.scheduleRealtimeReconnect(conversationId: conversationId)
                }
            }
        }
    }

    private func stopRealtime() {
        realtimeMessagesSubscription?.cancel()
        realtimeMessagesSubscription = nil
        realtimeConversationId = nil
        realtimeResyncTask?.cancel()
        realtimeResyncTask = nil
    }

    func reconnectRealtimeIfNeeded() async {
        guard sceneIsActive else { return }
        startCompanyRealtime(force: true)
        let conversationId = realtimeConversationId ?? pendingRealtimeConversationId
        pendingRealtimeConversationId = nil
        guard let conversationId,
              let channel = channels.first(where: { $0.conversationId == conversationId })
                ?? directMessages.first(where: { $0.id == conversationId })?.chatTarget else {
            return
        }
        startRealtime(for: channel, force: true)
    }

    private func startCompanyRealtime(force: Bool = false) {
        guard sceneIsActive, configuration.isUsable, let empresaId = configuration.empresaId else { return }
        guard force || companyResyncTask == nil else { return }

        stopCompanyRealtime()
        companyResyncTask = Task { [weak self] in
            guard let self, self.configuration.empresaId == empresaId else { return }
            do {
                Self.realtimeLogger.info("Starting company subscriptions empresa=\(empresaId, privacy: .public)")
                let service = try await self.ensureConvexRealtimeClient()
                let displayName = self.configuration.displayName
                self.companyChannelsSubscription = service
                    .subscribeChannels(empresaId: empresaId, displayName: displayName)
                    .sink(
                        receiveCompletion: { [weak self] completion in
                            guard case .failure = completion else { return }
                            Task { @MainActor in
                                guard let self, self.sceneIsActive else { return }
                                Self.realtimeLogger.error("Channels subscription failed empresa=\(empresaId, privacy: .public)")
                                self.lastError = "Convex channels subscription failed"
                                self.scheduleRealtimeReconnect()
                            }
                        },
                        receiveValue: { [weak self] rows in
                            Task { @MainActor in
                                guard let self, self.sceneIsActive else { return }
                                self.resetRealtimeRetry(onlyIfNoPendingConversation: true)
                                Self.realtimeLogger.info("Channels subscription value empresa=\(empresaId, privacy: .public) count=\(rows.count, privacy: .public)")
                                self.applyChannels(rows.map(\.coreChannel))
                            }
                        }
                    )
                self.companyDirectMessagesSubscription = service
                    .subscribeDirectMessages(empresaId: empresaId, displayName: displayName)
                    .sink(
                        receiveCompletion: { [weak self] completion in
                            guard case .failure = completion else { return }
                            Task { @MainActor in
                                guard let self, self.sceneIsActive else { return }
                                Self.realtimeLogger.error("DM subscription failed empresa=\(empresaId, privacy: .public)")
                                self.lastError = "Convex direct messages subscription failed"
                                self.scheduleRealtimeReconnect()
                            }
                        },
                        receiveValue: { [weak self] rows in
                            Task { @MainActor in
                                guard let self, self.sceneIsActive else { return }
                                self.resetRealtimeRetry(onlyIfNoPendingConversation: true)
                                Self.realtimeLogger.info("DM subscription value empresa=\(empresaId, privacy: .public) count=\(rows.count, privacy: .public)")
                                self.applyDirectMessages(rows.map(\.coreDirectMessage))
                            }
                        }
                    )
            } catch {
                Self.realtimeLogger.error("Company subscription setup failed: \(error.localizedDescription, privacy: .public)")
                self.publishError(error.localizedDescription)
                if self.sceneIsActive {
                    self.scheduleRealtimeReconnect()
                }
            }
        }
    }

    private func stopCompanyRealtime() {
        companyChannelsSubscription?.cancel()
        companyChannelsSubscription = nil
        companyDirectMessagesSubscription?.cancel()
        companyDirectMessagesSubscription = nil
        companyResyncTask?.cancel()
        companyResyncTask = nil
    }

    private func stopConvexRealtimeClient() {
        convexWebSocketSubscription?.cancel()
        convexWebSocketSubscription = nil
        convexRealtimeClient = nil
        convexRealtimeKey = nil
    }

    private func scheduleRealtimeReconnect(conversationId: String? = nil) {
        guard sceneIsActive, configuration.isUsable else { return }
        pendingRealtimeConversationId = conversationId ?? pendingRealtimeConversationId
        guard realtimeRetryTask == nil else { return }
        let delay = realtimeRetryDelay
        realtimeRetryDelay = min(realtimeRetryDelay * 2, 30)
        realtimeRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.performScheduledRealtimeReconnect()
        }
    }

    private func performScheduledRealtimeReconnect() async {
        realtimeRetryTask = nil
        let conversationId = pendingRealtimeConversationId
        pendingRealtimeConversationId = nil
        guard sceneIsActive, configuration.isUsable else { return }
        do {
            _ = try await ensureFreshSession()
        } catch {
            publishError(error.localizedDescription)
            scheduleRealtimeReconnect(conversationId: conversationId)
            return
        }

        startCompanyRealtime(force: true)
        guard let conversationId,
              realtimeConversationId == conversationId,
              let channel = channels.first(where: { $0.conversationId == conversationId })
                ?? directMessages.first(where: { $0.id == conversationId })?.chatTarget else {
            return
        }
        startRealtime(for: channel, force: true)
    }

    private func resetRealtimeRetry(onlyIfNoPendingConversation: Bool = false) {
        if onlyIfNoPendingConversation, pendingRealtimeConversationId != nil {
            realtimeRetryDelay = 2
            return
        }
        realtimeRetryTask?.cancel()
        realtimeRetryTask = nil
        pendingRealtimeConversationId = nil
        realtimeRetryDelay = 2
    }

    private func ensureConvexRealtimeClient() async throws -> ConvexRealtimeClient {
        let activeConfiguration = try await ensureFreshSession(restartRealtime: false)
        let realtimeKey = "\(activeConfiguration.convexURL)|\(activeConfiguration.accessToken)"
        if let convexRealtimeClient, convexRealtimeKey == realtimeKey {
            Self.realtimeLogger.info("Reusing Convex realtime client")
            return convexRealtimeClient
        }
        Self.realtimeLogger.info("Creating Convex realtime client")
        let client = try await Task.detached(priority: .utility) {
            let service = try ConvexRealtimeClient(configuration: activeConfiguration)
            await service.authenticate()
            return service
        }.value
        Self.realtimeLogger.info("Convex realtime client ready")
        convexWebSocketSubscription?.cancel()
        convexWebSocketSubscription = client
            .watchWebSocketState()
            .sink { state in
                Self.realtimeLogger.info("Convex websocket state=\(String(describing: state), privacy: .public)")
            }
        convexRealtimeClient = client
        convexRealtimeKey = realtimeKey
        return client
    }

    private func handleCompanyRealtimeMessage(_ message: CoreMessage) {
        guard message.empresaId == configuration.empresaId,
              message.parentMessageId == nil,
              message.deletedAt == nil,
              sceneIsActive else {
            return
        }

        updateChannelPreview(with: message)
        guard message.conversationId != realtimeConversationId,
              message.userId != configuration.userId else {
            return
        }

        if let channelIndex = channels.firstIndex(where: {
            $0.conversationId == message.conversationId
        }) {
            channels[channelIndex].unreadCount += 1
        } else if let directIndex = directMessages.firstIndex(where: {
            $0.id == message.conversationId
        }) {
            directMessages[directIndex].unreadCount += 1
        }
    }

    private func refreshChatListActivity() async {
        guard sceneIsActive else { return }
        guard let client = try? ConvexCoreClient(configuration: configuration) else { return }
        async let loadedChannels = try? client.listChannelsFast()
        async let loadedDirectMessages = try? fetchDirectMessages(using: client)

        if let channels = await loadedChannels {
            guard sceneIsActive, !Task.isCancelled else { return }
            applyChannels(channels)
        }
        if let directMessages = await loadedDirectMessages {
            guard sceneIsActive, !Task.isCancelled else { return }
            applyDirectMessages(directMessages)
        }
    }

    private func resyncRealtimeMessages(conversationId: String) async {
        guard realtimeConversationId == conversationId,
              let client = try? ConvexCoreClient(configuration: configuration) else {
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
               let client = try? ConvexCoreClient(configuration: configuration) {
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
            && message.metadata?.isCommandCard != true
        if !isAttachmentOnly {
            upsertMessage(message)
        }
        clearUnreadForActiveConversation(message.conversationId)

        if let client = try? ConvexCoreClient(configuration: configuration) {
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
        if let client = try? ConvexCoreClient(configuration: configuration) {
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
           let client = try? ConvexCoreClient(configuration: configuration),
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
            saveChatListCache()
            return
        }
        if let current = channelPreviews[message.conversationId],
           current.createdAt > message.createdAt {
            return
        }
        channelPreviews[message.conversationId] = message
        saveChatListCache()
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
            let client = try ConvexCoreClient(configuration: config)
            let cardId = UUID().uuidString
            let metadata = CoreMessageMetadata(
                kind: "command_card",
                cardId: cardId,
                command: "poll",
                status: "active",
                payload: [
                    "question": .string(trimmedQuestion),
                    "options": .array(cleanOptions.map { .string($0) }),
                    "votes": .object([:]),
                    "totalVotes": .number(0),
                ],
                initiatedBy: configuration.userId
            )
            var message = try await client.sendMessage(
                empresaId: channel.empresaId,
                conversationId: conversationId,
                channelId: channel.id,
                parentMessageId: nil,
                content: announcementText,
                metadata: metadata
            )
            message.author = optimistic.author

            if let poll = corePoll(from: message) {
                polls[message.id] = poll
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
        guard let conversationId = channel.conversationId else { return }
        for message in messages[conversationId] ?? [] {
            guard let poll = corePoll(from: message), let messageId = poll.messageId else { continue }
            polls[messageId] = poll
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

        guard configuration.isUsable,
              !poll.id.hasPrefix("local-"),
              let messageId = poll.messageId,
              var message = message(withId: messageId),
              var metadata = message.metadata,
              metadata.kind == "command_card",
              metadata.command == "poll",
              var payload = metadata.payload else { return }
        do {
            let config = try await ensureFreshSession()
            let client = try ConvexCoreClient(configuration: config)
            let selectedIndex = poll.options.first(where: { $0.id == optionId })?.sortOrder ?? -1
            guard selectedIndex >= 0 else { return }
            var votes = payload["votes"]?.objectValue ?? [:]
            for key in votes.keys {
                let current = votes[key]?.arrayValue ?? []
                votes[key] = .array(current.filter { $0.stringValue != configuration.userId })
            }
            var selectedVotes = votes[String(selectedIndex)]?.arrayValue ?? []
            if !selectedVotes.contains(where: { $0.stringValue == configuration.userId }) {
                selectedVotes.append(.string(configuration.userId))
            }
            votes[String(selectedIndex)] = .array(selectedVotes)
            payload["votes"] = .object(votes)
            payload["totalVotes"] = .number(Double(votes.values.reduce(0) { count, value in
                count + (value.arrayValue?.count ?? 0)
            }))
            metadata.payload = payload
            message.metadata = metadata
            let patched = try await client.patchMessageMetadata(
                messageId: message.id,
                metadata: metadata,
                content: message.content,
                action: "poll_vote"
            )
            upsertMessage(patched)
            if let updatedPoll = corePoll(from: patched) {
                polls[message.id] = updatedPoll
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func message(withId messageId: String) -> CoreMessage? {
        for conversationMessages in messages.values {
            if let message = conversationMessages.first(where: { $0.id == messageId }) {
                return message
            }
        }
        for replies in threadReplies.values {
            if let message = replies.first(where: { $0.id == messageId }) {
                return message
            }
        }
        return nil
    }

    private func corePoll(from message: CoreMessage) -> CorePoll? {
        guard let metadata = message.metadata,
              metadata.kind == "command_card",
              metadata.command == "poll",
              metadata.status != "error",
              let payload = metadata.payload else {
            return nil
        }
        let question = payload["question"]?.stringValue ?? "Encuesta"
        let optionLabels = payload["options"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard !optionLabels.isEmpty else { return nil }
        let votes = payload["votes"]?.objectValue ?? [:]
        let pollId = metadata.cardId ?? message.id
        return CorePoll(
            id: pollId,
            messageId: message.id,
            question: question,
            options: optionLabels.enumerated().map { index, label in
                let votedBy = votes[String(index)]?.arrayValue?.compactMap(\.stringValue) ?? []
                return CorePollOption(
                    id: "\(message.id):\(index)",
                    label: label,
                    sortOrder: index,
                    votesCount: votedBy.count,
                    votedByMe: votedBy.contains(configuration.userId)
                )
            }
        )
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

private struct CoreChatListCachePayload: Codable {
    var directMessages: [CoreDirectMessage]
    var channelPreviews: [String: CoreMessage]
}

private enum CoreChatListCache {
    private static let keyPrefix = "zia-chat.chat-list."

    static func load(userId: String) -> CoreChatListCachePayload? {
        guard !userId.isEmpty,
              let data = UserDefaults.standard.data(forKey: keyPrefix + userId) else {
            return nil
        }
        return try? JSONDecoder().decode(CoreChatListCachePayload.self, from: data)
    }

    static func save(
        directMessages: [CoreDirectMessage],
        channelPreviews: [String: CoreMessage],
        userId: String
    ) {
        guard !userId.isEmpty else { return }
        let payload = CoreChatListCachePayload(
            directMessages: directMessages,
            channelPreviews: channelPreviews
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
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
                content: "Once backend settings are saved, these preview messages are replaced by real Core data.",
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
