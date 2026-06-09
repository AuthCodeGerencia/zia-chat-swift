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

    func listMessages(conversationId: String) async throws -> [CoreMessage] {
        let displayOrder = try await listMessagePage(conversationId: conversationId)
        return try await enrichMessages(displayOrder)
    }

    func listMessagePage(conversationId: String) async throws -> [CoreMessage] {
        let loaded: [CoreMessage] = try await client
            .from("core_messages")
            .select()
            .eq("conversation_id", value: conversationId)
            .is("deleted_at", value: nil)
            .is("parent_message_id", value: nil)
            .order("created_at", ascending: false)
            .limit(21)
            .execute()
            .value

        return Array(loaded.reversed())
    }

    func enrichMessages(_ messages: [CoreMessage]) async throws -> [CoreMessage] {
        try await enrich(messages)
    }

    func ensureChannelMembership(channelId: String, conversationId: String) async throws {
        try await ensureMembership(conversationId: conversationId, channelId: channelId)
    }

    func sendMessage(
        empresaId: Int,
        conversationId: String,
        channelId: String?,
        parentMessageId: String?,
        content: String
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
        return message
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
        let parentMap = Dictionary(uniqueKeysWithValues: ((try? await parentsTask) ?? []).map { ($0.id, $0) })

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

        return Dictionary(uniqueKeysWithValues: users.map { ($0.id, normalizedAvatarUser($0)) })
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

        return try await client
            .from("core_attachments")
            .select()
            .in("message_id", values: messageIds)
            .execute()
            .value
    }

    private func fetchParents(ids: [String]) async throws -> [CoreMessageQuote] {
        guard !ids.isEmpty else { return [] }

        let parents: [CoreMessage] = try await client
            .from("core_messages")
            .select()
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

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
