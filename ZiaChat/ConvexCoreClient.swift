import Foundation

enum ConvexCoreError: LocalizedError {
    case notConfigured
    case invalidURL
    case emptyResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Convex settings are incomplete."
        case .invalidURL:
            return "Invalid Convex deployment URL."
        case .emptyResponse:
            return "Convex returned an empty response."
        case .server(let message):
            return message
        }
    }
}

final class ConvexCoreClient {
    private let configuration: CoreAppConfiguration
    private let baseURL: URL
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(configuration: CoreAppConfiguration) throws {
        guard configuration.hasSessionContext else { throw ConvexCoreError.notConfigured }
        let rawURL = configuration.convexURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !rawURL.isEmpty, let url = URL(string: rawURL) else { throw ConvexCoreError.invalidURL }
        self.configuration = configuration
        self.baseURL = url
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
        decoder.dateDecodingStrategy = .custom(Self.decodeDate)
        encoder.dateEncodingStrategy = .millisecondsSince1970
    }

    func listChannels() async throws -> [CoreChannel] {
        guard let empresaId = configuration.empresaId else { return [] }
        let rows: [ConvexChannelDTO] = try await query(
            "channels:list",
            ["empresaId": empresaId, "displayName": configuration.displayName.convexNilIfBlank as Any]
        )
        return rows.map(\.coreChannel)
    }

    func listChannelsFast() async throws -> [CoreChannel] {
        try await listChannels()
    }

    func listChannelPreviews(conversationIds: [String]) async throws -> [String: CoreMessage] {
        var previews: [String: CoreMessage] = [:]
        for conversationId in conversationIds {
            let page: ConvexMessagePageDTO = try await query(
                "messages:list",
                ["conversationId": conversationId, "parentMessageId": NSNull(), "limit": 1]
            )
            if let message = page.messages.last?.coreMessage {
                previews[conversationId] = message
            }
        }
        return previews
    }

    func listDirectMessages() async throws -> [CoreDirectMessage] {
        guard let empresaId = configuration.empresaId else { return [] }
        let rows: [ConvexDirectMessageDTO] = try await query(
            "dms:list",
            ["empresaId": empresaId, "displayName": configuration.displayName.convexNilIfBlank as Any]
        )
        return rows.map(\.coreDirectMessage)
    }

    func listMentionableUsers() async throws -> [CoreUserLite] {
        guard let empresaId = configuration.empresaId else { return [] }
        return try await query("users:listByEmpresa", ["empresaId": empresaId])
    }

    func listInternalCompanies() async throws -> [CoreInternalCompany] {
        guard let empresaId = configuration.empresaId else { return [] }
        let rows: [ConvexBusinessUnitDTO] = try await query("businessUnits:list", ["empresaId": empresaId])
        return rows.compactMap(\.coreInternalCompany)
    }

    func listStickers() async throws -> [CoreSticker] {
        guard let empresaId = configuration.empresaId else { return [] }
        return try await query("stickers:list", ["empresaId": empresaId])
    }

    func uploadSticker(name: String, data: Data, fileName: String, mimeType: String) async throws -> CoreSticker {
        guard let empresaId = configuration.empresaId else { throw ConvexCoreError.notConfigured }
        let uploadURL: String = try await mutation("stickers:generateUploadUrl", [:])
        guard let url = URL(string: uploadURL) else { throw ConvexCoreError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ConvexCoreError.server(String(data: responseData, encoding: .utf8) ?? "No se pudo subir el sticker a Convex")
        }
        let payload = try decoder.decode(ConvexUploadResponse.self, from: responseData)
        return try await mutation(
            "stickers:create",
            ["empresaId": empresaId, "name": name, "storageId": payload.storageId]
        )
    }

    func listTyping(conversationId: String) async throws -> [ConvexTypingStatus] {
        try await query("typing:list", ["conversationId": conversationId])
    }

    func setTyping(conversationId: String, userName: String?, isTyping: Bool, parentMessageId: String? = nil) async throws {
        let _: String? = try await mutation(
            "typing:set",
            [
                "conversationId": conversationId,
                "userName": userName as Any,
                "isTyping": isTyping,
                "parentMessageId": parentMessageId as Any,
            ]
        )
    }

    func registerPushToken(token: String, deviceName: String) async throws {
        let _: String = try await mutation(
            "push:registerToken",
            ["token": token, "deviceName": deviceName]
        )
    }

    func unregisterPushTokens() async throws {
        let _: Int = try await mutation("push:unregisterCurrentUser", [:])
    }

    func sendTestPush() async throws -> ConvexPushTestResult {
        try await action("pushActions:testCurrentUser", [:])
    }

    func listChannelMembers(channelId: String) async throws -> [CoreUserLite] {
        let rows: [ConvexChannelMemberDTO] = try await query("channels:listMembers", ["channelId": channelId])
        return rows.compactMap(\.user)
    }

    func listChannelMemberRoles(channelId: String) async throws -> [CoreChannelMemberRole] {
        let rows: [ConvexChannelMemberDTO] = try await query("channels:listMembers", ["channelId": channelId])
        return rows.map { CoreChannelMemberRole(userId: $0.supabaseUserId, role: $0.role) }
    }

    func createChannel(
        name: String,
        description: String,
        visibility: CoreChannelVisibility,
        channelType: String = "text",
        metadata: CoreChannelMetadata? = nil
    ) async throws -> CoreChannel {
        guard let empresaId = configuration.empresaId else { throw ConvexCoreError.notConfigured }
        let result: ConvexCreateChannelResult = try await mutation(
            "channels:create",
            [
                "empresaId": empresaId,
                "name": name,
                "description": description.convexNilIfBlank as Any,
                "visibility": visibility.rawValue,
                "channelType": channelType,
                "metadata": try metadata?.convexJSONObject() as Any,
            ]
        )
        return CoreChannel(
            id: result.channelId,
            empresaId: empresaId,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            slug: Self.slugifyCoreName(name),
            description: description.convexNilIfBlank,
            visibility: visibility,
            createdBy: configuration.userId,
            metadata: metadata,
            conversationId: result.conversationId
        )
    }

    func updateChannel(
        channelId: String,
        name: String,
        description: String,
        visibility: CoreChannelVisibility,
        metadata: CoreChannelMetadata
    ) async throws {
        let _: String = try await mutation(
            "channels:update",
            [
                "channelId": channelId,
                "name": name,
                "description": description.convexNilIfBlank as Any,
                "visibility": visibility.rawValue,
                "metadata": try metadata.convexJSONObject(),
            ]
        )
    }

    func archiveChannel(_ channel: CoreChannel) async throws {
        let _: String = try await mutation("channels:archive", ["channelId": channel.id])
    }

    func syncChannelMembers(channelId: String, userIds: [String], adminIds: [String]) async throws {
        let _: String? = try await mutation(
            "channels:syncMembers",
            ["channelId": channelId, "userIds": userIds, "adminIds": adminIds]
        )
    }

    func createChannelInviteToken(channelId: String) async throws -> String {
        let result: ConvexInviteResult = try await mutation("channels:createInvite", ["channelId": channelId])
        return result.token
    }

    func startDirectMessage(peerUserId: String) async throws -> CoreDirectMessage {
        guard let empresaId = configuration.empresaId else { throw ConvexCoreError.notConfigured }
        let dm: ConvexDirectMessageDTO = try await mutation(
            "dms:create",
            ["empresaId": empresaId, "peerUserId": peerUserId]
        )
        return dm.coreDirectMessage
    }

    func listMessagePage(conversationId: String, before: Date? = nil, limit: Int = 21) async throws -> [CoreMessage] {
        var args: [String: Any] = [
            "conversationId": conversationId,
            "parentMessageId": NSNull(),
            "limit": limit,
        ]
        if let before {
            args["beforeCreatedAt"] = Int(before.timeIntervalSince1970 * 1_000)
        }
        let page: ConvexMessagePageDTO = try await query("messages:list", args)
        return page.messages.map(\.coreMessage)
    }

    func listMessages(conversationId: String) async throws -> [CoreMessage] {
        try await listMessagePage(conversationId: conversationId, limit: 50)
    }

    func enrichMessages(_ messages: [CoreMessage]) async throws -> [CoreMessage] {
        messages
    }

    func enrichRealtimeMessage(_ message: CoreMessage) async -> CoreMessage {
        (try? await getMessageById(message.id)) ?? message
    }

    func getMessageById(_ messageId: String) async throws -> CoreMessage? {
        let row: ConvexMessageDTO? = try await query("messages:getById", ["messageId": messageId])
        return row?.coreMessage
    }

    func listThreadReplies(conversationId: String, parentMessageId: String) async throws -> [CoreMessage] {
        let page: ConvexMessagePageDTO = try await query(
            "messages:list",
            ["conversationId": conversationId, "parentMessageId": parentMessageId, "limit": 100]
        )
        return page.messages.map(\.coreMessage)
    }

    func sendMessage(
        empresaId: Int,
        conversationId: String,
        channelId: String?,
        parentMessageId: String?,
        content: String,
        attachments: [CorePendingAttachment] = [],
        replyTo: CoreMessageReplyTo? = nil,
        metadata explicitMetadata: CoreMessageMetadata? = nil
    ) async throws -> CoreMessage {
        let uploaded = try await uploadAttachments(attachments)
        let metadata = try (explicitMetadata ?? CoreMessageMetadata(replyTo: replyTo)).nonEmptyConvexJSONObject()
        let row: ConvexMessageDTO = try await mutation(
            "messages:send",
            [
                "empresaId": empresaId,
                "conversationId": conversationId,
                "channelId": channelId as Any,
                "parentMessageId": parentMessageId as Any,
                "content": content,
                "metadata": metadata as Any,
                "attachments": uploaded.map(\.convexPayload),
            ]
        )
        return row.coreMessage
    }

    func searchChannelMessages(keyword: String, channelIds: [String]) async throws -> [CoreMessage] {
        let conversationIds = channelIds
        let rows: [ConvexMessageDTO] = try await query(
            "messages:search",
            ["conversationIds": conversationIds, "query": keyword, "limit": 60]
        )
        return rows.map(\.coreMessage)
    }

    func markRead(conversationId: String, lastReadMessageId: String?) async throws {
        let _: String = try await mutation(
            "messages:markRead",
            ["conversationId": conversationId, "lastReadMessageId": lastReadMessageId as Any]
        )
    }

    func listConversationReads(conversationId: String) async throws -> [CoreConversationRead] {
        []
    }

    func listMessagePins(conversationId: String) async throws -> [CoreMessagePin] {
        []
    }

    func pinMessage(_ message: CoreMessage) async throws -> CoreMessagePin {
        throw ConvexCoreError.server("Los pines todavia no estan disponibles en Convex para iOS.")
    }

    func unpinMessage(_ message: CoreMessage) async throws {}

    func markUnread(conversationId: String) async throws {
        let _: String = try await mutation("messages:markUnread", ["conversationId": conversationId])
    }

    func react(messageId: String, emoji: String) async throws -> CoreMessage {
        let result: ConvexReactionToggleDTO = try await mutation(
            "messages:toggleReaction",
            ["messageId": messageId, "emoji": emoji]
        )
        return result.message.coreMessage
    }

    func react(empresaId: Int, conversationId: String, messageId: String, emoji: String) async throws {
        _ = try await react(messageId: messageId, emoji: emoji)
    }

    func updateMessage(messageId: String, content: String) async throws -> CoreMessage {
        let row: ConvexMessageDTO = try await mutation(
            "messages:update",
            ["messageId": messageId, "content": content]
        )
        return row.coreMessage
    }

    func patchMessageMetadata(
        messageId: String,
        metadata: CoreMessageMetadata?,
        content: String? = nil,
        action: String? = nil
    ) async throws -> CoreMessage {
        var args: [String: Any] = [
            "messageId": messageId,
            "metadata": try metadata?.convexJSONObject() as Any,
            "action": action as Any,
        ]
        if let content { args["content"] = content }
        let row: ConvexMessageDTO = try await mutation("messages:patchMetadata", args)
        return row.coreMessage
    }

    func hideMessage(_ messageId: String) async throws -> CoreMessage {
        let row: ConvexMessageDTO = try await mutation("messages:hide", ["messageId": messageId])
        return row.coreMessage
    }

    func forwardMessage(_ source: CoreMessage, to channel: CoreChannel) async throws -> CoreMessage {
        guard let conversationId = channel.conversationId else { throw ConvexCoreError.emptyResponse }
        let attachments = (source.attachments ?? []).compactMap { attachment -> [String: Any]? in
            let path = attachment.path ?? attachment.url ?? ""
            guard !path.isEmpty else { return nil }
            return [
                "path": path,
                "storageId": NSNull(),
                "url": attachment.url as Any,
                "fileName": attachment.fileName,
                "mimeType": attachment.mimeType as Any,
                "sizeBytes": attachment.sizeBytes ?? 0,
                "bucket": attachment.bucket ?? "legacy",
            ]
        }
        let row: ConvexMessageDTO = try await mutation(
            "messages:send",
            [
                "empresaId": channel.empresaId,
                "conversationId": conversationId,
                "channelId": channel.isDirectMessage ? NSNull() : channel.id,
                "parentMessageId": NSNull(),
                "content": source.content,
                "metadata": try source.metadata?.convexJSONObject() as Any,
                "attachments": attachments,
            ]
        )
        return row.coreMessage
    }

    func fetchChannelMetadata(channelId: String) async throws -> CoreChannelMetadata? {
        guard let empresaId = configuration.empresaId else { return nil }
        let rows: [ConvexChannelDTO] = try await query(
            "channels:list",
            ["empresaId": empresaId, "displayName": configuration.displayName.convexNilIfBlank as Any]
        )
        return rows.first(where: { $0.id == channelId })?.metadata
    }

    func listChannelThreads(conversationId: String) async throws -> [CoreThreadSummary] {
        let page: ConvexMessagePageDTO = try await query(
            "messages:list",
            ["conversationId": conversationId, "parentMessageId": NSNull(), "limit": 100]
        )
        return page.messages
            .map(\.coreMessage)
            .filter { ($0.replyCount ?? 0) > 0 }
            .map {
                CoreThreadSummary(
                    root: $0,
                    replyCount: $0.replyCount ?? 0,
                    lastReplyAt: $0.createdAt,
                    lastReplyUserId: nil
                )
            }
            .sorted { $0.lastReplyAt > $1.lastReplyAt }
    }

    private func uploadAttachments(_ attachments: [CorePendingAttachment]) async throws -> [ConvexUploadedAttachment] {
        var uploaded: [ConvexUploadedAttachment] = []
        for attachment in attachments {
            let uploadURL: String = try await mutation("messages:generateUploadUrl", [:])
            guard let url = URL(string: uploadURL) else { throw ConvexCoreError.invalidURL }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(attachment.mimeType, forHTTPHeaderField: "Content-Type")
            request.httpBody = attachment.data
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw ConvexCoreError.server(String(data: data, encoding: .utf8) ?? "No se pudo subir el adjunto a Convex")
            }
            let payload = try decoder.decode(ConvexUploadResponse.self, from: data)
            uploaded.append(
                ConvexUploadedAttachment(
                    storageId: payload.storageId,
                    fileName: attachment.fileName,
                    mimeType: attachment.mimeType,
                    sizeBytes: attachment.sizeBytes
                )
            )
        }
        return uploaded
    }

    private func query<T: Decodable>(_ path: String, _ args: [String: Any]) async throws -> T {
        try await call(endpoint: "query", path: path, args: args)
    }

    private func mutation<T: Decodable>(_ path: String, _ args: [String: Any]) async throws -> T {
        try await call(endpoint: "mutation", path: path, args: args)
    }

    private func action<T: Decodable>(_ path: String, _ args: [String: Any]) async throws -> T {
        try await call(endpoint: "action", path: path, args: args)
    }

    private func call<T: Decodable>(endpoint: String, path: String, args: [String: Any]) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent("api").appendingPathComponent(endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ios-zia-chat", forHTTPHeaderField: "Convex-Client")
        request.setValue("Bearer \(configuration.accessToken)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "path": path,
            "format": "convex_encoded_json",
            "args": [Self.jsonReady(args)],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 560 else {
            throw ConvexCoreError.server(String(data: data, encoding: .utf8) ?? "Convex request failed")
        }
        let envelope = try decoder.decode(ConvexEnvelope.self, from: data)
        guard envelope.status == "success", let value = envelope.value else {
            throw ConvexCoreError.server(envelope.errorMessage ?? "Convex request failed")
        }
        let valueData = try Self.dataFromJSONValue(Self.jsonFromConvex(value))
        return try decoder.decode(T.self, from: valueData)
    }

    static func slugifyCoreName(_ value: String) -> String {
        let folded = value
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
            .lowercased()
        var result = ""
        var lastWasDash = false
        for character in folded {
            if character.isASCII, character.isLetter || character.isNumber {
                result.append(character)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        return String(result.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(64))
    }

    nonisolated private static func jsonReady(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        if let value = value as? NSNull { return value }
        if let value = value as? [String: Any] {
            return value.reduce(into: [String: Any]()) { $0[$1.key] = jsonReady($1.value) }
        }
        if let value = value as? [Any] {
            return value.map(jsonReady)
        }
        return value
    }

    nonisolated private static func jsonFromConvex(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            if object.count == 1, let encodedInteger = object["$integer"] as? String {
                return Int(encodedInteger) ?? encodedInteger
            }
            return object.reduce(into: [String: Any]()) { $0[$1.key] = jsonFromConvex($1.value) }
        }
        if let array = value as? [Any] {
            return array.map(jsonFromConvex)
        }
        return value
    }

    nonisolated private static func dataFromJSONValue(_ value: Any) throws -> Data {
        if JSONSerialization.isValidJSONObject(value) {
            return try JSONSerialization.data(withJSONObject: value)
        }
        if value is NSNull {
            return Data("null".utf8)
        }
        if let string = value as? String {
            return try JSONEncoder().encode(string)
        }
        if let bool = value as? Bool {
            return try JSONEncoder().encode(bool)
        }
        if let int = value as? Int {
            return try JSONEncoder().encode(int)
        }
        if let double = value as? Double {
            return try JSONEncoder().encode(double)
        }
        throw ConvexCoreError.server("Convex returned an unsupported response type.")
    }

    nonisolated private static func decodeDate(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        if let milliseconds = try? container.decode(Double.self) {
            return Date(timeIntervalSince1970: milliseconds / 1_000)
        }
        let value = try container.decode(String.self)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(value)")
    }
}

private struct ConvexEnvelope: Decodable {
    var status: String
    var value: Any?
    var errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case status
        case value
        case errorMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        errorMessage = try? container.decodeIfPresent(String.self, forKey: .errorMessage)
        if let decoded = try? container.decodeIfPresent(CoreJSONAny.self, forKey: .value) {
            value = decoded.value
        }
    }
}

private struct CoreJSONAny: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([CoreJSONAny].self) {
            value = array.map(\.value)
        } else {
            let object = try container.decode([String: CoreJSONAny].self)
            value = object.mapValues(\.value)
        }
    }
}

private struct ConvexCreateChannelResult: Decodable {
    var channelId: String
    var conversationId: String
}

private struct ConvexInviteResult: Decodable {
    var token: String
}

struct ConvexPushTestResult: Decodable {
    var sent: Int
    var attempted: Int
    var rejected: Int
    var lastRejection: ConvexPushTestRejection?
}

struct ConvexPushTestRejection: Decodable {
    var status: Int?
    var reason: String
}

private struct ConvexUploadResponse: Decodable {
    var storageId: String
}

struct ConvexTypingStatus: Decodable, Hashable {
    var userId: String
    var userName: String
    var isTyping: Bool
    var parentMessageId: String?
    var updatedAt: Date?
}

private struct ConvexUploadedAttachment {
    var storageId: String
    var fileName: String
    var mimeType: String
    var sizeBytes: Int

    var convexPayload: [String: Any] {
        [
            "path": storageId,
            "storageId": storageId,
            "url": NSNull(),
            "fileName": fileName,
            "mimeType": mimeType,
            "sizeBytes": sizeBytes,
            "bucket": "convex-storage",
        ]
    }
}

private struct ConvexChannelDTO: Decodable {
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

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case empresaId
        case teamId
        case name
        case slug
        case description
        case visibility
        case channelType
        case createdByUserId
        case metadata
        case archivedAt
        case createdAt
        case updatedAt
        case conversationId
        case unreadCount
        case mentionCount
        case currentUserIsMember
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
            currentUserIsMember: currentUserIsMember ?? false,
            visibleAsSuperAdmin: false
        )
    }
}

private struct ConvexDirectMessageDTO: Decodable {
    var id: String
    var empresaId: Int
    var dmKey: String?
    var peerSupabaseUserId: String
    var peer: CoreUserLite?
    var unreadCount: Int?
    var mentionCount: Int?
    var lastMessage: ConvexLastMessageDTO?

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

private struct ConvexLastMessageDTO: Decodable {
    var id: String
    var userId: String
    var content: String
    var parentMessageId: String?
    var createdAt: Date
}

private struct ConvexChannelMemberDTO: Decodable {
    var supabaseUserId: String
    var role: String?
    var user: CoreUserLite?
}

private struct ConvexBusinessUnitDTO: Decodable {
    var legacyId: Int?
    var name: String

    var coreInternalCompany: CoreInternalCompany? {
        guard let legacyId else { return nil }
        return CoreInternalCompany(id: legacyId, name: name)
    }
}

private struct ConvexMessagePageDTO: Decodable {
    var messages: [ConvexMessageDTO]
    var hasMore: Bool
}

private struct ConvexMessageDTO: Decodable {
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
    var reactions: [ConvexReactionDTO]?
    var attachments: [ConvexAttachmentDTO]?
    var replyCount: Int?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case empresaId
        case conversationId
        case channelId
        case parentMessageId
        case supabaseUserId
        case content
        case metadata
        case editedAt
        case deletedAt
        case createdAt
        case author
        case reactions
        case attachments
        case replyCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        empresaId = (try? container.decode(Int.self, forKey: .empresaId)) ?? 0
        conversationId = (try? container.decode(String.self, forKey: .conversationId)) ?? ""
        channelId = try? container.decodeIfPresent(String.self, forKey: .channelId)
        parentMessageId = try? container.decodeIfPresent(String.self, forKey: .parentMessageId)
        supabaseUserId = (try? container.decode(String.self, forKey: .supabaseUserId)) ?? ""
        content = (try? container.decode(String.self, forKey: .content)) ?? ""
        metadata = try? container.decodeIfPresent(CoreMessageMetadata.self, forKey: .metadata)
        editedAt = try? container.decodeIfPresent(Date.self, forKey: .editedAt)
        deletedAt = try? container.decodeIfPresent(Date.self, forKey: .deletedAt)
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
        author = try? container.decodeIfPresent(CoreUserLite.self, forKey: .author)
        reactions = (try? container.decodeIfPresent([ConvexReactionDTO].self, forKey: .reactions)) ?? []
        attachments = (try? container.decodeIfPresent([ConvexAttachmentDTO].self, forKey: .attachments)) ?? []
        replyCount = try? container.decodeIfPresent(Int.self, forKey: .replyCount)
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

private struct ConvexReactionDTO: Decodable {
    var id: String
    var empresaId: Int
    var messageId: String
    var supabaseUserId: String
    var emoji: String
    var customReactionId: String?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case empresaId
        case messageId
        case supabaseUserId
        case emoji
        case customReactionId
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        empresaId = (try? container.decode(Int.self, forKey: .empresaId)) ?? 0
        messageId = (try? container.decode(String.self, forKey: .messageId)) ?? ""
        supabaseUserId = (try? container.decode(String.self, forKey: .supabaseUserId)) ?? ""
        emoji = (try? container.decode(String.self, forKey: .emoji)).flatMap { $0.isEmpty ? nil : $0 } ?? "\u{1F44D}"
        customReactionId = try? container.decodeIfPresent(String.self, forKey: .customReactionId)
        createdAt = try? container.decodeIfPresent(Date.self, forKey: .createdAt)
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

private struct ConvexAttachmentDTO: Decodable {
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

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case empresaId
        case messageId
        case uploaderUserId
        case bucket
        case path
        case url
        case fileName
        case mimeType
        case sizeBytes
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        empresaId = (try? container.decode(Int.self, forKey: .empresaId)) ?? 0
        messageId = try? container.decodeIfPresent(String.self, forKey: .messageId)
        uploaderUserId = (try? container.decode(String.self, forKey: .uploaderUserId)) ?? ""
        bucket = try? container.decodeIfPresent(String.self, forKey: .bucket)
        path = try? container.decodeIfPresent(String.self, forKey: .path)
        url = try? container.decodeIfPresent(String.self, forKey: .url)
        fileName = (try? container.decode(String.self, forKey: .fileName)).flatMap { $0.isEmpty ? nil : $0 } ?? "archivo"
        mimeType = try? container.decodeIfPresent(String.self, forKey: .mimeType)
        sizeBytes = try? container.decodeIfPresent(Int.self, forKey: .sizeBytes)
        createdAt = try? container.decodeIfPresent(Date.self, forKey: .createdAt)
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

private struct ConvexReactionToggleDTO: Decodable {
    var removed: Bool
    var reaction: ConvexReactionDTO?
    var message: ConvexMessageDTO
}

private extension Encodable {
    func convexJSONObject() throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }
}

private extension CoreMessageMetadata {
    func nonEmptyConvexJSONObject() throws -> [String: Any]? {
        let object = try convexJSONObject()
        return object.values.allSatisfy { $0 is NSNull } ? nil : object
    }
}

private extension String {
    var convexNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
