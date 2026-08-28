import Combine
import ConvexMobile
import Foundation
import os

/// Estado de la bandeja de WhatsApp (portal de AuthCode) dentro de Zia.
///
/// Se enciende sola: con la sesión de Zia busca el perfil del portal por
/// correo y, si tiene permiso `chat.read`, deja disponible el chip "WhatsApp".
/// Todo lo demás (lista, hilo, permisos, estado de la sesión de WAHA) llega
/// por suscripciones en vivo al Convex del portal.
@MainActor
final class WhatsAppStore: ObservableObject {
    enum Availability: Equatable {
        /// Aún no se ha comprobado el perfil del portal.
        case unknown
        /// El correo no tiene perfil en AuthCode o no puede ver el chat.
        case unavailable
        case available
    }

    private static let logger = Logger(subsystem: "authcode.ZiaChat", category: "WhatsApp")
    private static let chatsPageSize = 40
    private static let messagesPageSize = 80
    private static let messagesMax = 300
    /// Número de la sesión WAHA `iobot` (Ana María - Soporte iOBOT).
    /// Si el portal re-vincula la sesión a otro número hay que actualizarlo.
    static let expectedWhatsAppPhone = "50498556975"
    static let expectedWhatsAppPhoneDisplay = "+504 9855-6975"
    static var wrongAccountMessage: String {
        "La sesión WAHA conectada no corresponde a \(expectedWhatsAppPhoneDisplay)."
    }

    @Published private(set) var availability: Availability = .unknown
    @Published private(set) var profile: WhatsAppProfile?
    @Published private(set) var caps: WhatsAppCaps = .none
    @Published private(set) var session: WhatsAppSessionStatus?
    @Published private(set) var unreadCount = 0

    @Published var filter: WhatsAppFilter = .todos {
        didSet { if filter != oldValue { resubscribeChats() } }
    }
    @Published var searchText = "" {
        didSet { if searchText != oldValue { scheduleSearch() } }
    }
    @Published private(set) var chats: [WhatsAppChat] = []
    @Published private(set) var hasLoadedChats = false
    @Published private(set) var chatsIsDone = true
    @Published private(set) var chatsError: String?

    @Published private(set) var activeChatId: String?
    @Published private(set) var activeChat: WhatsAppChat?
    @Published private(set) var hasLoadedActiveChat = false
    @Published private(set) var messages: [WhatsAppMessage] = []
    @Published private(set) var hasLoadedMessages = false
    @Published private(set) var threadError: String?
    @Published private(set) var agents: [WhatsAppAgent] = []
    @Published private(set) var companies: [WhatsAppCompany] = []
    @Published private(set) var participants: [WhatsAppParticipant] = []
    @Published private(set) var isSending = false

    private var client: WhatsAppConvexClient?
    private var configuredEmail: String?
    private var resolveTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var appliedSearch = ""
    private var chatsLimit = WhatsAppStore.chatsPageSize
    private var messagesLimit = WhatsAppStore.messagesPageSize

    private var capsSubscription: AnyCancellable?
    private var sessionSubscription: AnyCancellable?
    private var unreadSubscription: AnyCancellable?
    private var chatsSubscription: AnyCancellable?
    private var chatSubscription: AnyCancellable?
    private var messagesSubscription: AnyCancellable?
    private var agentsSubscription: AnyCancellable?
    private var companiesSubscription: AnyCancellable?
    private var participantsSubscription: AnyCancellable?

    /// Solo en simulador de desarrollo: `ZIA_WHATSAPP_EMAIL` (variable del
    /// esquema) fuerza el correo con el que se busca el perfil del portal.
    private static var debugEmailOverride: String? {
        #if DEBUG && targetEnvironment(simulator)
        let value = ProcessInfo.processInfo.environment["ZIA_WHATSAPP_EMAIL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value?.isEmpty == false ? value : nil
        #else
        return nil
        #endif
    }

    var isAvailable: Bool { availability == .available }
    var profileId: String? { profile?.id }
    var isExpectedWhatsAppAccount: Bool {
        guard let meId = session?.meId else { return true }
        let digits = meId.filter(\.isNumber)
        return digits.hasPrefix(Self.expectedWhatsAppPhone) || digits.hasSuffix(Self.expectedWhatsAppPhone)
    }

    // MARK: - Ciclo de vida

    /// Llamar cada vez que cambia la sesión de Zia. Resuelve el perfil del
    /// portal solo cuando cambia el correo; reabrir la app no repite nada.
    func configure(with configuration: CoreAppConfiguration) {
        guard configuration.isUsable, !CoreChannelsStore.isDemo,
              let email = Self.debugEmailOverride ?? configuration.sessionEmail else {
            reset()
            return
        }
        guard email != configuredEmail else { return }
        reset()
        configuredEmail = email

        let deploymentURL = CoreEnvironment.shared.authcodeConvexURL
        guard let client = try? WhatsAppConvexClient(deploymentURL: deploymentURL) else {
            Self.logger.error("AUTHCODE_CONVEX_URL inválida; bandeja de WhatsApp desactivada")
            availability = .unavailable
            return
        }
        self.client = client

        resolveTask = Task { [weak self] in
            await self?.resolveProfile(email: email, client: client)
        }
    }

    func reset() {
        resolveTask?.cancel()
        resolveTask = nil
        searchTask?.cancel()
        searchTask = nil
        capsSubscription = nil
        sessionSubscription = nil
        unreadSubscription = nil
        chatsSubscription = nil
        agentsSubscription = nil
        companiesSubscription = nil
        participantsSubscription = nil
        closeChat()
        client = nil
        configuredEmail = nil
        profile = nil
        caps = .none
        session = nil
        unreadCount = 0
        chats = []
        hasLoadedChats = false
        chatsIsDone = true
        chatsError = nil
        chatsLimit = Self.chatsPageSize
        appliedSearch = ""
        availability = .unknown
    }

    private func resolveProfile(email: String, client: WhatsAppConvexClient) async {
        var resolved: WhatsAppProfile?
        for attempt in 0..<3 {
            do {
                resolved = try await client.resolveProfile(email: email)
                break
            } catch {
                Self.logger.warning("No se pudo resolver el perfil de AuthCode (intento \(attempt + 1)): \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(for: .seconds(Double(attempt + 1) * 2))
            }
        }
        guard !Task.isCancelled, configuredEmail == email else { return }
        guard let resolved else {
            availability = .unavailable
            return
        }
        profile = resolved
        subscribeProfileScoped(profileId: resolved.id, client: client)
    }

    private func subscribeProfileScoped(profileId: String, client: WhatsAppConvexClient) {
        capsSubscription = client.subscribeCaps(profileId: profileId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                guard let self, case .failure(let error) = completion else { return }
                Self.logger.error("Permisos de WhatsApp: \(error.whatsAppMessage, privacy: .public)")
                self.availability = .unavailable
            } receiveValue: { [weak self] caps in
                guard let self else { return }
                self.caps = caps
                let wasAvailable = self.availability == .available
                self.availability = caps.read ? .available : .unavailable
                if caps.read, !wasAvailable {
                    self.subscribeInbox()
                }
            }
    }

    private func subscribeInbox() {
        guard let client, let profileId else { return }
        sessionSubscription = client.subscribeSession(profileId: profileId)
            .receive(on: DispatchQueue.main)
            .sink { _ in } receiveValue: { [weak self] status in
                guard let self else { return }
                self.session = status
                if !self.isExpectedWhatsAppAccount {
                    self.chats = []
                    self.chatsError = Self.wrongAccountMessage
                }
            }
        unreadSubscription = client.subscribeUnreadCount(profileId: profileId)
            .receive(on: DispatchQueue.main)
            .sink { _ in } receiveValue: { [weak self] count in
                self?.unreadCount = Int(count)
            }
        resubscribeChats()
    }

    // MARK: - Bandeja

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            let next = self.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard next != self.appliedSearch else { return }
            self.appliedSearch = next
            self.resubscribeChats()
        }
    }

    private func resubscribeChats(keepingLimit: Bool = false) {
        guard let client, let profileId, isAvailable else { return }
        if !keepingLimit {
            chatsLimit = Self.chatsPageSize
            hasLoadedChats = false
        }
        chatsError = nil
        chatsSubscription = client.subscribeChats(
            profileId: profileId,
            filter: filter,
            search: appliedSearch,
            numItems: chatsLimit
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] completion in
            guard let self, case .failure(let error) = completion else { return }
            self.chatsError = error.whatsAppMessage
            self.hasLoadedChats = true
        } receiveValue: { [weak self] page in
            guard let self else { return }
            guard self.isExpectedWhatsAppAccount else {
                self.chats = []
                self.chatsError = Self.wrongAccountMessage
                self.hasLoadedChats = true
                return
            }
            // La sesión iobot ahora es la línea de soporte directa: la bandeja
            // muestra grupos y chats privados, igual que el portal.
            self.chats = page.page
            self.chatsIsDone = page.isDone
            self.hasLoadedChats = true
        }
    }

    func loadMoreChats() {
        guard hasLoadedChats, !chatsIsDone else { return }
        chatsLimit += Self.chatsPageSize
        resubscribeChats(keepingLimit: true)
    }

    func retryChats() {
        resubscribeChats()
    }

    // MARK: - Hilo

    func openChat(_ chatId: String) {
        guard let client, let profileId else { return }
        guard activeChatId != chatId else { return }
        closeChat()
        activeChatId = chatId
        messagesLimit = Self.messagesPageSize

        chatSubscription = client.subscribeChat(profileId: profileId, chatId: chatId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                guard let self, case .failure(let error) = completion else { return }
                self.threadError = error.whatsAppMessage
                self.hasLoadedActiveChat = true
            } receiveValue: { [weak self] chat in
                guard let self else { return }
                self.activeChat = chat
                self.hasLoadedActiveChat = true
            }
        subscribeMessages()

        if caps.assign {
            agentsSubscription = client.subscribeAgents(profileId: profileId)
                .receive(on: DispatchQueue.main)
                .sink { _ in } receiveValue: { [weak self] agents in self?.agents = agents }
            companiesSubscription = client.subscribeCompanies(profileId: profileId)
                .receive(on: DispatchQueue.main)
                .sink { _ in } receiveValue: { [weak self] companies in self?.companies = companies }
        }
        participantsSubscription = client.subscribeParticipants(profileId: profileId, chatId: chatId)
            .receive(on: DispatchQueue.main)
            .sink { _ in } receiveValue: { [weak self] participants in self?.participants = participants }

        Task { await markRead(chatId: chatId) }
    }

    private func subscribeMessages() {
        guard let client, let profileId, let chatId = activeChatId else { return }
        messagesSubscription = client.subscribeMessages(profileId: profileId, chatId: chatId, limit: messagesLimit)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                guard let self, case .failure(let error) = completion else { return }
                self.threadError = error.whatsAppMessage
                self.hasLoadedMessages = true
            } receiveValue: { [weak self] messages in
                guard let self else { return }
                self.messages = messages
                self.hasLoadedMessages = true
                // Un mensaje nuevo mientras el hilo está abierto se marca leído
                // al instante, como en la bandeja del portal.
                if let last = messages.last, !last.fromMe, self.activeChat?.unreadCount ?? 0 > 0 {
                    Task { await self.markRead(chatId: chatId) }
                }
            }
    }

    var canLoadOlderMessages: Bool {
        hasLoadedMessages && messages.count >= messagesLimit && messagesLimit < Self.messagesMax
    }

    func loadOlderMessages() {
        guard canLoadOlderMessages else { return }
        messagesLimit = min(messagesLimit + Self.messagesPageSize, Self.messagesMax)
        subscribeMessages()
    }

    func closeChat() {
        chatSubscription = nil
        messagesSubscription = nil
        agentsSubscription = nil
        companiesSubscription = nil
        participantsSubscription = nil
        activeChatId = nil
        activeChat = nil
        hasLoadedActiveChat = false
        messages = []
        participants = []
        hasLoadedMessages = false
        threadError = nil
        messagesLimit = Self.messagesPageSize
    }

    func chat(withId chatId: String) -> WhatsAppChat? {
        if activeChatId == chatId, let activeChat { return activeChat }
        return chats.first { $0.chatId == chatId }
    }

    // MARK: - Acciones

    private func markRead(chatId: String) async {
        guard let client, let profileId else { return }
        try? await client.markRead(profileId: profileId, chatId: chatId)
    }

    func sendText(_ body: String, quoting quoted: WhatsAppMessage?, asNote: Bool) async throws {
        guard let client, let profileId, let chatId = activeChatId else { return }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        if asNote {
            try await client.addNote(profileId: profileId, chatId: chatId, body: text)
        } else {
            try await client.sendText(
                profileId: profileId,
                chatId: chatId,
                body: text,
                quotedMessageId: quoted?.waMessageId
            )
        }
    }

    func sendAttachments(_ attachments: [CorePendingAttachment], caption: String, quoting quoted: WhatsAppMessage? = nil) async throws {
        guard let client, let profileId, let chatId = activeChatId, !attachments.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        for (index, attachment) in attachments.enumerated() {
            let storageId = try await client.upload(attachment, profileId: profileId)
            try await client.sendFile(
                profileId: profileId,
                chatId: chatId,
                storageId: storageId,
                filename: attachment.fileName,
                mimetype: attachment.mimeType,
                // El texto del compositor acompaña solo al primer archivo.
                caption: index == 0 ? trimmedCaption : nil,
                quotedMessageId: index == 0 ? quoted?.waMessageId : nil
            )
        }
    }

    func retry(_ message: WhatsAppMessage) async throws {
        guard let client, let profileId else { return }
        try await client.retrySend(profileId: profileId, messageId: message.id)
    }

    func assign(to agentId: String?) async throws {
        guard let client, let profileId, let chatId = activeChatId else { return }
        try await client.assign(profileId: profileId, chatId: chatId, assignedTo: agentId)
    }

    func assign(to agentIds: [String]) async throws {
        guard let client, let profileId, let chatId = activeChatId else { return }
        try await client.assignAgents(profileId: profileId, chatId: chatId, assignedToIds: agentIds)
    }

    func setState(_ state: WhatsAppChatState) async throws {
        guard let client, let profileId, let chatId = activeChatId else { return }
        try await client.setState(profileId: profileId, chatId: chatId, state: state)
    }

    func setMuted(_ muted: Bool) async throws {
        guard let client, let profileId, let chatId = activeChatId else { return }
        try await client.mute(profileId: profileId, chatId: chatId, muted: muted)
    }

    func setBusinessUnit(_ unit: WhatsAppBusinessUnit?) async throws {
        guard let client, let profileId, let chatId = activeChatId else { return }
        try await client.classify(profileId: profileId, chatId: chatId, businessUnit: .some(unit?.rawValue))
    }

    /// Vincula una empresa del directorio interno del portal.
    func linkCompany(_ company: WhatsAppCompany) async throws {
        guard let client, let profileId, let chatId = activeChatId else { return }
        try await client.classify(
            profileId: profileId,
            chatId: chatId,
            companyId: .some(company.id),
            clientName: .some(nil)
        )
    }

    /// Cliente que no está en el directorio: se guarda como texto libre.
    func setClientName(_ name: String) async throws {
        guard let client, let profileId, let chatId = activeChatId else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let match = companies.first(where: { $0.nombre.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            try await linkCompany(match)
            return
        }
        try await client.classify(
            profileId: profileId,
            chatId: chatId,
            companyId: .some(nil),
            clientName: .some(trimmed)
        )
    }

    func clearClient() async throws {
        guard let client, let profileId, let chatId = activeChatId else { return }
        try await client.classify(profileId: profileId, chatId: chatId, companyId: .some(nil), clientName: .some(nil))
    }
}
