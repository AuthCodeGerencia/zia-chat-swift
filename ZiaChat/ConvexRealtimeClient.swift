import Combine
@preconcurrency import ConvexMobile
import Foundation
import os

/// Entrega a ConvexMobile el access token vigente de Supabase. El núcleo en
/// Rust lo vuelve a pedir (`loginFromCache`) en cada reconexión del websocket,
/// así que tras un refresco de sesión las reconexiones ya usan el token nuevo.
final class CoreConvexTokenAuthProvider: AuthProvider, @unchecked Sendable {
    typealias T = String

    nonisolated private let token: OSAllocatedUnfairLock<String>

    nonisolated init(token: String) {
        self.token = OSAllocatedUnfairLock(initialState: token)
    }

    nonisolated var currentToken: String {
        token.withLock { $0 }
    }

    nonisolated func setToken(_ newToken: String) {
        token.withLock { $0 = newToken }
    }

    nonisolated func login(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> String {
        currentToken
    }

    nonisolated func logout() async throws {}

    nonisolated func loginFromCache(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> String {
        currentToken
    }

    nonisolated func extractIdToken(from authResult: String) -> String {
        authResult
    }
}

final class ConvexRealtimeClient: @unchecked Sendable {
    /// Un cliente por deployment para toda la vida del proceso. ConvexMobile
    /// 0.8.1 nunca libera un `ConvexClientWithAuth` autenticado: el callback de
    /// auth que guarda el núcleo en Rust retiene al propio cliente nativo. Crear
    /// uno nuevo en cada refresco de token o vuelta a primer plano dejaba vivo
    /// el anterior (runtime de tokio con sus hilos y un websocket reconectando
    /// con un token vencido) hasta agotar recursos y cerrar la app.
    nonisolated private static let clients = OSAllocatedUnfairLock<[String: ConvexRealtimeClient]>(initialState: [:])

    nonisolated(unsafe) private let client: ConvexClientWithAuth<String>
    nonisolated private let authProvider: CoreConvexTokenAuthProvider
    nonisolated private let authenticatedToken = OSAllocatedUnfairLock<String?>(initialState: nil)

    nonisolated static func shared(for configuration: CoreAppConfiguration) throws -> ConvexRealtimeClient {
        guard !configuration.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !configuration.userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              configuration.empresaId != nil else {
            throw ConvexCoreError.notConfigured
        }
        let rawURL = configuration.convexURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !rawURL.isEmpty, URL(string: rawURL) != nil else { throw ConvexCoreError.invalidURL }
        let token = configuration.accessToken
        return clients.withLock { clients in
            if let existing = clients[rawURL] {
                return existing
            }
            let created = ConvexRealtimeClient(deploymentURL: rawURL, token: token)
            clients[rawURL] = created
            return created
        }
    }

    nonisolated private init(deploymentURL: String, token: String) {
        authProvider = CoreConvexTokenAuthProvider(token: token)
        client = ConvexClientWithAuth(deploymentUrl: deploymentURL, authProvider: authProvider)
    }

    /// Autentica el websocket con `token`. Con el mismo token ya aceptado no
    /// hace nada; con uno nuevo re-autentica la conexión existente.
    nonisolated func authenticate(token: String) async {
        guard authenticatedToken.withLock({ $0 }) != token else { return }
        authProvider.setToken(token)
        guard case .success = await client.loginFromCache(),
              authProvider.currentToken == token else { return }
        authenticatedToken.withLock { $0 = token }
    }

    func watchWebSocketState() -> AnyPublisher<WebSocketState, Never> {
        client.watchWebSocketState()
    }

    func subscribeChannels(empresaId: Int, displayName: String) -> AnyPublisher<[CoreRealtimeChannelDTO], ClientError> {
        client.subscribe(
            to: "channels:list",
            with: [
                // Swift Int se codifica como Int64 de Convex; el backend valida
                // v.number() (float64), así que hay que mandar Double.
                "empresaId": Double(empresaId),
                "displayName": displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : displayName,
            ],
            yielding: [CoreRealtimeChannelDTO].self
        )
    }

    func subscribeDirectMessages(empresaId: Int, displayName: String) -> AnyPublisher<[CoreRealtimeDirectMessageDTO], ClientError> {
        client.subscribe(
            to: "dms:list",
            with: [
                "empresaId": Double(empresaId),
                "displayName": displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : displayName,
            ],
            yielding: [CoreRealtimeDirectMessageDTO].self
        )
    }

    func subscribeMessages(conversationId: String, limit: Int) -> AnyPublisher<CoreRealtimeMessagePageDTO, ClientError> {
        client.subscribe(
            to: "messages:list",
            with: [
                "conversationId": conversationId,
                "parentMessageId": nil,
                "limit": Double(limit),
            ],
            yielding: CoreRealtimeMessagePageDTO.self
        )
    }
}

struct CoreRealtimeChannelDTO: Decodable {
    var id: String
    var empresaId: Int
    var teamId: String?
    var name: String
    var slug: String
    var description: String?
    var visibility: CoreChannelVisibility
    var channelType: String
    var createdByUserId: String?
    var metadata: CoreChannelMetadata?
    var archivedAt: Date?
    var createdAt: Date?
    var updatedAt: Date?
    var conversationId: String?
    var unreadCount: Int?
    var mentionCount: Int?
    var currentUserIsMember: Bool?
    var lastMessage: CoreRealtimeLastMessageDTO?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CoreRealtimeCodingKey.self)
        id = try container.decodeString(keys: "_id", "id")
        empresaId = try container.decodeIfPresent(Int.self, forKey: "empresaId") ?? 0
        teamId = try container.decodeIfPresent(String.self, forKey: "teamId")
        name = try container.decodeIfPresent(String.self, forKey: "name") ?? ""
        slug = try container.decodeIfPresent(String.self, forKey: "slug") ?? ""
        description = try container.decodeIfPresent(String.self, forKey: "description")
        visibility = try container.decodeIfPresent(CoreChannelVisibility.self, forKey: "visibility") ?? .public
        channelType = try container.decodeIfPresent(String.self, forKey: "channelType") ?? "text"
        createdByUserId = try container.decodeIfPresent(String.self, forKey: "createdByUserId")
        metadata = try container.decodeIfPresent(CoreChannelMetadata.self, forKey: "metadata")
        archivedAt = try container.decodeDateIfPresent(forKey: "archivedAt")
        createdAt = try container.decodeDateIfPresent(forKey: "createdAt")
        updatedAt = try container.decodeDateIfPresent(forKey: "updatedAt")
        conversationId = try container.decodeIfPresent(String.self, forKey: "conversationId")
        unreadCount = try container.decodeIfPresent(Int.self, forKey: "unreadCount")
        mentionCount = try container.decodeIfPresent(Int.self, forKey: "mentionCount")
        currentUserIsMember = try container.decodeIfPresent(Bool.self, forKey: "currentUserIsMember")
        lastMessage = try container.decodeIfPresent(CoreRealtimeLastMessageDTO.self, forKey: "lastMessage")
    }

    var coreChannel: CoreChannel {
        var metadata = metadata ?? CoreChannelMetadata()
        metadata.channelType = metadata.channelType ?? channelType
        return CoreChannel(
            id: id,
            empresaId: empresaId,
            teamId: teamId,
            name: name,
            slug: slug,
            description: description,
            visibility: visibility,
            isArchived: archivedAt != nil,
            createdBy: createdByUserId,
            createdAt: createdAt,
            updatedAt: updatedAt,
            metadata: metadata,
            conversationId: conversationId,
            unreadCount: unreadCount ?? 0,
            mentionCount: mentionCount ?? 0,
            lastMessageId: lastMessage?.id,
            lastMessageContent: lastMessage?.content,
            lastMessageAt: lastMessage?.createdAt,
            lastMessageUserId: lastMessage?.userId,
            lastMessageAuthor: lastMessage?.author,
            currentUserIsMember: currentUserIsMember ?? false,
            visibleAsSuperAdmin: false
        )
    }
}

struct CoreRealtimeDirectMessageDTO: Decodable {
    var id: String
    var empresaId: Int
    var dmKey: String?
    var peerSupabaseUserId: String
    var peer: CoreUserLite?
    var unreadCount: Int?
    var mentionCount: Int?
    var lastMessage: CoreRealtimeLastMessageDTO?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CoreRealtimeCodingKey.self)
        id = try container.decodeString(keys: "_id", "id")
        empresaId = try container.decodeIfPresent(Int.self, forKey: "empresaId") ?? 0
        dmKey = try container.decodeIfPresent(String.self, forKey: "dmKey")
        peerSupabaseUserId = try container.decodeIfPresent(String.self, forKey: "peerSupabaseUserId") ?? ""
        peer = try container.decodeIfPresent(CoreUserLite.self, forKey: "peer")
        unreadCount = try container.decodeIfPresent(Int.self, forKey: "unreadCount")
        mentionCount = try container.decodeIfPresent(Int.self, forKey: "mentionCount")
        lastMessage = try container.decodeIfPresent(CoreRealtimeLastMessageDTO.self, forKey: "lastMessage")
    }

    var coreDirectMessage: CoreDirectMessage {
        CoreDirectMessage(
            id: id,
            empresaId: empresaId,
            dmKey: dmKey,
            peer: peer ?? CoreUserLite(id: peerSupabaseUserId, fullName: "Usuario Core"),
            unreadCount: unreadCount ?? 0,
            mentionCount: mentionCount ?? 0,
            lastMessageContent: lastMessage?.content,
            lastMessageAt: lastMessage?.createdAt,
            lastMessageUserId: lastMessage?.userId
        )
    }
}

struct CoreRealtimeLastMessageDTO: Decodable {
    var id: String
    var userId: String
    var content: String
    var parentMessageId: String?
    var createdAt: Date
    var author: CoreUserLite?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CoreRealtimeCodingKey.self)
        id = try container.decodeString(keys: "_id", "id")
        userId = try container.decodeString(keys: "userId", "supabaseUserId")
        content = try container.decodeIfPresent(String.self, forKey: "content") ?? ""
        parentMessageId = try container.decodeIfPresent(String.self, forKey: "parentMessageId")
        createdAt = try container.decodeDate(forKey: "createdAt")
        author = try container.decodeIfPresent(CoreUserLite.self, forKey: "author")
    }
}

struct CoreRealtimeMessagePageDTO: Decodable {
    var messages: [CoreRealtimeMessageDTO]
    var hasMore: Bool
}

struct CoreRealtimeMessageDTO: Decodable {
    var id: String
    var empresaId: Int
    var conversationId: String
    var channelId: String?
    var parentMessageId: String?
    var supabaseUserId: String
    var content: String
    var metadata: CoreMessageMetadata?
    var editedAt: Date?
    var deletedAt: Date?
    var createdAt: Date
    var author: CoreUserLite?
    var reactions: [CoreRealtimeReactionDTO]?
    var attachments: [CoreRealtimeAttachmentDTO]?
    var replyCount: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CoreRealtimeCodingKey.self)
        id = try container.decodeString(keys: "_id", "id")
        empresaId = try container.decodeIfPresent(Int.self, forKey: "empresaId") ?? 0
        conversationId = try container.decodeIfPresent(String.self, forKey: "conversationId") ?? ""
        channelId = try container.decodeIfPresent(String.self, forKey: "channelId")
        parentMessageId = try container.decodeIfPresent(String.self, forKey: "parentMessageId")
        supabaseUserId = try container.decodeString(keys: "supabaseUserId", "userId", fallback: "")
        content = try container.decodeIfPresent(String.self, forKey: "content") ?? ""
        metadata = try container.decodeIfPresent(CoreMessageMetadata.self, forKey: "metadata")
        editedAt = try container.decodeDateIfPresent(forKey: "editedAt")
        deletedAt = try container.decodeDateIfPresent(forKey: "deletedAt")
        createdAt = try container.decodeDate(forKey: "createdAt")
        author = try container.decodeIfPresent(CoreUserLite.self, forKey: "author")
        reactions = try container.decodeIfPresent([CoreRealtimeReactionDTO].self, forKey: "reactions")
        attachments = try container.decodeIfPresent([CoreRealtimeAttachmentDTO].self, forKey: "attachments")
        replyCount = try container.decodeIfPresent(Int.self, forKey: "replyCount")
    }

    var coreMessage: CoreMessage {
        var message = CoreMessage(
            id: id,
            empresaId: empresaId,
            conversationId: conversationId,
            channelId: channelId,
            parentMessageId: parentMessageId,
            userId: supabaseUserId,
            content: content,
            editedAt: editedAt,
            deletedAt: deletedAt,
            createdAt: createdAt,
            metadata: metadata
        )
        message.author = author
        message.reactions = reactions?.map(\.coreReaction)
        message.attachments = attachments?.map(\.coreAttachment)
        message.replyCount = replyCount
        return message
    }
}

struct CoreRealtimeReactionDTO: Decodable {
    var id: String
    var empresaId: Int
    var messageId: String
    var supabaseUserId: String
    var emoji: String
    var customReactionId: String?
    var createdAt: Date?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CoreRealtimeCodingKey.self)
        id = try container.decodeString(keys: "_id", "id")
        empresaId = try container.decodeIfPresent(Int.self, forKey: "empresaId") ?? 0
        messageId = try container.decodeIfPresent(String.self, forKey: "messageId") ?? ""
        supabaseUserId = try container.decodeString(keys: "supabaseUserId", "userId", fallback: "")
        emoji = try container.decodeIfPresent(String.self, forKey: "emoji") ?? "\u{1F44D}"
        customReactionId = try container.decodeIfPresent(String.self, forKey: "customReactionId")
        createdAt = try container.decodeDateIfPresent(forKey: "createdAt")
    }

    var coreReaction: CoreReaction {
        CoreReaction(
            id: id,
            empresaId: empresaId,
            messageId: messageId,
            userId: supabaseUserId,
            emoji: emoji,
            customReactionId: customReactionId,
            createdAt: createdAt
        )
    }
}

struct CoreRealtimeAttachmentDTO: Decodable {
    var id: String
    var empresaId: Int
    var messageId: String?
    var uploaderUserId: String
    var bucket: String?
    var path: String?
    var url: String?
    var fileName: String
    var mimeType: String?
    var sizeBytes: Int?
    var createdAt: Date?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CoreRealtimeCodingKey.self)
        id = try container.decodeString(keys: "_id", "id")
        empresaId = try container.decodeIfPresent(Int.self, forKey: "empresaId") ?? 0
        messageId = try container.decodeIfPresent(String.self, forKey: "messageId")
        uploaderUserId = try container.decodeString(keys: "uploaderUserId", "supabaseUserId", "userId", fallback: "")
        bucket = try container.decodeIfPresent(String.self, forKey: "bucket")
        path = try container.decodeIfPresent(String.self, forKey: "path")
        url = try container.decodeIfPresent(String.self, forKey: "url")
        fileName = try container.decodeIfPresent(String.self, forKey: "fileName") ?? "archivo"
        mimeType = try container.decodeIfPresent(String.self, forKey: "mimeType")
        sizeBytes = try container.decodeIfPresent(Int.self, forKey: "sizeBytes")
        createdAt = try container.decodeDateIfPresent(forKey: "createdAt")
    }

    var coreAttachment: CoreAttachment {
        CoreAttachment(
            id: id,
            empresaId: empresaId,
            messageId: messageId,
            ticketId: nil,
            uploaderId: uploaderUserId,
            bucket: bucket,
            path: path,
            url: url,
            fileName: fileName,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            createdAt: createdAt
        )
    }
}

struct CoreRealtimeCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

private extension KeyedDecodingContainer where K == CoreRealtimeCodingKey {
    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T? {
        try decodeIfPresent(type, forKey: CoreRealtimeCodingKey(stringValue: key)!)
    }

    func decodeString(keys: String..., fallback: String? = nil) throws -> String {
        for key in keys {
            if let value = try decodeIfPresent(String.self, forKey: key), !value.isEmpty {
                return value
            }
        }
        if let fallback {
            return fallback
        }
        throw DecodingError.keyNotFound(
            CoreRealtimeCodingKey(stringValue: keys.first ?? "id")!,
            DecodingError.Context(codingPath: codingPath, debugDescription: "Missing string value")
        )
    }

    func decodeDate(forKey key: String) throws -> Date {
        try decodeDateIfPresent(forKey: key) ?? Date()
    }

    func decodeDateIfPresent(forKey key: String) throws -> Date? {
        let codingKey = CoreRealtimeCodingKey(stringValue: key)!
        if let milliseconds = try? decodeIfPresent(Double.self, forKey: codingKey) {
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        if let string = try? decodeIfPresent(String.self, forKey: codingKey) {
            if let milliseconds = Double(string) {
                return Date(timeIntervalSince1970: milliseconds / 1000)
            }
            return ISO8601DateFormatter().date(from: string)
        }
        return nil
    }
}
