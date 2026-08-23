import Foundation
import Combine
import OSLog
import UIKit

@MainActor
final class CoreChannelsStore: ObservableObject {
    private static let realtimeLogger = Logger(subsystem: "authcode.ZiaChat", category: "ConvexRealtime")

    @Published var configuration: CoreAppConfiguration
    @Published var channels: [CoreChannel] = []
    @Published var directMessages: [CoreDirectMessage] = []
    @Published var messages: [String: [CoreMessage]] = [:]
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
    private var convexClientTask: Task<ConvexRealtimeClient, Error>?
    private var convexClientTaskKey: String?
    private var isConnectingCompanyRealtime = false
    private var realtimeMessagesSubscription: AnyCancellable?
    private var companyChannelsSubscription: AnyCancellable?
    private var companyDirectMessagesSubscription: AnyCancellable?
    /// Identifica el arranque vigente de las suscripciones de empresa para
    /// que un fallo tardío de una suscripción reemplazada no tire la nueva.
    private var companyRealtimeGeneration = 0
    private var convexWebSocketSubscription: AnyCancellable?
    private var channelSearchTask: Task<Void, Never>?
    private var realtimeConversationId: String?
    private var refreshTask: Task<Void, Never>?
    private var lastRefreshAt: Date?
    /// Primer refresh terminado (con o sin éxito): hasta entonces la lista
    /// vacía muestra el cargador y no el estado "sin chats".
    @Published private(set) var hasLoadedChatList = false
    var hasCompletedRefresh: Bool { lastRefreshAt != nil }
    /// Conversaciones cuya lista de hilos ya se pidió al servidor (o cuya
    /// página local cubre todo el historial).
    private var syncedThreadConversationIds: Set<String> = []
    private var sessionRefreshTask: Task<CoreAppConfiguration, Error>?
    private var sessionMaintenanceTask: Task<Void, Never>?
    private var realtimeRetryTask: Task<Void, Never>?
    private var pendingRealtimeConversationId: String?
    private var realtimeRetryDelay: TimeInterval = 2
    private var sceneIsActive = true
    static let optimisticMessageIdPrefix = "local-pending-"
    private let optimisticMessagePrefix = CoreChannelsStore.optimisticMessageIdPrefix
    /// Conversación cuyo ChatDetailView está en pantalla. Solo ella marca leído.
    private(set) var visibleConversationId: String?
    private var lastMarkedReadMessageId: [String: String] = [:]
    private var pendingSends: [String: PendingSend] = [:]
    private var cacheWriteTask: Task<Void, Never>?
    private var messagesCacheWriteTasks: [String: Task<Void, Never>] = [:]
    /// No leídos que tenía cada conversación al abrirla (antes de ponerlos en
    /// cero); se resuelve a un id cuando llega la primera página del servidor,
    /// porque la lista en memoria o de caché puede estar desactualizada.
    private var pendingNewMessagesUnread: [String: Int] = [:]
    /// Mensaje sobre el que el chat pinta el separador "Nuevos mensajes".
    @Published private(set) var newMessagesDividerId: [String: String] = [:]
    /// Borradores por conversación (o por hilo, con el id de la raíz).
    @Published private(set) var drafts: [String: ComposerDraft] = CoreChannelsStore.loadDrafts()
    static let draftsDefaultsKey = "zia.composerDrafts"
    private var draftsWriteTask: Task<Void, Never>?
    /// Conversaciones puestas en cero localmente; se respeta el cero unos
    /// segundos mientras el servidor procesa el markRead.
    private var locallyClearedAt: [String: Date] = [:]
    private static let locallyClearedGrace: TimeInterval = 10

    init(configuration: CoreAppConfiguration) {
        self.configuration = configuration
        CoreStoreDiskCache.removeLegacyDefaults()
        let draftFiles = Set(drafts.values.flatMap { $0.attachments.map(\.storedFileName) })
        Task.detached(priority: .utility) {
            PendingUploadStorage.purgeStale(keeping: draftFiles)
            AttachmentCacheStorage.purgeStale()
        }
        if configuration.isUsable, !Self.isDemo {
            let userId = configuration.userId
            if let cachedChannels = CoreStoreDiskCache.loadChannels(userId: userId), !cachedChannels.isEmpty {
                self.channels = cachedChannels
                restoreCachedChannelImages(cachedChannels)
            }
            if let cachedList = CoreStoreDiskCache.loadChatList(userId: userId) {
                self.directMessages = cachedList.directMessages
                self.channelPreviews = cachedList.channelPreviews.mapValues(\.coreMessage)
            }
        }
        self.selectedChannelId = channels.first?.id
        if configuration.isUsable {
            startSessionMaintenance()
        }
    }

    private func restoreCachedChannelImages(_ cached: [CoreChannel]) {
        Task { [weak self] in
            let restored = await Task.detached(priority: .userInitiated) {
                CoreStoreDiskCache.restoringInlineImages(cached)
            }.value
            guard let self else { return }
            let restoredById = Dictionary(uniqueKeysWithValues: restored.map { ($0.id, $0) })
            var next = self.channels
            var changed = false
            for index in next.indices {
                guard let source = restoredById[next[index].id]?.metadata else { continue }
                var metadata = next[index].metadata ?? CoreChannelMetadata()
                if metadata.iconImage?.isEmpty != false, let icon = source.iconImage, !icon.isEmpty {
                    metadata.iconImage = icon
                    changed = true
                }
                if metadata.theme?.backgroundImage?.isEmpty != false,
                   let background = source.theme?.backgroundImage, !background.isEmpty {
                    var theme = metadata.theme ?? CoreChannelTheme()
                    theme.backgroundImage = background
                    metadata.theme = theme
                    changed = true
                }
                next[index].metadata = metadata
            }
            if changed {
                self.channels = next
            }
        }
    }

    /// Persiste la lista de chats con debounce y fuera del hilo principal.
    private func scheduleCacheWrite() {
        guard !Self.isDemo else { return }
        cacheWriteTask?.cancel()
        cacheWriteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, let self, self.configuration.isUsable else { return }
            let userId = self.configuration.userId
            let snapshot = CoreStoreCacheSnapshot(
                channels: self.channels,
                directMessages: self.directMessages,
                channelPreviews: self.channelPreviews.mapValues(CachedMessage.init)
            )
            CoreStoreDiskCache.scheduleWrite(snapshot, userId: userId)
        }
    }

    /// Persiste los últimos mensajes de la conversación (sin los envíos
    /// locales pendientes, que no sobreviven al relanzamiento) con debounce.
    private func scheduleMessagesCacheWrite(conversationId: String) {
        guard configuration.isUsable, !Self.isDemo else { return }
        messagesCacheWriteTasks[conversationId]?.cancel()
        messagesCacheWriteTasks[conversationId] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, let self, self.configuration.isUsable else { return }
            self.messagesCacheWriteTasks[conversationId] = nil
            let recent = (self.messages[conversationId] ?? [])
                .filter { $0.localState == nil }
                .suffix(CoreMessagesCache.limit)
                .map(CachedMessage.init)
            CoreMessagesCache.scheduleWrite(recent, userId: self.configuration.userId, conversationId: conversationId)
        }
    }

    @concurrent
    private static func loadCachedMessages(
        userId: String,
        conversationId: String,
        enabled: Bool
    ) async -> [CachedMessage]? {
        guard enabled else { return nil }
        return CoreMessagesCache.load(userId: userId, conversationId: conversationId)
    }

    // MARK: - Borradores

    /// Guarda (o elimina, si está vacío) el borrador de una conversación o hilo.
    func setDraft(_ draft: ComposerDraft?, for key: String, flush: Bool = false) {
        let next = draft.flatMap { $0.isEmpty ? nil : $0 }
        guard drafts[key] != next else { return }
        if let next {
            drafts[key] = next
        } else {
            drafts.removeValue(forKey: key)
        }
        scheduleDraftsWrite(flush: flush)
    }

    private func scheduleDraftsWrite(flush: Bool) {
        draftsWriteTask?.cancel()
        let snapshot = drafts
        guard !flush else {
            Task.detached(priority: .utility) { Self.persistDrafts(snapshot) }
            return
        }
        draftsWriteTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            Self.persistDrafts(snapshot)
        }
    }

    private nonisolated static func persistDrafts(_ drafts: [String: ComposerDraft]) {
        let defaults = UserDefaults.standard
        guard !drafts.isEmpty, let data = try? JSONEncoder().encode(drafts) else {
            defaults.removeObject(forKey: draftsDefaultsKey)
            return
        }
        defaults.set(data, forKey: draftsDefaultsKey)
    }

    private nonisolated static func loadDrafts() -> [String: ComposerDraft] {
        guard let data = UserDefaults.standard.data(forKey: draftsDefaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: ComposerDraft].self, from: data)) ?? [:]
    }

    convenience init() {
        self.init(configuration: CoreConfigurationStore.load())
    }

    /// Modo demo (`-zia-demo`, solo DEBUG): datos de muestra y ninguna
    /// llamada de red. Cada método que toca el servidor lo consulta.
    nonisolated static var isDemo: Bool { ZiaDemoMode.isEnabled }

#if DEBUG
    static func preview() -> CoreChannelsStore {
        let store = CoreChannelsStore(configuration: CoreConfigurationStore.load())
        store.channels = CorePreviewData.channels
        store.messages = CorePreviewData.messages
        store.selectedChannelId = store.channels.first?.id
        return store
    }

    static func demo() -> CoreChannelsStore {
        let store = CoreChannelsStore(configuration: CorePreviewData.configuration)
        store.channels = CorePreviewData.channels
        store.directMessages = CorePreviewData.directMessages
        store.channelPreviews = CorePreviewData.channelPreviews
        store.messages = CorePreviewData.messages
        store.messagePins = CorePreviewData.pins
        store.threadReplies = CorePreviewData.threadReplies
        store.mentionableUsers = CorePreviewData.users
        store.selectedChannelId = store.channels.first?.id
        store.hasLoadedChatList = true
        store.lastRefreshAt = Date()
        return store
    }

    /// Páginas antiguas ya sintetizadas por conversación en modo demo.
    private var demoOlderPagesLoaded: [String: Int] = [:]
#endif

    func setVisibleConversation(_ conversationId: String?) {
        visibleConversationId = conversationId
    }

    /// Limpia la conversación visible solo si sigue siendo la indicada: al
    /// reemplazar la ruta, el `onDisappear` del chat anterior puede llegar
    /// después del `onAppear` del nuevo.
    func clearVisibleConversation(_ conversationId: String?) {
        guard visibleConversationId == conversationId else { return }
        visibleConversationId = nil
    }

    func closeActiveConversation() {
        visibleConversationId = nil
        stopRealtime()
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
        guard !Self.isDemo else { return }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try ConvexCoreClient(configuration: activeConfiguration)
            let loaded = try await fetchDirectMessages(using: client)
            applyDirectMessages(loaded)
            hydrateDirectMessagePeers(loaded, using: client)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Encuentra o crea el DM con otra persona en Convex y devuelve el canal
    /// fantasma listo para abrir.
    func startDirectMessage(with user: CoreUserLite) async -> CoreChannel? {
        guard configuration.isUsable, user.id != configuration.userId else { return nil }
        lastError = nil
        if Self.isDemo {
            return directMessages.first { $0.peer.id == user.id }.map(dmChannel(for:))
        }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try ConvexCoreClient(configuration: activeConfiguration)
            var dm = try await client.startDirectMessage(peerUserId: user.id)
            if dm.peer.id == user.id, dm.peer.fullName == nil {
                dm.peer = user
            }
            if !directMessages.contains(where: { $0.id == dm.id }) {
                directMessages.insert(dm, at: 0)
                scheduleCacheWrite()
            }
            return dmChannel(for: dm)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func clearDMUnread(_ dmId: String) {
        guard let index = directMessages.firstIndex(where: { $0.id == dmId }) else { return }
        locallyClearedAt[dmId] = Date()
        guard directMessages[index].unreadCount != 0 || directMessages[index].mentionCount != 0 else { return }
        directMessages[index].unreadCount = 0
        directMessages[index].mentionCount = 0
        scheduleCacheWrite()
    }

    private func isLocallyCleared(_ id: String) -> Bool {
        guard let clearedAt = locallyClearedAt[id] else { return false }
        if Date().timeIntervalSince(clearedAt) < Self.locallyClearedGrace {
            return true
        }
        locallyClearedAt[id] = nil
        return false
    }

    func save(configuration: CoreAppConfiguration) {
        self.configuration = configuration
        guard !Self.isDemo else { return }
        CoreConfigurationStore.save(configuration)
        if configuration.isUsable {
            startSessionMaintenance()
        } else {
            stopSessionMaintenance()
        }
    }

    func login(email: String, password: String) async {
        guard !Self.isDemo else { return }
        isLoggingIn = true
        lastError = nil
        do {
            let environment = CoreEnvironment.shared
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
        visibleConversationId = nil
        lastMarkedReadMessageId = [:]
        lastRefreshAt = nil
        hasLoadedChatList = false
        syncedThreadConversationIds = []
        pendingNewMessagesUnread = [:]
        newMessagesDividerId = [:]
        CoreMessagesCache.removeAll(userId: configuration.userId)
        drafts = [:]
        scheduleDraftsWrite(flush: true)
        var next = configuration
        next.clearSession()
        save(configuration: next)
        channels = []
        directMessages = []
        messages = [:]
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
        guard force || configuration.accessTokenExpires(), !Self.isDemo else {
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
        guard configuration.isUsable, !Self.isDemo, sessionMaintenanceTask == nil else { return }
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
        if Self.isDemo {
            clearUnread(for: channel.id)
            return
        }
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

    func refresh(force: Bool = false) async {
        guard configuration.isUsable else {
            channels = []
            messages = [:]
            selectedChannelId = nil
            lastError = nil
            return
        }

        if Self.isDemo {
            hasLoadedChatList = true
            lastRefreshAt = Date()
            return
        }
        if let refreshTask {
            await refreshTask.value
            return
        }
        if !force, let lastRefreshAt, Date().timeIntervalSince(lastRefreshAt) < 5 {
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
                startCompanyRealtime()
                async let channelsLoad = client.listChannels()
                async let directMessagesLoad = try? fetchDirectMessages(using: client)
                async let usersLoad = try? client.listMentionableUsers()
                let loadedChannels = try await channelsLoad
                guard sceneIsActive, !Task.isCancelled else { return }
                applyChannels(loadedChannels)
                hasLoadedChatList = true
                if let loadedDirectMessages = await directMessagesLoad {
                    guard sceneIsActive, !Task.isCancelled else { return }
                    applyDirectMessages(loadedDirectMessages)
                    hydrateDirectMessagePeers(loadedDirectMessages, using: client)
                }
                if let users = await usersLoad {
                    guard sceneIsActive, !Task.isCancelled else { return }
                    mentionableUsers = users
                }
                lastRefreshAt = Date()
            } catch {
                if sceneIsActive {
                    lastError = error.localizedDescription
                    hasLoadedChatList = true
                }
            }
        }
        refreshTask = task
        await task.value
    }

    private func applyChannels(_ loadedChannels: [CoreChannel]) {
        // Carry the previously known icon forward so it does not flash or
        // disappear during a refresh.
        let previousIcons = Dictionary(
            channels.compactMap { channel -> (String, String)? in
                guard let icon = channel.metadata?.iconImage, !icon.isEmpty else { return nil }
                return (channel.id, icon)
            },
            uniquingKeysWith: { first, _ in first }
        )

        let mergedChannels = loadedChannels.map { channel -> CoreChannel in
            var updated = channel
            if isLocallyCleared(channel.id) {
                updated.unreadCount = 0
                updated.mentionCount = 0
            }
            if updated.metadata?.iconImage?.isEmpty != false,
               let previousIcon = previousIcons[channel.id] {
                var metadata = updated.metadata ?? CoreChannelMetadata()
                metadata.iconImage = previousIcon
                updated.metadata = metadata
            }
            return updated
        }

        if channels != mergedChannels {
            channels = mergedChannels
            scheduleCacheWrite()
        }
        mergeChannelPreviews(from: mergedChannels)
        let nextSelectedChannelId = selectedChannelId.flatMap(channel(with:))?.id ?? channels.first?.id
        if selectedChannelId != nextSelectedChannelId {
            selectedChannelId = nextSelectedChannelId
        }
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
        if next != channelPreviews {
            channelPreviews = next
            scheduleCacheWrite()
        }
    }

    private func applyDirectMessages(_ loaded: [CoreDirectMessage]) {
        let cachedByID = Dictionary(
            uniqueKeysWithValues: directMessages.map { ($0.id, $0) }
        )
        let merged = loaded.map { incoming in
            var merged = ConvexCoreClient.applyingCachedPeerProfile(incoming)
            if isLocallyCleared(incoming.id) {
                merged.unreadCount = 0
                merged.mentionCount = 0
            }
            guard let cached = cachedByID[incoming.id] else {
                return merged
            }
            // Un par ya hidratado no debe volver a "Usuario Core" por una
            // emisión de la suscripción sin perfil.
            if ConvexCoreClient.peerNeedsHydration(merged.peer), !ConvexCoreClient.peerNeedsHydration(cached.peer) {
                merged.peer = cached.peer
            }
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
        if merged != directMessages {
            directMessages = merged
            scheduleCacheWrite()
        }
    }

    /// Resuelve nombre/avatar de pares incompletos en segundo plano y parchea
    /// la lista sin bloquear el refresh.
    private func hydrateDirectMessagePeers(_ loaded: [CoreDirectMessage], using client: ConvexCoreClient) {
        guard loaded.contains(where: { ConvexCoreClient.peerNeedsHydration($0.peer) }) else { return }
        Task { [weak self] in
            let profiles = await client.fetchMissingPeerProfiles(for: loaded)
            guard let self, !profiles.isEmpty, self.configuration.isUsable else { return }
            var next = self.directMessages
            var changed = false
            for index in next.indices where ConvexCoreClient.peerNeedsHydration(next[index].peer) {
                let hydrated = ConvexCoreClient.applyingCachedPeerProfile(next[index])
                if hydrated.peer != next[index].peer {
                    next[index] = hydrated
                    changed = true
                }
            }
            if changed {
                self.directMessages = next
                self.scheduleCacheWrite()
            }
        }
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

    func channelForNotification(channelId: String?, conversationId: String?) async throws -> CoreChannel? {
        if let channel = resolveChannel(channelId: channelId, conversationId: conversationId) {
            return channel
        }
        guard !Self.isDemo else { return nil }

        let activeConfiguration = try await ensureFreshSession(restartRealtime: false)
        let client = try ConvexCoreClient(configuration: activeConfiguration)
        applyChannels(try await client.listChannels())
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
        if !force {
            pendingNewMessagesUnread[conversationId] = channels.first { $0.id == channel.id }?.unreadCount
                ?? directMessages.first { $0.id == channel.id }?.unreadCount
                ?? channel.unreadCount
            newMessagesDividerId[conversationId] = nil
        }
        guard configuration.isUsable else { return }
        if Self.isDemo {
            resolveNewMessagesDivider(conversationId: conversationId)
            mergeThreadSummaries(from: messages[conversationId] ?? [], conversationId: conversationId)
            await loadChannelMembers(for: channel, force: false)
            clearUnread(for: channel.id)
            return
        }
        // La caché de disco se lee mientras se valida la sesión; si no hay
        // nada en memoria, siembra la lista y la suscripción la concilia.
        let userId = configuration.userId
        let shouldSeedFromCache = !force && messages[conversationId]?.isEmpty != false
        async let cachedPage = Self.loadCachedMessages(
            userId: userId,
            conversationId: conversationId,
            enabled: shouldSeedFromCache
        )
        do {
            _ = try await ensureFreshSession()
        } catch {
            lastError = error.localizedDescription
            return
        }
        // Si el usuario ya salió del chat mientras esperábamos, no revivir la
        // suscripción ni marcar leído.
        guard !Task.isCancelled else { return }
        if let cached = await cachedPage, !cached.isEmpty, messages[conversationId]?.isEmpty != false {
            messages[conversationId] = cached.map(\.coreMessage)
            if hasOlderMessages[conversationId] == nil {
                hasOlderMessages[conversationId] = true
            }
        }
        let membersLoad = Task { await loadChannelMembers(for: channel, force: force) }
        // Una suscripción recién creada entrega la página más reciente por sí
        // sola; solo hace falta resincronizar si ya estaba viva.
        let subscriptionWasLive = realtimeConversationId == conversationId
        startRealtime(for: channel)
        if !force, messages[conversationId]?.isEmpty == false {
            markReadIfNeeded(conversationId: conversationId, messageId: messages[conversationId]?.last?.id)
            clearUnread(for: channel.id)
            if subscriptionWasLive {
                Task { [weak self] in
                    await self?.resyncRealtimeMessages(conversationId: conversationId)
                }
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
            messages[conversationId] = keepingLocalSends(messages[conversationId] ?? [], in: loaded)
            resolveNewMessagesDivider(conversationId: conversationId)
            hasOlderMessages[conversationId] = loaded.count == pageLimit
            scheduleMessagesCacheWrite(conversationId: conversationId)
            mergeThreadSummaries(from: loaded, conversationId: conversationId)
            clearUnread(for: channel.id)
            isLoadingMessages[conversationId] = false

            guard !Task.isCancelled else { return }
            markReadIfNeeded(conversationId: conversationId, messageId: loaded.last?.id)
            await membersLoad.value
        } catch {
            lastError = error.localizedDescription
            isLoadingMessages[conversationId] = false
        }
    }

    // MARK: - Recibos de lectura

    /// Carga las marcas de lectura de todos los miembros de la conversación.
    func loadConversationReads(for channel: CoreChannel) async {
        guard let conversationId = channel.conversationId, configuration.isUsable, !Self.isDemo else { return }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try ConvexCoreClient(configuration: activeConfiguration)
            let reads = try await client.listConversationReads(conversationId: conversationId)
            let next = Dictionary(
                reads.map { ($0.userId, $0.lastReadAt) },
                uniquingKeysWith: max
            )
            if conversationReads[conversationId] != next {
                conversationReads[conversationId] = next
            }
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
        MessageReceipt.compute(
            message: message,
            members: members(for: channel),
            reads: conversationReads[message.conversationId] ?? [:]
        )
    }

    /// Para DMs, `loadChannelMembers` ya guarda al peer en `channelMembers`.
    func members(for channel: CoreChannel) -> [CoreUserLite] {
        if let cached = channelMembers[channel.id] { return cached }
        if channel.isDirect, let directMessage = directMessages.first(where: { $0.id == channel.id }) {
            return [directMessage.peer]
        }
        return []
    }

    private func loadChannelMembers(for channel: CoreChannel, force: Bool) async {
        if channel.isDirect {
            if let directMessage = directMessages.first(where: { $0.id == channel.id }) {
                channelMembers[channel.id] = [directMessage.peer]
            }
            return
        }
        if !force, channelMembers[channel.id] != nil { return }
        if Self.isDemo {
            channelMembers[channel.id] = mentionableUsers
            return
        }
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

#if DEBUG
        if Self.isDemo {
            try? await Task.sleep(for: .milliseconds(400))
            let loadedPages = demoOlderPagesLoaded[conversationId, default: 0]
            demoOlderPagesLoaded[conversationId] = loadedPages + 1
            hasOlderMessages[conversationId] = loadedPages + 1 < 2
            mergeMessagePage(CorePreviewData.olderPage(before: oldestMessage), conversationId: conversationId, isLatestPage: false)
            return
        }
#endif
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try ConvexCoreClient(configuration: activeConfiguration)
            let page = try await client.listMessagePage(
                conversationId: conversationId,
                before: oldestMessage.createdAt
            )

            hasOlderMessages[conversationId] = page.count == 21
            mergeMessagePage(page, conversationId: conversationId, isLatestPage: false)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadMessagePins(for channel: CoreChannel) async {
        guard configuration.isUsable, !Self.isDemo, let conversationId = channel.conversationId else { return }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try ConvexCoreClient(configuration: activeConfiguration)
            let pins = try await client.listMessagePins(conversationId: conversationId)
            if messagePins[conversationId] != pins {
                messagePins[conversationId] = pins
            }
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
        if Self.isDemo {
            if isPinned(message) {
                messagePins[message.conversationId]?.removeAll { $0.messageId == message.id }
            } else {
                let pin = CoreMessagePin(
                    id: "local-pin-\(message.id)",
                    empresaId: message.empresaId,
                    conversationId: message.conversationId,
                    messageId: message.id,
                    pinnedBy: configuration.userId,
                    createdAt: Date()
                )
                messagePins[message.conversationId, default: []].insert(pin, at: 0)
            }
            return
        }
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
        // Los adjuntos pasan a disco fuera del MainActor: la burbuja optimista
        // los muestra desde el archivo y la subida usa `fromFile:`.
        let persisted: [CorePendingAttachment]
        do {
            persisted = try await Self.persistAttachments(attachments)
        } catch {
            lastError = error.localizedDescription
            return
        }
        var optimisticMessage = makeOptimisticMessage(
            content: diceResult.map { "🎲 Dado Core: \($0) (+\(diceXp) XP)" } ?? content,
            channel: channel,
            conversationId: conversationId,
            parentMessageId: parentMessageId,
            attachments: persisted
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
        var metadata = optimisticMessage.metadata ?? CoreMessageMetadata()
        metadata.payload = (metadata.payload ?? [:]).merging(
            [Self.clientMessageIdKey: .string(optimisticMessage.id)]
        ) { _, new in new }
        optimisticMessage.metadata = metadata
        optimisticMessage.localState = .sending
        if let parentMessageId {
            if upsertThreadReply(optimisticMessage, parentMessageId: parentMessageId) {
                incrementReplyCount(for: parentMessageId, conversationId: conversationId)
            }
        } else {
            upsertMessage(optimisticMessage)
        }

        await performSend(
            PendingSend(channel: channel, message: optimisticMessage, attachments: persisted)
        )
    }

    /// Envío pendiente de confirmar por el servidor; se conserva tras un fallo
    /// para poder reintentarlo con el mismo contenido y adjuntos.
    private struct PendingSend {
        var channel: CoreChannel
        var message: CoreMessage
        var attachments: [CorePendingAttachment]
    }

    private func performSend(_ pending: PendingSend) async {
        let optimistic = pending.message
        let conversationId = optimistic.conversationId
        lastError = nil
        if Self.isDemo {
            var message = optimistic
            message.id = "demo-\(UUID().uuidString)"
            message.localState = nil
            if let parentMessageId = optimistic.parentMessageId {
                replaceThreadReply(id: optimistic.id, with: message, parentMessageId: parentMessageId)
            } else {
                removeMessage(id: optimistic.id, conversationId: conversationId)
                upsertMessage(message)
                updateChannelPreview(with: message)
            }
            return
        }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try ConvexCoreClient(configuration: activeConfiguration)
            var message = try await client.sendMessage(
                empresaId: pending.channel.empresaId,
                conversationId: conversationId,
                // Los DMs no tienen canal: el mensaje va solo a la conversación.
                channelId: pending.channel.isDirectMessage ? nil : pending.channel.id,
                parentMessageId: optimistic.parentMessageId,
                content: optimistic.content,
                attachments: pending.attachments,
                metadata: optimistic.metadata
            )
            message.author = optimistic.author
            pendingSends[optimistic.id] = nil
            PendingUploadStorage.remove(pending.attachments)
            if let parentMessageId = optimistic.parentMessageId {
                replaceThreadReply(id: optimistic.id, with: message, parentMessageId: parentMessageId)
            } else {
                removeMessage(id: optimistic.id, conversationId: conversationId)
                upsertMessage(message)
                updateChannelPreview(with: message)
            }
            markReadIfNeeded(conversationId: conversationId, messageId: message.id)
        } catch {
            // Si la página en tiempo real ya confirmó el mensaje, la burbuja
            // optimista desapareció y no hay nada que reintentar.
            guard isLocalMessagePresent(optimistic) else {
                PendingUploadStorage.remove(pending.attachments)
                return
            }
            pendingSends[optimistic.id] = pending
            setLocalState(
                .failed,
                messageId: optimistic.id,
                conversationId: conversationId,
                parentMessageId: optimistic.parentMessageId
            )
            lastError = error.localizedDescription
            Haptics.error()
        }
    }

    private func isLocalMessagePresent(_ message: CoreMessage) -> Bool {
        if let parentMessageId = message.parentMessageId {
            return threadReplies[parentMessageId]?.contains { $0.id == message.id } ?? false
        }
        return messages[message.conversationId]?.contains { $0.id == message.id } ?? false
    }

    /// Reintenta un mensaje marcado como `.failed`.
    func retrySend(messageId: String) async {
        guard let pending = pendingSends.removeValue(forKey: messageId) else { return }
        setLocalState(
            .sending,
            messageId: messageId,
            conversationId: pending.message.conversationId,
            parentMessageId: pending.message.parentMessageId
        )
        await performSend(pending)
    }

    /// Descarta un mensaje fallido y sus archivos temporales.
    func discardFailed(messageId: String) {
        guard let pending = pendingSends.removeValue(forKey: messageId) else { return }
        PendingUploadStorage.remove(pending.attachments)
        let conversationId = pending.message.conversationId
        if let parentMessageId = pending.message.parentMessageId {
            threadReplies[parentMessageId]?.removeAll { $0.id == messageId }
            incrementReplyCount(for: parentMessageId, conversationId: conversationId, by: -1)
            decrementThreadSummary(parentMessageId: parentMessageId, conversationId: conversationId)
        } else {
            removeMessage(id: messageId, conversationId: conversationId)
        }
    }

    func isFailedSend(_ message: CoreMessage) -> Bool {
        message.localState == .failed && pendingSends[message.id] != nil
    }

    private func setLocalState(
        _ state: LocalSendState?,
        messageId: String,
        conversationId: String,
        parentMessageId: String?
    ) {
        if let parentMessageId {
            guard var replies = threadReplies[parentMessageId],
                  let index = replies.firstIndex(where: { $0.id == messageId }) else { return }
            replies[index].localState = state
            threadReplies[parentMessageId] = replies
        } else {
            guard var list = messages[conversationId],
                  let index = list.firstIndex(where: { $0.id == messageId }) else { return }
            list[index].localState = state
            messages[conversationId] = list
        }
    }

    @concurrent
    private static func persistAttachments(_ attachments: [CorePendingAttachment]) async throws -> [CorePendingAttachment] {
        try attachments.map { try PendingUploadStorage.persist($0) }
    }

    func loadThread(for message: CoreMessage, force: Bool = false) async {
        if !force, threadReplies[message.id] != nil { return }
        guard configuration.isUsable, !Self.isDemo else { return }

        isLoadingThread[message.id] = true
        defer { isLoadingThread[message.id] = false }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try ConvexCoreClient(configuration: activeConfiguration)
            let loaded = try await client.listThreadReplies(
                conversationId: message.conversationId,
                parentMessageId: message.id
            )
            threadReplies[message.id] = keepingLocalSends(threadReplies[message.id] ?? [], in: loaded)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Loads the list of threads (root messages with replies) for a channel.
    func loadChannelThreads(for channel: CoreChannel, force: Bool = false) async {
        guard let conversationId = channel.conversationId else { return }
        if !force, syncedThreadConversationIds.contains(conversationId) { return }
        guard configuration.isUsable, canPublishSceneUpdates() else { return }
        if Self.isDemo {
            mergeThreadSummaries(from: messages[conversationId] ?? [], conversationId: conversationId)
            return
        }

        setLoadingChannelThreads(true, conversationId: conversationId)
        defer { setLoadingChannelThreads(false, conversationId: conversationId) }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try ConvexCoreClient(configuration: activeConfiguration)
            let loadedThreads = try await client.listChannelThreads(conversationId: conversationId)
            publishSceneUpdate {
                channelThreads[conversationId] = loadedThreads
                syncedThreadConversationIds.insert(conversationId)
            }
        } catch {
            publishError(error.localizedDescription)
        }
    }

    /// Carga los threads de todos los canales de texto (filtro "Hilos" del index).
    /// Con `force == false` solo consulta los canales que aún no tienen threads
    /// en memoria, así el refresco incremental es barato.
    func loadAllChannelThreads(force: Bool = false) async {
        guard configuration.isUsable, !Self.isDemo, canPublishSceneUpdates() else { return }
        let targets = textChannels.compactMap { channel -> String? in
            guard let conversationId = channel.conversationId else { return nil }
            return force || !syncedThreadConversationIds.contains(conversationId) ? conversationId : nil
        }
        guard !targets.isEmpty else { return }

        setLoadingAllThreads(true)
        defer { setLoadingAllThreads(false) }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try ConvexCoreClient(configuration: activeConfiguration)
            let loaded = await withTaskGroup(of: (String, [CoreThreadSummary])?.self) { group in
                var results: [String: [CoreThreadSummary]] = [:]
                var pending = targets[...]
                let maxInFlight = 4
                func enqueue() {
                    guard let conversationId = pending.popFirst() else { return }
                    group.addTask { @MainActor in
                        guard let threads = try? await client.listChannelThreads(conversationId: conversationId) else {
                            return nil
                        }
                        return (conversationId, threads)
                    }
                }
                for _ in 0..<maxInFlight { enqueue() }
                while let result = await group.next() {
                    if let (conversationId, threads) = result {
                        results[conversationId] = threads
                    }
                    enqueue()
                }
                return results
            }
            guard canPublishSceneUpdates(), !loaded.isEmpty else { return }
            var next = channelThreads
            for (conversationId, threads) in loaded {
                next[conversationId] = threads
            }
            syncedThreadConversationIds.formUnion(loaded.keys)
            channelThreads = next
        } catch {
            publishError(error.localizedDescription)
        }
    }

    func sendThreadReply(
        _ text: String,
        attachments: [CorePendingAttachment] = [],
        to root: CoreMessage,
        in channel: CoreChannel
    ) async {
        await send(text, attachments: attachments, in: channel, parentMessageId: root.id)
    }

    func forward(_ message: CoreMessage, to channel: CoreChannel) async {
        guard configuration.isUsable else { return }
        if Self.isDemo {
            await send(message.content, in: channel)
            return
        }
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
        guard configuration.isUsable, !Self.isDemo else { return }
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
        guard configuration.isUsable, !Self.isDemo else { return false }
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
        guard configuration.isUsable, !Self.isDemo else { return false }
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
        guard configuration.isUsable, !Self.isDemo else { return nil }
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
        if Self.isDemo {
            return (messages[channel.conversationId ?? ""] ?? [])
                .filter { $0.content.localizedCaseInsensitiveContains(trimmed) }
        }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try ConvexCoreClient(configuration: activeConfiguration)
            return try await client.searchChannelMessages(keyword: trimmed, channelIds: [channel.id])
        } catch {
            return []
        }
    }

    func loadChannelMemberRoles(channelId: String) async -> [CoreChannelMemberRole] {
        guard configuration.isUsable, !Self.isDemo else { return [] }
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
        guard configuration.isUsable, !Self.isDemo else { return nil }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try ConvexCoreClient(configuration: activeConfiguration)
            let token = try await client.createChannelInviteToken(channelId: channel.id)
            let baseURL = CoreEnvironment.shared.appURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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
        let previous = messages[message.conversationId]?.first { $0.id == message.id } ?? message
        applyLocalMessageEdit(messageId: message.id, conversationId: message.conversationId, content: content)
        if Self.isDemo { return true }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try ConvexCoreClient(configuration: activeConfiguration)
            _ = try await client.updateMessage(messageId: message.id, content: content)
            return true
        } catch {
            applyLocalMessageEdit(
                messageId: message.id,
                conversationId: message.conversationId,
                content: previous.content,
                editedAt: previous.editedAt
            )
            lastError = error.localizedDescription
            return false
        }
    }

    /// Elimina (soft delete) un mensaje propio en Convex.
    @discardableResult
    func deleteMessage(_ message: CoreMessage) async -> Bool {
        guard configuration.isUsable else { return false }
        lastError = nil
        if Self.isDemo {
            removeMessage(id: message.id, conversationId: message.conversationId)
            messagePins[message.conversationId]?.removeAll { $0.messageId == message.id }
            return true
        }
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

    private func applyLocalMessageEdit(
        messageId: String,
        conversationId: String,
        content: String,
        editedAt: Date? = Date()
    ) {
        if var list = messages[conversationId],
           let index = list.firstIndex(where: { $0.id == messageId }) {
            list[index].content = content
            list[index].editedAt = editedAt
            messages[conversationId] = list
            scheduleMessagesCacheWrite(conversationId: conversationId)
        }
        for (rootId, replies) in threadReplies {
            guard let index = replies.firstIndex(where: { $0.id == messageId }) else { continue }
            var copy = replies
            copy[index].content = content
            copy[index].editedAt = editedAt
            threadReplies[rootId] = copy
        }
        if var preview = channelPreviews[conversationId], preview.id == messageId {
            preview.content = content
            channelPreviews[conversationId] = preview
        }
    }

    func loadMentionableUsersIfNeeded() async {
        guard configuration.isUsable, !Self.isDemo, mentionableUsers.isEmpty else { return }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try ConvexCoreClient(configuration: activeConfiguration)
            mentionableUsers = try await client.listMentionableUsers()
        } catch {
            // Non-fatal: the member picker simply stays empty.
        }
    }

    func loadInternalCompanies() async {
        guard configuration.isUsable, !Self.isDemo else { return }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try ConvexCoreClient(configuration: activeConfiguration)
            internalCompanies = try await client.listInternalCompanies()
        } catch {
            internalCompanies = []
        }
    }

    /// Alterna la reacción de forma optimista y concilia con la respuesta del
    /// servidor sin recargar la conversación.
    func react(to message: CoreMessage, emoji: String) async {
        guard configuration.isUsable, message.localState == nil else { return }
        let conversationId = message.conversationId
        let previousReactions = messages[conversationId]?.first { $0.id == message.id }?.reactions
        var reactions = previousReactions ?? []
        if let existing = reactions.firstIndex(where: { $0.userId == configuration.userId && $0.emoji == emoji }) {
            reactions.remove(at: existing)
        } else {
            reactions.append(
                CoreReaction(
                    id: "local-\(UUID().uuidString)",
                    empresaId: message.empresaId,
                    messageId: message.id,
                    userId: configuration.userId,
                    emoji: emoji,
                    createdAt: Date()
                )
            )
        }
        setReactions(reactions, messageId: message.id, conversationId: conversationId)
        lastError = nil
        guard !Self.isDemo else { return }
        do {
            let activeConfiguration = try await ensureFreshSession()
            let client = try ConvexCoreClient(configuration: activeConfiguration)
            let toggle = try await client.react(messageId: message.id, emoji: emoji)
            var reconciled = reactions
            if !toggle.removed, let confirmed = toggle.reaction {
                if let placeholder = reconciled.firstIndex(where: {
                    $0.id.hasPrefix("local-") && $0.userId == configuration.userId && $0.emoji == emoji
                }) {
                    reconciled[placeholder] = confirmed
                } else if !reconciled.contains(where: { $0.id == confirmed.id }) {
                    reconciled.append(confirmed)
                }
            }
            var updated = toggle.message
            // El servidor puede devolver el documento sin hidratar (sin
            // reacciones): en ese caso se conserva la conciliación local.
            if updated.reactions?.isEmpty != false {
                updated.reactions = reconciled
            }
            upsertMessage(updated)
        } catch {
            setReactions(previousReactions, messageId: message.id, conversationId: conversationId)
            lastError = error.localizedDescription
        }
    }

    private func setReactions(_ reactions: [CoreReaction]?, messageId: String, conversationId: String) {
        guard var list = messages[conversationId],
              let index = list.firstIndex(where: { $0.id == messageId }) else { return }
        list[index].reactions = reactions
        messages[conversationId] = list
        scheduleMessagesCacheWrite(conversationId: conversationId)
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
        if configuration.isUsable, !Self.isDemo {
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
            locallyClearedAt[channelId] = Date()
            if channels[index].unreadCount != 0 || channels[index].mentionCount != 0 {
                channels[index].unreadCount = 0
                channels[index].mentionCount = 0
                scheduleCacheWrite()
            }
        }
        clearDMUnread(channelId)
    }

    private static let clientMessageIdKey = "clientMessageId"

    /// Coalesce de markRead: una sola llamada por (conversación, último mensaje),
    /// en vez de una por cada tick de la suscripción.
    private func markReadIfNeeded(conversationId: String, messageId: String?) {
        guard let messageId, lastMarkedReadMessageId[conversationId] != messageId else { return }
        lastMarkedReadMessageId[conversationId] = messageId
        guard !Self.isDemo else { return }
        Task { [configuration] in
            guard let client = try? ConvexCoreClient(configuration: configuration) else { return }
            do {
                try await client.markRead(conversationId: conversationId, lastReadMessageId: messageId)
            } catch {
                if lastMarkedReadMessageId[conversationId] == messageId {
                    lastMarkedReadMessageId[conversationId] = nil
                }
            }
        }
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
        parentMessageId: String?,
        attachments: [CorePendingAttachment] = []
    ) -> CoreMessage {
        let id = "\(optimisticMessagePrefix)\(UUID().uuidString)"
        let localAttachments = attachments.map { pending in
            CoreAttachment(
                id: "local-\(pending.id.uuidString)",
                empresaId: channel.empresaId,
                messageId: id,
                uploaderId: configuration.userId,
                url: pending.localURL?.absoluteString,
                fileName: pending.fileName,
                mimeType: pending.mimeType,
                sizeBytes: pending.sizeBytes,
                createdAt: Date()
            )
        }
        return CoreMessage(
            id: id,
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
            ),
            attachments: localAttachments.isEmpty ? nil : localAttachments
        )
    }

    private func startRealtime(for channel: CoreChannel, force: Bool = false) {
        guard sceneIsActive, !Self.isDemo else { return }
        guard let conversationId = channel.conversationId else { return }
        guard force || realtimeConversationId != conversationId else { return }

        stopRealtime()
        realtimeConversationId = conversationId
        realtimeResyncTask = Task { [weak self] in
            guard let self else { return }
            do {
                Self.realtimeLogger.info("Starting message subscription conversation=\(conversationId, privacy: .public)")
                let service = try await self.ensureConvexRealtimeClient()
                // Si mientras esperábamos el cliente otra llamada reinició o
                // detuvo el realtime, no pisar su suscripción.
                guard !Task.isCancelled, self.realtimeConversationId == conversationId else { return }
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
                                if self.hasOlderMessages[conversationId] != page.hasMore {
                                    self.hasOlderMessages[conversationId] = page.hasMore
                                }
                                self.mergeMessagePage(loaded, conversationId: conversationId)
                                if let latest = loaded.last {
                                    self.updateChannelPreview(with: latest)
                                    if self.visibleConversationId == conversationId {
                                        self.clearUnreadForActiveConversation(conversationId)
                                        self.markReadIfNeeded(conversationId: conversationId, messageId: latest.id)
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
                    // Mientras llega el reintento, la página se actualiza por HTTP.
                    Task { [weak self] in
                        await self?.resyncRealtimeMessages(conversationId: conversationId)
                    }
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
        guard sceneIsActive, !Self.isDemo else { return }
        if !isConnectingCompanyRealtime {
            let companyIsLive = companyChannelsSubscription != nil && companyDirectMessagesSubscription != nil
            startCompanyRealtime(force: !companyIsLive)
        }
        let conversationId = realtimeConversationId ?? pendingRealtimeConversationId
        pendingRealtimeConversationId = nil
        guard let conversationId,
              let channel = channels.first(where: { $0.conversationId == conversationId })
                ?? directMessages.first(where: { $0.id == conversationId })?.chatTarget else {
            return
        }
        startRealtime(for: channel, force: realtimeConversationId != conversationId)
    }

    private func startCompanyRealtime(force: Bool = false) {
        guard sceneIsActive, configuration.isUsable, !Self.isDemo, let empresaId = configuration.empresaId else { return }
        guard force || companyResyncTask == nil else { return }

        stopCompanyRealtime()
        isConnectingCompanyRealtime = true
        companyRealtimeGeneration += 1
        let generation = companyRealtimeGeneration
        companyResyncTask = Task { [weak self] in
            // Una tarea reemplazada llega aquí cancelada; el flag pertenece a la vigente.
            defer {
                if !Task.isCancelled {
                    self?.isConnectingCompanyRealtime = false
                }
            }
            guard let self, self.configuration.empresaId == empresaId else { return }
            do {
                Self.realtimeLogger.info("Starting company subscriptions empresa=\(empresaId, privacy: .public)")
                let service = try await self.ensureConvexRealtimeClient()
                guard !Task.isCancelled else { return }
                let displayName = self.configuration.displayName
                self.companyChannelsSubscription = service
                    .subscribeChannels(empresaId: empresaId, displayName: displayName)
                    .sink(
                        receiveCompletion: { [weak self] completion in
                            guard case .failure = completion else { return }
                            Task { @MainActor in
                                guard let self, self.sceneIsActive,
                                      self.companyRealtimeGeneration == generation else { return }
                                Self.realtimeLogger.error("Channels subscription failed empresa=\(empresaId, privacy: .public)")
                                self.companyChannelsSubscription = nil
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
                                guard let self, self.sceneIsActive,
                                      self.companyRealtimeGeneration == generation else { return }
                                Self.realtimeLogger.error("DM subscription failed empresa=\(empresaId, privacy: .public)")
                                self.companyDirectMessagesSubscription = nil
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
        isConnectingCompanyRealtime = false
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
        convexClientTask?.cancel()
        convexClientTask = nil
        convexClientTaskKey = nil
    }

    private func scheduleRealtimeReconnect(conversationId: String? = nil) {
        guard sceneIsActive, configuration.isUsable else { return }
        pendingRealtimeConversationId = conversationId ?? pendingRealtimeConversationId
        guard realtimeRetryTask == nil else { return }
        let delay = realtimeRetryDelay * Double.random(in: 0.8...1.25)
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

        // Descarta el cliente websocket cacheado: si la suscripción falló por
        // un socket en mal estado (p. ej. auth rechazada), reutilizarlo dejaría
        // el realtime muerto de forma permanente.
        stopConvexRealtimeClient()
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
        guard !Self.isDemo else { throw CoreAuthError.missingRefreshToken }
        let activeConfiguration = try await ensureFreshSession(restartRealtime: false)
        let realtimeKey = "\(activeConfiguration.convexURL)|\(activeConfiguration.accessToken)"
        if let convexRealtimeClient, convexRealtimeKey == realtimeKey {
            Self.realtimeLogger.info("Reusing Convex realtime client")
            return convexRealtimeClient
        }
        let task: Task<ConvexRealtimeClient, Error>
        if let convexClientTask, convexClientTaskKey == realtimeKey {
            task = convexClientTask
        } else {
            Self.realtimeLogger.info("Creating Convex realtime client")
            task = Task.detached(priority: .utility) {
                let service = try ConvexRealtimeClient(configuration: activeConfiguration)
                await service.authenticate()
                return service
            }
            convexClientTask = task
            convexClientTaskKey = realtimeKey
        }
        let client: ConvexRealtimeClient
        do {
            client = try await task.value
        } catch {
            if convexClientTask == task {
                convexClientTask = nil
                convexClientTaskKey = nil
            }
            throw error
        }
        guard convexClientTask == task else {
            // Otro awaiter ya instaló este cliente, o fue descartado mientras conectaba.
            if let convexRealtimeClient, convexRealtimeKey == realtimeKey {
                return convexRealtimeClient
            }
            try Task.checkCancellation()
            return try await ensureConvexRealtimeClient()
        }
        convexClientTask = nil
        convexClientTaskKey = nil
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

    private func resyncRealtimeMessages(conversationId: String) async {
        guard !Self.isDemo, realtimeConversationId == conversationId,
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

        mergeMessagePage(loaded, conversationId: conversationId)
        if let latest = loaded.last {
            updateChannelPreview(with: latest)
            if visibleConversationId == conversationId {
                clearUnreadForActiveConversation(conversationId)
                markReadIfNeeded(conversationId: conversationId, messageId: latest.id)
            }
        }
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
            copy.replyCount = message.replyCount ?? current[index].replyCount
            current[index] = copy
        } else if let last = current.last, message.createdAt < last.createdAt {
            let insertIndex = current.lastIndex { $0.createdAt <= message.createdAt }
                .map { $0 + 1 } ?? 0
            current.insert(message, at: insertIndex)
        } else {
            current.append(message)
        }
        messages[message.conversationId] = current
        scheduleMessagesCacheWrite(conversationId: message.conversationId)
        prefetchImages(in: message)
    }

    /// Precalienta las fotos del mensaje al tamaño de burbuja para que
    /// aparezcan ya decodificadas al hacer scroll.
    private func prefetchImages(in message: CoreMessage) {
        guard let attachments = message.attachments, !attachments.isEmpty else { return }
        let scale = UITraitCollection.current.displayScale
        guard scale > 0 else { return }
        for attachment in attachments where attachment.isImage && !attachment.isGIF {
            guard let url = attachment.resolvedURL else { continue }
            Task(priority: .utility) {
                await RemoteImageLoader.shared.prefetch(url, targetSize: CGSize(width: 220, height: 180), scale: scale)
            }
        }
    }

    /// `isLatestPage`: la página es la más reciente del servidor, así que los
    /// mensajes en memoria dentro de su ventana de tiempo que no aparezcan en
    /// ella fueron borrados mientras la app no escuchaba.
    private func mergeMessagePage(_ page: [CoreMessage], conversationId: String, isLatestPage: Bool = true) {
        guard !page.isEmpty else { return }
        let current = messages[conversationId, default: []]
        var byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })

        if isLatestPage, let oldest = page.first?.createdAt {
            let pageIds = Set(page.map(\.id))
            for message in current where message.createdAt >= oldest
                && !pageIds.contains(message.id)
                && !message.id.hasPrefix(optimisticMessagePrefix)
                && message.localState == nil {
                byID[message.id] = nil
            }
        }

        if current.contains(where: { $0.id.hasPrefix(optimisticMessagePrefix) }) {
            for message in page where !message.id.hasPrefix(optimisticMessagePrefix) {
                for candidate in current where isOptimisticMessage(candidate, confirmedBy: message) {
                    byID[candidate.id] = nil
                }
            }
        }

        var newMessages: [CoreMessage] = []
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
                copy.replyCount = message.replyCount ?? existing.replyCount
                byID[message.id] = copy
            } else {
                byID[message.id] = message
                if isLatestPage {
                    newMessages.append(message)
                }
            }
        }
        // Solo las últimas (las visibles al abrir) para acotar el trabajo en la primera carga.
        for message in newMessages.suffix(10) {
            prefetchImages(in: message)
        }

        let merged = byID.values.sorted { $0.createdAt < $1.createdAt }
        if merged != current {
            messages[conversationId] = merged
            scheduleMessagesCacheWrite(conversationId: conversationId)
        }
        if isLatestPage {
            resolveNewMessagesDivider(conversationId: conversationId)
        }
        mergeThreadSummaries(from: page, conversationId: conversationId)
    }

    /// Primer no leído al abrir (índice cronológico `count - unread`) sobre la
    /// primera página fresca del servidor; sin separador si es propio.
    private func resolveNewMessagesDivider(conversationId: String) {
        guard let unread = pendingNewMessagesUnread.removeValue(forKey: conversationId) else { return }
        guard unread > 0, let list = messages[conversationId], !list.isEmpty else { return }
        let candidate = list[max(0, list.count - unread)]
        guard candidate.userId != configuration.userId else { return }
        newMessagesDividerId[conversationId] = candidate.id
    }

    private nonisolated static func threadSummaries(from page: [CoreMessage]) -> [CoreThreadSummary] {
        page
            .filter { $0.parentMessageId == nil && $0.deletedAt == nil && ($0.replyCount ?? 0) > 0 }
            .map {
                CoreThreadSummary(
                    root: $0,
                    replyCount: $0.replyCount ?? 0,
                    lastReplyAt: $0.createdAt,
                    lastReplyUserId: nil
                )
            }
    }

    /// Mantiene la lista de hilos del canal a partir de la página de mensajes
    /// ya descargada, sin una consulta extra al servidor.
    private func mergeThreadSummaries(from page: [CoreMessage], conversationId: String) {
        let current = channelThreads[conversationId] ?? []
        var byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for summary in Self.threadSummaries(from: page) {
            if var existing = byID[summary.id] {
                existing.root = summary.root
                existing.replyCount = max(existing.replyCount, summary.replyCount)
                byID[summary.id] = existing
            } else {
                byID[summary.id] = summary
            }
        }
        for message in page where message.parentMessageId == nil
            && (message.deletedAt != nil || (message.replyCount ?? 0) == 0) {
            byID[message.id] = nil
        }
        let next = byID.values.sorted { $0.lastReplyAt > $1.lastReplyAt }
        if next != current || channelThreads[conversationId] == nil {
            channelThreads[conversationId] = next
        }
        if hasOlderMessages[conversationId] == false {
            syncedThreadConversationIds.insert(conversationId)
        }
    }

    private func removeMessage(id: String, conversationId: String) {
        messages[conversationId, default: []].removeAll { $0.id == id }
        scheduleMessagesCacheWrite(conversationId: conversationId)
    }

    /// Al recargar desde el servidor se conservan los mensajes locales que
    /// siguen enviándose o fallaron, para no perder su texto ni el reintento.
    private func keepingLocalSends(_ current: [CoreMessage], in loaded: [CoreMessage]) -> [CoreMessage] {
        let local = current.filter { $0.localState != nil }
        guard !local.isEmpty else { return loaded }
        var kept: [CoreMessage] = []
        for candidate in local {
            // Si la página ya trae el mensaje confirmado, el local sobra (y no
            // debe reintentarse: crearía un duplicado en el servidor).
            if loaded.contains(where: { isOptimisticMessage(candidate, confirmedBy: $0) }) {
                if let pending = pendingSends.removeValue(forKey: candidate.id) {
                    PendingUploadStorage.remove(pending.attachments)
                }
            } else {
                kept.append(candidate)
            }
        }
        guard !kept.isEmpty else { return loaded }
        return (loaded + kept).sorted { $0.createdAt < $1.createdAt }
    }

    /// El servidor devuelve `metadata.payload.clientMessageId`; si lo omite,
    /// se usa autor + contenido en una ventana corta.
    private func isOptimisticMessage(_ candidate: CoreMessage, confirmedBy message: CoreMessage) -> Bool {
        guard candidate.id.hasPrefix(optimisticMessagePrefix) else { return false }
        if case .string(let clientMessageId)? = message.metadata?.payload?[Self.clientMessageIdKey] {
            return clientMessageId == candidate.id
        }
        let pendingWindow: TimeInterval = 30
        return candidate.userId == message.userId
            && candidate.content == message.content
            && abs(candidate.createdAt.timeIntervalSince(message.createdAt)) < pendingWindow
    }

    private func clearUnreadForActiveConversation(_ conversationId: String) {
        // El id de un DM es su conversationId; clearUnread cae en clearDMUnread.
        clearUnread(for: channels.first(where: { $0.conversationId == conversationId })?.id ?? conversationId)
    }

    private func updateChannelPreview(with message: CoreMessage) {
        guard message.parentMessageId == nil, message.deletedAt == nil else { return }
        if let index = directMessages.firstIndex(where: { $0.id == message.conversationId }) {
            if let currentDate = directMessages[index].lastMessageAt,
               currentDate > message.createdAt {
                return
            }
            if directMessages[index].lastMessageAt == message.createdAt,
               directMessages[index].lastMessageContent == message.content,
               directMessages[index].lastMessageUserId == message.userId {
                return
            }
            directMessages[index].lastMessageUserId = message.userId
            directMessages[index].lastMessageContent = message.content
            directMessages[index].lastMessageAt = message.createdAt
            directMessages.sort { first, second in
                (first.lastMessageAt ?? .distantPast) > (second.lastMessageAt ?? .distantPast)
            }
            scheduleCacheWrite()
            return
        }
        if let current = channelPreviews[message.conversationId],
           current.createdAt > message.createdAt || current == message {
            return
        }
        channelPreviews[message.conversationId] = message
        scheduleCacheWrite()
    }

    private func incrementReplyCount(for messageId: String, conversationId: String, by delta: Int = 1) {
        guard let index = messages[conversationId]?.firstIndex(where: { $0.id == messageId }) else { return }
        messages[conversationId]?[index].replyCount = max(0, (messages[conversationId]?[index].replyCount ?? 0) + delta)
    }

    /// Sustituye la respuesta optimista por la confirmada por el servidor.
    private func replaceThreadReply(id optimisticId: String, with reply: CoreMessage, parentMessageId: String) {
        var replies = threadReplies[parentMessageId, default: []]
        guard let index = replies.firstIndex(where: { $0.id == optimisticId }) else {
            if upsertThreadReply(reply, parentMessageId: parentMessageId) {
                incrementReplyCount(for: parentMessageId, conversationId: reply.conversationId)
            }
            return
        }
        // loadThread pudo traer ya la respuesta confirmada: se quita la
        // optimista en lugar de duplicarla.
        if let confirmedIndex = replies.firstIndex(where: { $0.id == reply.id }) {
            replies[confirmedIndex] = reply
            replies.remove(at: index)
        } else {
            replies[index] = reply
        }
        replies.sort { $0.createdAt < $1.createdAt }
        threadReplies[parentMessageId] = replies
    }

    /// Contraparte de `bumpThreadSummary` al descartar una respuesta local.
    private func decrementThreadSummary(parentMessageId: String, conversationId: String) {
        guard var summaries = channelThreads[conversationId],
              let index = summaries.firstIndex(where: { $0.id == parentMessageId }) else { return }
        summaries[index].replyCount = max(0, summaries[index].replyCount - 1)
        let rootReplies = messages[conversationId]?.first { $0.id == parentMessageId }?.replyCount ?? 0
        if summaries[index].replyCount == 0, rootReplies == 0 {
            summaries.remove(at: index)
        }
        channelThreads[conversationId] = summaries
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
        guard configuration.isUsable, !Self.isDemo else { return }

        let announcementText = "📊 \(trimmedQuestion)"
        var optimistic = makeOptimisticMessage(
            content: announcementText,
            channel: channel,
            conversationId: conversationId,
            parentMessageId: nil
        )
        optimistic.localState = .sending
        upsertMessage(optimistic)
        polls[optimistic.id] = CorePoll(
            id: "local-\(optimistic.id)",
            messageId: optimistic.id,
            question: trimmedQuestion,
            options: cleanOptions.enumerated().map { index, label in
                CorePollOption(id: "local-\(index)", label: label, sortOrder: index, votesCount: 0, votedByMe: false)
            }
        )

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
            markReadIfNeeded(conversationId: conversationId, messageId: message.id)
            await loadPolls(for: channel)
        } catch {
            polls[optimistic.id] = nil
            removeMessage(id: optimistic.id, conversationId: conversationId)
            lastError = error.localizedDescription
        }
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
              !Self.isDemo,
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
