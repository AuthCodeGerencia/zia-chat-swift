import Foundation
import Supabase

enum SupabaseCoreError: LocalizedError {
    case notConfigured
    case invalidURL
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Core settings are incomplete."
        case .invalidURL:
            return "Invalid Supabase project URL."
        case .emptyResponse:
            return "Supabase returned an empty response."
        }
    }
}

final class SupabaseCoreClient {
    private static let attachmentsBucket = "core-attachments"
    private let configuration: CoreAppConfiguration
    private let client: SupabaseClient

    init(configuration: CoreAppConfiguration) throws {
        guard configuration.isUsable else { throw SupabaseCoreError.notConfigured }
        guard let url = URL(string: configuration.supabaseURL) else {
            throw SupabaseCoreError.invalidURL
        }

        self.configuration = configuration

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(Self.decodeDate)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        client = SupabaseClient(
            supabaseURL: url,
            supabaseKey: configuration.anonKey,
            options: SupabaseClientOptions(
                db: .init(
                    schema: "public",
                    encoder: encoder,
                    decoder: decoder
                ),
                auth: .init(
                    accessToken: {
                        configuration.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                )
            )
        )
    }

    func listChannels() async throws -> [CoreChannel] {
        let channels: [CoreChannel] = try await client
            .rpc(
                "core_list_user_channels",
                params: ListChannelsParams(pDisplayName: configuration.displayName.nilIfBlank)
            )
            .execute()
            .value

        guard let empresaId = configuration.empresaId else { return channels }
        return channels.filter { $0.empresaId == empresaId }
    }

    func listChannelsFast() async throws -> [CoreChannel] {
        let channels: [CoreChannel] = try await client
            .rpc("core_list_zia_channels")
            .execute()
            .value

        guard let empresaId = configuration.empresaId else { return channels }
        return channels.filter { $0.empresaId == empresaId }
    }

    func createChannel(name: String, description: String, visibility: CoreChannelVisibility) async throws -> CoreChannel {
        let rows: [CoreChannelCreateResponse] = try await client
            .rpc(
                "core_create_channel",
                params: CreateChannelParams(
                    pName: name,
                    pDescription: description.nilIfBlank,
                    pVisibility: visibility.rawValue
                )
            )
            .execute()
            .value

        guard let row = rows.first else { throw SupabaseCoreError.emptyResponse }
        return CoreChannel(
            id: row.id,
            empresaId: row.empresaId,
            name: row.name,
            slug: row.slug,
            description: row.description,
            visibility: row.visibility,
            conversationId: row.conversationId
        )
    }

    func searchChannelMessages(keyword: String, channelIds: [String]) async throws -> [CoreMessage] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !channelIds.isEmpty, let empresaId = configuration.empresaId else {
            return []
        }

        let pattern = "%\(Self.escapeIlike(trimmed))%"
        let loaded: [CoreMessage] = try await client
            .from("core_messages")
            .select("id,empresa_id,conversation_id,channel_id,content,created_at")
            .eq("empresa_id", value: empresaId)
            .in("channel_id", values: channelIds)
            .is("deleted_at", value: nil)
            .ilike("content", pattern: pattern)
            .order("created_at", ascending: false)
            .limit(150)
            .execute()
            .value

        return loaded
    }

    func listMessages(conversationId: String) async throws -> [CoreMessage] {
        let displayOrder = try await listMessagePage(conversationId: conversationId)
        return try await enrichMessages(displayOrder)
    }

    func listMessagePage(
        conversationId: String,
        before: Date? = nil,
        limit: Int = 21
    ) async throws -> [CoreMessage] {
        let loaded: [CoreMessage]
        if let before {
            loaded = try await messagePageQuery(
                conversationId: conversationId,
                before: before,
                limit: limit
            )
        } else {
            do {
                loaded = try await client
                    .rpc(
                        "core_list_zia_messages",
                        params: ListMessagesParams(
                            conversationId: conversationId,
                            limit: limit
                        )
                    )
                    .execute()
                    .value
            } catch {
                loaded = try await messagePageQuery(
                    conversationId: conversationId,
                    before: nil,
                    limit: limit
                )
            }
        }

        return Array(loaded.reversed())
    }

    private func messagePageQuery(
        conversationId: String,
        before: Date?,
        limit: Int
    ) async throws -> [CoreMessage] {
        var query = client
            .from("core_messages")
            .select(Self.messageColumns)
            .eq("conversation_id", value: conversationId)
            .is("deleted_at", value: nil)
            .is("parent_message_id", value: nil)

        if let before {
            query = query.lt("created_at", value: Self.iso8601String(from: before))
        }

        return try await query
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
            .value
    }

    func enrichMessages(_ messages: [CoreMessage]) async throws -> [CoreMessage] {
        try await enrich(messages)
    }

    func enrichRealtimeMessage(_ message: CoreMessage) async -> CoreMessage {
        let needsAttachment = message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        for attempt in 0..<6 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(250 * attempt))
            }

            guard let enriched = try? await enrich([message]).first else { continue }
            if !needsAttachment || enriched.attachments?.isEmpty == false {
                return enriched
            }
        }

        return message
    }

    func ensureChannelMembership(channelId: String, conversationId: String) async throws {
        try await ensureMembership(conversationId: conversationId, channelId: channelId)
    }

    func sendMessage(
        empresaId: Int,
        conversationId: String,
        channelId: String?,
        parentMessageId: String?,
        content: String,
        attachments: [CorePendingAttachment] = []
    ) async throws -> CoreMessage {
        try await ensureMembership(conversationId: conversationId, channelId: channelId)

        let row = CoreMessageInsert(
            empresaId: empresaId,
            conversationId: conversationId,
            channelId: channelId,
            parentMessageId: parentMessageId,
            userId: configuration.userId,
            content: content
        )

        let inserted: [CoreMessage] = try await client
            .from("core_messages")
            .insert(row)
            .select()
            .execute()
            .value

        guard let message = inserted.first else { throw SupabaseCoreError.emptyResponse }
        guard !attachments.isEmpty else { return message }

        do {
            let rows = try await uploadAttachments(
                attachments,
                empresaId: empresaId,
                conversationId: conversationId,
                messageId: message.id
            )
            let saved: [CoreAttachment] = try await client
                .from("core_attachments")
                .insert(rows)
                .select()
                .execute()
                .value

            var enrichedMessage = message
            enrichedMessage.attachments = try await signAttachments(saved)
            return enrichedMessage
        } catch {
            _ = try? await client
                .from("core_messages")
                .update(["deleted_at": ISO8601DateFormatter().string(from: Date())])
                .eq("id", value: message.id)
                .execute()
            throw error
        }
    }

    func react(empresaId: Int, conversationId: String, messageId: String, emoji: String) async throws {
        let existing: [ReactionID] = try await client
            .from("core_reactions")
            .select("id")
            .eq("message_id", value: messageId)
            .eq("user_id", value: configuration.userId)
            .eq("emoji", value: emoji)
            .limit(1)
            .execute()
            .value

        if let id = existing.first?.id {
            try await client
                .from("core_reactions")
                .delete()
                .eq("id", value: id)
                .execute()
            return
        }

        let row = ReactionInsert(
            empresaId: empresaId,
            messageId: messageId,
            userId: configuration.userId,
            emoji: emoji
        )

        try await client
            .from("core_reactions")
            .insert(row)
            .execute()
    }

    func markRead(conversationId: String, lastReadMessageId: String?) async throws {
        let row = MessageReadUpsert(
            conversationId: conversationId,
            userId: configuration.userId,
            lastReadMessageId: lastReadMessageId,
            lastReadAt: Date()
        )

        try await client
            .from("core_message_reads")
            .upsert(row, onConflict: "conversation_id,user_id")
            .execute()
    }

    func registerPushToken(token: String, deviceName: String) async throws {
        guard let empresaId = configuration.empresaId else {
            throw SupabaseCoreError.notConfigured
        }

        let row = PushTokenUpsert(
            empresaId: empresaId,
            userId: configuration.userId,
            platform: "zia_chat_apns",
            token: token,
            deviceName: deviceName,
            lastSeenAt: Date()
        )

        try await client
            .from("core_push_tokens")
            .upsert(row, onConflict: "token")
            .execute()
    }

    private func ensureMembership(conversationId: String, channelId: String?) async throws {
        let conversationMember = ConversationMemberUpsert(
            conversationId: conversationId,
            userId: configuration.userId,
            role: "member"
        )

        try await client
            .from("core_conversation_members")
            .upsert(
                conversationMember,
                onConflict: "conversation_id,user_id",
                ignoreDuplicates: true
            )
            .execute()

        guard let channelId else { return }

        let channelMember = ChannelMemberUpsert(
            channelId: channelId,
            userId: configuration.userId,
            role: "member"
        )

        try await client
            .from("core_channel_members")
            .upsert(
                channelMember,
                onConflict: "channel_id,user_id",
                ignoreDuplicates: true
            )
            .execute()
    }

    private func enrich(_ messages: [CoreMessage]) async throws -> [CoreMessage] {
        guard !messages.isEmpty else { return [] }

        async let usersTask = fetchUsers(ids: Array(Set(messages.map(\.userId))))
        async let reactionsTask = fetchReactions(messageIds: messages.map(\.id))
        async let attachmentsTask = fetchAttachments(messageIds: messages.map(\.id))
        async let parentsTask = fetchParents(ids: messages.compactMap(\.parentMessageId))

        let userMap = (try? await usersTask) ?? [:]
        let reactionMap = Dictionary(grouping: ((try? await reactionsTask) ?? []), by: \.messageId)
        let attachmentMap = Dictionary(grouping: ((try? await attachmentsTask) ?? []), by: { $0.messageId ?? "" })
        let parentMap = ((try? await parentsTask) ?? []).reduce(into: [String: CoreMessageQuote]()) {
            $0[$1.id] = $1
        }

        return messages.map { message in
            var copy = message
            copy.author = userMap[message.userId]
            copy.reactions = reactionMap[message.id] ?? []
            copy.attachments = attachmentMap[message.id] ?? []
            if let parentId = message.parentMessageId {
                copy.parent = parentMap[parentId]
            }
            return copy
        }
    }

    private func fetchUsers(ids: [String]) async throws -> [String: CoreUserLite] {
        guard !ids.isEmpty else { return [:] }

        let users: [CoreUserLite] = try await client
            .from("profiles")
            .select("id,full_name,avatar_url,rol_id")
            .in("id", values: ids)
            .execute()
            .value

        return users.reduce(into: [String: CoreUserLite]()) {
            $0[$1.id] = normalizedAvatarUser($1)
        }
    }

    private func fetchReactions(messageIds: [String]) async throws -> [CoreReaction] {
        guard !messageIds.isEmpty else { return [] }

        return try await client
            .from("core_reactions")
            .select()
            .in("message_id", values: messageIds)
            .execute()
            .value
    }

    private func fetchAttachments(messageIds: [String]) async throws -> [CoreAttachment] {
        guard !messageIds.isEmpty else { return [] }

        let attachments: [CoreAttachment] = try await client
            .from("core_attachments")
            .select()
            .in("message_id", values: messageIds)
            .execute()
            .value
        return try await signAttachments(attachments)
    }

    private func uploadAttachments(
        _ attachments: [CorePendingAttachment],
        empresaId: Int,
        conversationId: String,
        messageId: String
    ) async throws -> [CoreAttachmentInsert] {
        var rows: [CoreAttachmentInsert] = []
        for (index, attachment) in attachments.enumerated() {
            let safeName = Self.safeFileName(attachment.fileName)
            let path = "core-attachments/\(empresaId)/\(conversationId)/\(messageId)/\(Int(Date().timeIntervalSince1970 * 1_000))-\(index)-\(safeName)"
            try await client.storage
                .from(Self.attachmentsBucket)
                .upload(
                    path,
                    data: attachment.data,
                    options: FileOptions(contentType: attachment.mimeType)
                )
            rows.append(
                CoreAttachmentInsert(
                    empresaId: empresaId,
                    messageId: messageId,
                    uploaderId: configuration.userId,
                    bucket: Self.attachmentsBucket,
                    path: path,
                    fileName: attachment.fileName,
                    mimeType: attachment.mimeType,
                    sizeBytes: attachment.sizeBytes
                )
            )
        }
        return rows
    }

    private func signAttachments(_ attachments: [CoreAttachment]) async throws -> [CoreAttachment] {
        var result: [CoreAttachment] = []
        for attachment in attachments {
            var copy = attachment
            if copy.url?.nilIfBlank == nil, let path = copy.path?.nilIfBlank {
                let bucket = copy.bucket?.nilIfBlank ?? Self.attachmentsBucket
                copy.url = try await client.storage
                    .from(bucket)
                    .createSignedURL(path: path, expiresIn: 3_600)
                    .absoluteString
            }
            result.append(copy)
        }
        return result
    }

    private func fetchParents(ids: [String]) async throws -> [CoreMessageQuote] {
        guard !ids.isEmpty else { return [] }

        let parents: [CoreMessage] = try await client
            .from("core_messages")
            .select(Self.messageColumns)
            .in("id", values: ids)
            .execute()
            .value

        let users = try await fetchUsers(ids: Array(Set(parents.map(\.userId))))

        return parents.map {
            CoreMessageQuote(
                id: $0.id,
                content: $0.content,
                authorName: users[$0.userId]?.displayName ?? "Unknown"
            )
        }
    }

    private func normalizedAvatarUser(_ user: CoreUserLite) -> CoreUserLite {
        guard let avatar = user.avatarURLString, !avatar.isEmpty, !avatar.lowercased().hasPrefix("http") else {
            return user
        }

        var copy = user
        let base = configuration.supabaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let clean = avatar
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "avatars/users/", with: "")
            .replacingOccurrences(of: "users/", with: "")
        copy.avatarURLString = "\(base)/storage/v1/object/public/avatars/users/\(clean)"
        return copy
    }

    nonisolated private static func escapeIlike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    nonisolated private static func safeFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let result = String(scalars)
        return result.isEmpty ? "image" : result
    }

    nonisolated private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    nonisolated private static let messageColumns = """
        id,empresa_id,conversation_id,channel_id,parent_message_id,user_id,content,edited_at,deleted_at,created_at
        """

    nonisolated private static func decodeDate(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(value)")
    }
}

private struct ListMessagesParams: Encodable {
    var conversationId: String
    var limit: Int

    enum CodingKeys: String, CodingKey {
        case conversationId = "p_conversation_id"
        case limit = "p_limit"
    }
}

private struct ListChannelsParams: Encodable {
    var pDisplayName: String?

    enum CodingKeys: String, CodingKey {
        case pDisplayName = "p_display_name"
    }
}

private struct CreateChannelParams: Encodable {
    var pName: String
    var pDescription: String?
    var pVisibility: String

    enum CodingKeys: String, CodingKey {
        case pName = "p_name"
        case pDescription = "p_description"
        case pVisibility = "p_visibility"
    }
}

private struct CoreChannelCreateResponse: Codable {
    var id: String
    var empresaId: Int
    var name: String
    var slug: String
    var description: String?
    var visibility: CoreChannelVisibility
    var conversationId: String

    enum CodingKeys: String, CodingKey {
        case id
        case empresaId = "empresa_id"
        case name
        case slug
        case description
        case visibility
        case conversationId = "conversation_id"
    }
}

private struct CoreMessageInsert: Encodable {
    var empresaId: Int
    var conversationId: String
    var channelId: String?
    var parentMessageId: String?
    var userId: String
    var content: String

    enum CodingKeys: String, CodingKey {
        case empresaId = "empresa_id"
        case conversationId = "conversation_id"
        case channelId = "channel_id"
        case parentMessageId = "parent_message_id"
        case userId = "user_id"
        case content
    }
}

private struct CoreAttachmentInsert: Encodable {
    var empresaId: Int
    var messageId: String
    var uploaderId: String
    var bucket: String
    var path: String
    var fileName: String
    var mimeType: String
    var sizeBytes: Int

    enum CodingKeys: String, CodingKey {
        case empresaId = "empresa_id"
        case messageId = "message_id"
        case uploaderId = "uploader_id"
        case bucket
        case path
        case fileName = "file_name"
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
    }
}

private struct ReactionInsert: Encodable {
    var empresaId: Int
    var messageId: String
    var userId: String
    var emoji: String

    enum CodingKeys: String, CodingKey {
        case empresaId = "empresa_id"
        case messageId = "message_id"
        case userId = "user_id"
        case emoji
    }
}

private struct ReactionID: Decodable {
    var id: String
}

private struct ConversationMemberUpsert: Encodable {
    var conversationId: String
    var userId: String
    var role: String

    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case userId = "user_id"
        case role
    }
}

private struct ChannelMemberUpsert: Encodable {
    var channelId: String
    var userId: String
    var role: String

    enum CodingKeys: String, CodingKey {
        case channelId = "channel_id"
        case userId = "user_id"
        case role
    }
}

private struct MessageReadUpsert: Encodable {
    var conversationId: String
    var userId: String
    var lastReadMessageId: String?
    var lastReadAt: Date

    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case userId = "user_id"
        case lastReadMessageId = "last_read_message_id"
        case lastReadAt = "last_read_at"
    }
}

private struct PushTokenUpsert: Encodable {
    var empresaId: Int
    var userId: String
    var platform: String
    var token: String
    var deviceName: String
    var lastSeenAt: Date

    enum CodingKeys: String, CodingKey {
        case empresaId = "empresa_id"
        case userId = "user_id"
        case platform
        case token
        case deviceName = "device_name"
        case lastSeenAt = "last_seen_at"
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
