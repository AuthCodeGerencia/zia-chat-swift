import Foundation
import Supabase

enum SupabaseCoreError: LocalizedError {
    case notConfigured
    case invalidURL
    case emptyResponse
    case attachmentUpload(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Core settings are incomplete."
        case .invalidURL:
            return "Invalid Supabase project URL."
        case .emptyResponse:
            return "Supabase returned an empty response."
        case .attachmentUpload(let message):
            return message
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

    /// Lista los mensajes directos del usuario (RPC core_list_user_dms, igual
    /// que la web).
    func listDirectMessages() async throws -> [CoreDirectMessage] {
        let rows: [CoreDMRpcRow] = try await client
            .rpc(
                "core_list_user_dms",
                params: ListChannelsParams(pDisplayName: configuration.displayName.nilIfBlank)
            )
            .execute()
            .value

        let filtered: [CoreDMRpcRow]
        if let empresaId = configuration.empresaId {
            filtered = rows.filter { $0.empresaId == empresaId }
        } else {
            filtered = rows
        }

        return filtered.map { row in
            let peer = normalizedAvatarUser(
                CoreUserLite(
                    id: row.peerId,
                    fullName: row.peerFullName,
                    avatarURLString: row.peerAvatarUrl,
                    roleId: row.peerRolId
                )
            )
            return CoreDirectMessage(
                id: row.id,
                empresaId: row.empresaId,
                dmKey: row.dmKey,
                peer: peer,
                unreadCount: row.unreadCount ?? 0,
                mentionCount: row.mentionCount ?? 0,
                lastMessageContent: row.lastMessageContent,
                lastMessageAt: row.lastMessageCreatedAt,
                lastMessageUserId: row.lastMessageUserId
            )
        }
        .sorted { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }
    }

    func listMentionableUsers() async throws -> [CoreUserLite] {
        var query = client
            .from("profiles")
            .select("id,full_name,avatar_url,rol_id")

        if let empresaId = configuration.empresaId {
            query = query.eq("empresa_id", value: empresaId)
        }

        let users: [CoreUserLite] = try await query
            .order("full_name", ascending: true)
            .execute()
            .value

        return users.map(normalizedAvatarUser)
    }

    func listChannelMembers(channelId: String) async throws -> [CoreUserLite] {
        let memberships: [ChannelMemberUserID] = try await client
            .from("core_channel_members")
            .select("user_id")
            .eq("channel_id", value: channelId)
            .execute()
            .value

        let userIds = Array(Set(memberships.map(\.userId)))
        guard !userIds.isEmpty else { return [] }

        let users: [CoreUserLite] = try await client
            .from("profiles")
            .select("id,full_name,avatar_url,rol_id")
            .in("id", values: userIds)
            .order("full_name", ascending: true)
            .execute()
            .value

        return users.map(normalizedAvatarUser)
    }

    func createChannel(
        name: String,
        description: String,
        visibility: CoreChannelVisibility,
        channelType: String = "text",
        metadata: CoreChannelMetadata? = nil
    ) async throws -> CoreChannel {
        let rows: [CoreChannelCreateResponse]
        do {
            rows = try await client
                .rpc(
                    "core_create_channel",
                    params: CreateChannelParams(
                        pName: name,
                        pDescription: description.nilIfBlank,
                        pVisibility: visibility.rawValue,
                        pChannelType: channelType,
                        pMetadata: metadata
                    )
                )
                .execute()
                .value
        } catch {
            // Fallback for backends without the v2 RPC (extra params not deployed yet).
            guard "\(error)".contains("core_create_channel") else { throw error }
            rows = try await client
                .rpc(
                    "core_create_channel",
                    params: LegacyCreateChannelParams(
                        pName: name,
                        pDescription: description.nilIfBlank,
                        pVisibility: visibility.rawValue
                    )
                )
                .execute()
                .value
        }

        guard let row = rows.first else { throw SupabaseCoreError.emptyResponse }
        return CoreChannel(
            id: row.id,
            empresaId: row.empresaId,
            name: row.name,
            slug: row.slug,
            description: row.description,
            visibility: row.visibility,
            metadata: row.metadata ?? metadata,
            conversationId: row.conversationId
        )
    }

    /// Réplica de slugifyCoreName de la web (services/core/client).
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
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(trimmed.prefix(64))
    }

    /// Actualiza un canal igual que la web (update directo a core_channels:
    /// nombre, slug, descripción, visibilidad y metadata completa).
    func updateChannel(
        channelId: String,
        name: String,
        description: String,
        visibility: CoreChannelVisibility,
        metadata: CoreChannelMetadata
    ) async throws {
        let slug = Self.slugifyCoreName(name)
        guard !slug.isEmpty else {
            throw SupabaseCoreError.attachmentUpload("Nombre de canal inválido")
        }
        try await client
            .from("core_channels")
            .update(
                ChannelUpdateRow(
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    slug: slug,
                    description: description.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                    visibility: visibility.rawValue,
                    metadata: metadata
                )
            )
            .eq("id", value: channelId)
            .execute()
    }

    /// Metadata fresca del canal directo de la tabla (la lista rápida no la trae).
    func fetchChannelMetadata(channelId: String) async throws -> CoreChannelMetadata? {
        let rows: [ChannelMetadataRow] = try await client
            .from("core_channels")
            .select("metadata")
            .eq("id", value: channelId)
            .limit(1)
            .execute()
            .value
        return rows.first?.metadata
    }

    func listChannelMemberRoles(channelId: String) async throws -> [CoreChannelMemberRole] {
        try await client
            .from("core_channel_members")
            .select("user_id, role")
            .eq("channel_id", value: channelId)
            .execute()
            .value
    }

    /// "Eliminar" canal con la misma semántica de la web: archivar
    /// (is_archived + slug renombrado) para que deje de aparecer a todos.
    func archiveChannel(_ channel: CoreChannel) async throws {
        try await client
            .from("core_channels")
            .update(
                ChannelArchiveRow(
                    isArchived: true,
                    slug: "\(channel.slug)-archived-\(Int(Date().timeIntervalSince1970 * 1_000))"
                )
            )
            .eq("id", value: channel.id)
            .execute()
    }

    func syncChannelMembers(channelId: String, userIds: [String], adminIds: [String]) async throws {
        _ = try await client
            .rpc(
                "core_sync_channel_members",
                params: SyncChannelMembersParams(
                    pChannelId: channelId,
                    pUserIds: userIds,
                    pAdminIds: adminIds
                )
            )
            .execute()
    }

    func listInternalCompanies() async throws -> [CoreInternalCompany] {
        try await client
            .from("internal_companies")
            .select("id,name")
            .order("name", ascending: true)
            .execute()
            .value
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

    func listChannelPreviews(conversationIds: [String]) async throws -> [String: CoreMessage] {
        guard !conversationIds.isEmpty else { return [:] }

        let limit = min(max(conversationIds.count * 8, 100), 1_000)
        let loaded: [CoreMessage] = try await client
            .from("core_messages")
            .select(Self.messageColumns)
            .in("conversation_id", values: conversationIds)
            .is("deleted_at", value: nil)
            .is("parent_message_id", value: nil)
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
            .value

        var previews: [String: CoreMessage] = [:]
        for message in loaded where previews[message.conversationId] == nil {
            previews[message.conversationId] = message
        }

        let previewIDs = previews.values.map(\.id)
        let attachments = (try? await fetchAttachments(messageIds: previewIDs)) ?? []
        let attachmentMap = Dictionary(grouping: attachments, by: { $0.messageId ?? "" })

        for (conversationId, message) in previews {
            var copy = message
            let metadataAttachments = Self.metadataAttachments(from: message)
            copy.attachments = attachmentMap[message.id, default: []] + metadataAttachments
            previews[conversationId] = copy
        }

        return previews
    }

    func listMessages(conversationId: String) async throws -> [CoreMessage] {
        let displayOrder = try await listMessagePage(conversationId: conversationId)
        return try await enrichMessages(displayOrder)
    }

    func listMessagePins(conversationId: String) async throws -> [CoreMessagePin] {
        try await client
            .from("core_message_pins")
            .select()
            .eq("conversation_id", value: conversationId)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func pinMessage(_ message: CoreMessage) async throws -> CoreMessagePin {
        guard let empresaId = configuration.empresaId else {
            throw SupabaseCoreError.notConfigured
        }

        let inserted: [CoreMessagePin] = try await client
            .from("core_message_pins")
            .insert(
                CoreMessagePinInsert(
                    empresaId: empresaId,
                    conversationId: message.conversationId,
                    messageId: message.id,
                    pinnedBy: configuration.userId
                )
            )
            .select()
            .execute()
            .value

        guard let pin = inserted.first else { throw SupabaseCoreError.emptyResponse }
        return pin
    }

    func unpinMessage(_ message: CoreMessage) async throws {
        try await client
            .from("core_message_pins")
            .delete()
            .eq("conversation_id", value: message.conversationId)
            .eq("message_id", value: message.id)
            .execute()
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
                let fromRPC: [CoreMessage] = try await client
                    .rpc(
                        "core_list_zia_messages",
                        params: ListMessagesParams(
                            conversationId: conversationId,
                            limit: limit
                        )
                    )
                    .execute()
                    .value
                // El RPC hace JOIN con core_channels, así que para los DMs
                // (channel_id NULL) devuelve vacío sin error. Si no trae nada,
                // reintenta con la consulta directa (RLS) antes de asumir que
                // la conversación está realmente vacía.
                if fromRPC.isEmpty {
                    loaded = try await messagePageQuery(
                        conversationId: conversationId,
                        before: nil,
                        limit: limit
                    )
                } else {
                    loaded = fromRPC
                }
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

    func listThreadReplies(conversationId: String, parentMessageId: String) async throws -> [CoreMessage] {
        let replies: [CoreMessage] = try await client
            .from("core_messages")
            .select(Self.messageColumns)
            .eq("conversation_id", value: conversationId)
            .eq("parent_message_id", value: parentMessageId)
            .is("deleted_at", value: nil)
            .order("created_at", ascending: true)
            .execute()
            .value

        return try await enrich(replies)
    }

    /// Lists every thread in a conversation (root messages that have replies),
    /// with reply count and the timestamp/author of the latest reply.
    func listChannelThreads(conversationId: String) async throws -> [CoreThreadSummary] {
        let replies: [ThreadReplyMeta] = try await client
            .from("core_messages")
            .select("parent_message_id,user_id,created_at")
            .eq("conversation_id", value: conversationId)
            .not("parent_message_id", operator: .is, value: "null")
            .is("deleted_at", value: nil)
            .order("created_at", ascending: false)
            .limit(1_000)
            .execute()
            .value

        guard !replies.isEmpty else { return [] }

        var counts: [String: Int] = [:]
        var lastReplyAt: [String: Date] = [:]
        var lastReplyUser: [String: String] = [:]
        for reply in replies {
            guard let parentId = reply.parentMessageId else { continue }
            counts[parentId, default: 0] += 1
            // Replies arrive newest-first, so the first one wins.
            if lastReplyAt[parentId] == nil {
                lastReplyAt[parentId] = reply.createdAt
                lastReplyUser[parentId] = reply.userId
            }
        }

        let roots: [CoreMessage] = try await client
            .from("core_messages")
            .select(Self.messageColumns)
            .in("id", values: Array(counts.keys))
            .is("deleted_at", value: nil)
            .execute()
            .value
        let enriched = (try? await enrich(roots)) ?? roots

        return enriched
            .compactMap { root -> CoreThreadSummary? in
                guard let count = counts[root.id], let lastAt = lastReplyAt[root.id] else { return nil }
                return CoreThreadSummary(
                    root: root,
                    replyCount: count,
                    lastReplyAt: lastAt,
                    lastReplyUserId: lastReplyUser[root.id]
                )
            }
            .sorted { $0.lastReplyAt > $1.lastReplyAt }
    }

    func forwardMessage(_ source: CoreMessage, to channel: CoreChannel) async throws -> CoreMessage {
        guard let conversationId = channel.conversationId else {
            throw SupabaseCoreError.emptyResponse
        }

        try await ensureMembership(conversationId: conversationId, channelId: channel.id)

        let row = CoreMessageInsert(
            empresaId: channel.empresaId,
            conversationId: conversationId,
            channelId: channel.id,
            parentMessageId: nil,
            userId: configuration.userId,
            content: source.content
        )
        let inserted: [CoreMessage] = try await client
            .from("core_messages")
            .insert(row)
            .select()
            .execute()
            .value
        guard var message = inserted.first else { throw SupabaseCoreError.emptyResponse }

        let attachments = source.attachments ?? []
        guard !attachments.isEmpty else { return message }

        let rows = attachments.compactMap { attachment -> CoreAttachmentInsert? in
            guard let path = attachment.path?.nilIfBlank else { return nil }
            return CoreAttachmentInsert(
                empresaId: channel.empresaId,
                messageId: message.id,
                uploaderId: configuration.userId,
                bucket: attachment.bucket?.nilIfBlank ?? Self.attachmentsBucket,
                path: path,
                fileName: attachment.fileName,
                mimeType: attachment.mimeType?.nilIfBlank ?? "application/octet-stream",
                sizeBytes: attachment.sizeBytes ?? 0
            )
        }

        if !rows.isEmpty {
            let saved: [CoreAttachment] = try await client
                .from("core_attachments")
                .insert(rows)
                .select()
                .execute()
                .value
            message.attachments = try await signAttachments(saved)
        }
        return message
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
        attachments: [CorePendingAttachment] = [],
        replyTo: CoreMessageReplyTo? = nil
    ) async throws -> CoreMessage {
        try await ensureMembership(conversationId: conversationId, channelId: channelId)

        let row = CoreMessageInsert(
            empresaId: empresaId,
            conversationId: conversationId,
            channelId: channelId,
            parentMessageId: parentMessageId,
            userId: configuration.userId,
            content: content,
            metadata: replyTo.map { CoreMessageMetadata(replyTo: $0) }
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
            throw Self.mapAttachmentError(error)
        }
    }

    // MARK: - Polls

    /// Creates a poll (core_polls + core_poll_options), mirroring the web app's
    /// direct-insert flow. Returns the new poll id.
    @discardableResult
    func createPoll(channelId: String?, messageId: String?, question: String, options: [String]) async throws -> String {
        guard let empresaId = configuration.empresaId else { throw SupabaseCoreError.notConfigured }
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanOptions = options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleanQuestion.isEmpty, cleanOptions.count >= 2 else {
            throw SupabaseCoreError.emptyResponse
        }

        let pollRows: [PollIDRow] = try await client
            .from("core_polls")
            .insert(
                PollInsert(
                    empresaId: empresaId,
                    channelId: channelId,
                    messageId: messageId,
                    question: cleanQuestion,
                    createdBy: configuration.userId
                )
            )
            .select("id")
            .execute()
            .value
        guard let pollId = pollRows.first?.id else { throw SupabaseCoreError.emptyResponse }

        let optionRows = cleanOptions.enumerated().map { index, label in
            PollOptionInsert(pollId: pollId, label: label, sortOrder: index)
        }
        try await client
            .from("core_poll_options")
            .insert(optionRows)
            .execute()

        return pollId
    }

    /// Lists the channel's polls with their options and aggregated vote counts.
    func listPolls(channelId: String) async throws -> [CorePoll] {
        let pollRows: [PollRowDTO] = try await client
            .from("core_polls")
            .select("id,message_id,question,options:core_poll_options(id,label,sort_order)")
            .eq("channel_id", value: channelId)
            .order("created_at", ascending: false)
            .limit(60)
            .execute()
            .value

        let optionIds = pollRows.flatMap { $0.options.map(\.id) }
        var votes: [PollVoteDTO] = []
        if !optionIds.isEmpty {
            votes = try await client
                .from("core_poll_votes")
                .select("option_id,user_id")
                .in("option_id", values: optionIds)
                .execute()
                .value
        }

        let me = configuration.userId
        return pollRows.map { row in
            let options = row.options
                .sorted { $0.sortOrder < $1.sortOrder }
                .map { option -> CorePollOption in
                    let optionVotes = votes.filter { $0.optionId == option.id }
                    return CorePollOption(
                        id: option.id,
                        label: option.label,
                        sortOrder: option.sortOrder,
                        votesCount: optionVotes.count,
                        votedByMe: optionVotes.contains { $0.userId == me }
                    )
                }
            return CorePoll(id: row.id, messageId: row.messageId, question: row.question, options: options)
        }
    }

    /// Records the current user's vote, replacing any previous vote on the poll.
    func votePoll(pollId: String, optionId: String) async throws {
        try await client
            .from("core_poll_votes")
            .delete()
            .eq("poll_id", value: pollId)
            .eq("user_id", value: configuration.userId)
            .execute()

        try await client
            .from("core_poll_votes")
            .insert(PollVoteInsert(pollId: pollId, optionId: optionId, userId: configuration.userId))
            .execute()
    }

    // MARK: - Stickers

    func listStickers() async throws -> [CoreSticker] {
        guard let empresaId = configuration.empresaId else { return [] }
        do {
            let rows: [CoreSticker] = try await client
                .from("core_stickers")
                .select("id,name,image_url,created_by")
                .eq("empresa_id", value: empresaId)
                .order("name", ascending: true)
                .execute()
                .value
            return rows
        } catch {
            // Si la migración created_by aún no está aplicada, cae al select
            // anterior para no romper el picker.
            let rows: [CoreSticker] = try await client
                .from("core_stickers")
                .select("id,name,image_url")
                .eq("empresa_id", value: empresaId)
                .order("name", ascending: true)
                .execute()
                .value
            return rows
        }
    }

    /// Uploads a sticker via the web app's `/api/core/stickers` route (same
    /// endpoint the React client uses), authenticating with the current bearer
    /// token.
    func uploadSticker(name: String, data: Data, fileName: String, mimeType: String) async throws -> CoreSticker {
        let base = CoreEnvironment.load().appURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/api/core/stickers") else { throw SupabaseCoreError.invalidURL }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.accessToken)", forHTTPHeaderField: "Authorization")

        var body = Data()
        func appendString(_ string: String) { body.append(Data(string.utf8)) }
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"name\"\r\n\r\n")
        appendString("\(name)\r\n")
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        appendString("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SupabaseCoreError.emptyResponse
        }
        return try JSONDecoder().decode(StickerUploadResponse.self, from: responseData).sticker
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

    /// Lee las marcas de lectura de todos los miembros de una conversación
    /// (visible dentro de la empresa gracias a la RLS de core_message_reads).
    /// Sirve para los recibos de lectura: palomitas y "Vistos por".
    func listConversationReads(conversationId: String) async throws -> [CoreConversationRead] {
        let rows: [CoreConversationRead] = try await client
            .from("core_message_reads")
            .select("user_id,last_read_at")
            .eq("conversation_id", value: conversationId)
            .execute()
            .value
        return rows
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
        async let replyCountsTask = fetchReplyCounts(messageIds: messages.map(\.id))

        let userMap = (try? await usersTask) ?? [:]
        let reactionMap = Dictionary(grouping: ((try? await reactionsTask) ?? []), by: \.messageId)
        let storedAttachments = (try? await attachmentsTask) ?? []
        let fallbackAttachments = messages.flatMap(Self.metadataAttachments)
        let allAttachments = (try? await signAttachments(storedAttachments + fallbackAttachments)) ??
            (storedAttachments + fallbackAttachments)
        let attachmentMap = Dictionary(grouping: allAttachments, by: { $0.messageId ?? "" })
        let parentMap = ((try? await parentsTask) ?? []).reduce(into: [String: CoreMessageQuote]()) {
            $0[$1.id] = $1
        }
        let replyCounts = (try? await replyCountsTask) ?? [:]

        return messages.map { message in
            var copy = message
            copy.author = userMap[message.userId]
            copy.reactions = reactionMap[message.id] ?? []
            copy.attachments = attachmentMap[message.id] ?? []
            if let parentId = message.parentMessageId {
                copy.parent = parentMap[parentId]
            }
            copy.replyCount = replyCounts[message.id] ?? 0
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
        return attachments
    }

    private func fetchReplyCounts(messageIds: [String]) async throws -> [String: Int] {
        guard !messageIds.isEmpty else { return [:] }

        let replies: [ParentMessageID] = try await client
            .from("core_messages")
            .select("parent_message_id")
            .in("parent_message_id", values: messageIds)
            .is("deleted_at", value: nil)
            .execute()
            .value

        return replies.reduce(into: [:]) { counts, reply in
            guard let parentMessageId = reply.parentMessageId else { return }
            counts[parentMessageId, default: 0] += 1
        }
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
            do {
                try await client.storage
                    .from(Self.attachmentsBucket)
                    .upload(
                        path,
                        data: attachment.data,
                        options: FileOptions(contentType: attachment.mimeType)
                    )
            } catch {
                throw Self.mapAttachmentError(error)
            }
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

    /// Convierte errores crudos de Storage/PostgREST (p. ej. "status code 404
    /// body {}") en mensajes accionables. El 404 al subir adjuntos casi siempre
    /// significa que falta el bucket `core-attachments` o la tabla
    /// `core_attachments` (migración 20260611143000_zia_chat_attachments.sql).
    private static func mapAttachmentError(_ error: Error) -> Error {
        if let coreError = error as? SupabaseCoreError { return coreError }
        let raw = "\(error) \(error.localizedDescription)".lowercased()
        if raw.contains("core_attachments") && (raw.contains("does not exist") || raw.contains("schema cache") || raw.contains("could not find")) {
            return SupabaseCoreError.attachmentUpload(
                "Falta la tabla core_attachments. Ejecuta la migración 20260611143000_zia_chat_attachments.sql en el SQL Editor."
            )
        }
        if raw.contains("bucket not found") || raw.contains("404") {
            return SupabaseCoreError.attachmentUpload(
                "No existe el bucket 'core-attachments' en Supabase Storage. Ejecuta la migración 20260611143000_zia_chat_attachments.sql en el SQL Editor y vuelve a intentar."
            )
        }
        if raw.contains("row-level security") || raw.contains("violates") || raw.contains("403") {
            return SupabaseCoreError.attachmentUpload(
                "Supabase rechazó la subida del archivo por permisos (RLS). Verifica las políticas del bucket core-attachments de la migración 20260611143000."
            )
        }
        return SupabaseCoreError.attachmentUpload("No se pudo subir el archivo adjunto: \(error.localizedDescription)")
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

    private static func metadataAttachments(from message: CoreMessage) -> [CoreAttachment] {
        (message.metadata?.attachments ?? []).enumerated().compactMap { index, attachment in
            let path = attachment.path?.nilIfBlank
            let url = attachment.url?.nilIfBlank
            guard path != nil || url != nil else { return nil }

            return CoreAttachment(
                id: "\(message.id)-metadata-\(index)",
                empresaId: message.empresaId,
                messageId: message.id,
                ticketId: nil,
                uploaderId: message.userId,
                bucket: attachment.bucket?.nilIfBlank ?? attachmentsBucket,
                path: path,
                url: url,
                fileName: attachment.fileName?.nilIfBlank ?? "archivo",
                mimeType: attachment.mimeType?.nilIfBlank,
                sizeBytes: attachment.sizeBytes,
                createdAt: message.createdAt
            )
        }
    }

    nonisolated private static let messageColumns = """
        id,empresa_id,conversation_id,channel_id,parent_message_id,user_id,content,edited_at,deleted_at,created_at,metadata
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

private struct CoreDMRpcRow: Decodable {
    var id: String
    var empresaId: Int
    var dmKey: String?
    var peerId: String
    var peerFullName: String?
    var peerAvatarUrl: String?
    var peerRolId: Int?
    var unreadCount: Int?
    var mentionCount: Int?
    var lastMessageId: String?
    var lastMessageUserId: String?
    var lastMessageContent: String?
    var lastMessageCreatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case empresaId = "empresa_id"
        case dmKey = "dm_key"
        case peerId = "peer_id"
        case peerFullName = "peer_full_name"
        case peerAvatarUrl = "peer_avatar_url"
        case peerRolId = "peer_rol_id"
        case unreadCount = "unread_count"
        case mentionCount = "mention_count"
        case lastMessageId = "last_message_id"
        case lastMessageUserId = "last_message_user_id"
        case lastMessageContent = "last_message_content"
        case lastMessageCreatedAt = "last_message_created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        empresaId = try container.decode(Int.self, forKey: .empresaId)
        dmKey = try? container.decodeIfPresent(String.self, forKey: .dmKey)
        peerId = try container.decode(String.self, forKey: .peerId)
        peerFullName = try? container.decodeIfPresent(String.self, forKey: .peerFullName)
        peerAvatarUrl = try? container.decodeIfPresent(String.self, forKey: .peerAvatarUrl)
        peerRolId = try? container.decodeIfPresent(Int.self, forKey: .peerRolId)
        if let value = try? container.decodeIfPresent(Int.self, forKey: .unreadCount) {
            unreadCount = value
        } else if let value = try? container.decodeIfPresent(String.self, forKey: .unreadCount) {
            unreadCount = Int(value)
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: .mentionCount) {
            mentionCount = value
        } else if let value = try? container.decodeIfPresent(String.self, forKey: .mentionCount) {
            mentionCount = Int(value)
        }
        lastMessageId = try? container.decodeIfPresent(String.self, forKey: .lastMessageId)
        lastMessageUserId = try? container.decodeIfPresent(String.self, forKey: .lastMessageUserId)
        lastMessageContent = try? container.decodeIfPresent(String.self, forKey: .lastMessageContent)
        lastMessageCreatedAt = try? container.decodeIfPresent(Date.self, forKey: .lastMessageCreatedAt)
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
    var pChannelType: String
    var pMetadata: CoreChannelMetadata?

    enum CodingKeys: String, CodingKey {
        case pName = "p_name"
        case pDescription = "p_description"
        case pVisibility = "p_visibility"
        case pChannelType = "p_channel_type"
        case pMetadata = "p_metadata"
    }
}

private struct LegacyCreateChannelParams: Encodable {
    var pName: String
    var pDescription: String?
    var pVisibility: String

    enum CodingKeys: String, CodingKey {
        case pName = "p_name"
        case pDescription = "p_description"
        case pVisibility = "p_visibility"
    }
}

private struct ChannelUpdateRow: Encodable {
    var name: String
    var slug: String
    var description: String?
    var visibility: String
    var metadata: CoreChannelMetadata

    enum CodingKeys: String, CodingKey {
        case name
        case slug
        case description
        case visibility
        case metadata
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(slug, forKey: .slug)
        // null explícito para poder limpiar la descripción, igual que la web.
        try container.encode(description, forKey: .description)
        try container.encode(visibility, forKey: .visibility)
        try container.encode(metadata, forKey: .metadata)
    }
}

private struct ChannelMetadataRow: Decodable {
    var metadata: CoreChannelMetadata?
}

private struct ChannelArchiveRow: Encodable {
    var isArchived: Bool
    var slug: String

    enum CodingKeys: String, CodingKey {
        case isArchived = "is_archived"
        case slug
    }
}

private struct SyncChannelMembersParams: Encodable {
    var pChannelId: String
    var pUserIds: [String]
    var pAdminIds: [String]

    enum CodingKeys: String, CodingKey {
        case pChannelId = "p_channel_id"
        case pUserIds = "p_user_ids"
        case pAdminIds = "p_admin_ids"
    }
}

private struct CoreChannelCreateResponse: Codable {
    var id: String
    var empresaId: Int
    var name: String
    var slug: String
    var description: String?
    var visibility: CoreChannelVisibility
    var metadata: CoreChannelMetadata?
    var conversationId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case empresaId = "empresa_id"
        case name
        case slug
        case description
        case visibility
        case metadata
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
    var metadata: CoreMessageMetadata?

    enum CodingKeys: String, CodingKey {
        case empresaId = "empresa_id"
        case conversationId = "conversation_id"
        case channelId = "channel_id"
        case parentMessageId = "parent_message_id"
        case userId = "user_id"
        case content
        case metadata
    }
}

private struct CoreMessagePinInsert: Encodable {
    var empresaId: Int
    var conversationId: String
    var messageId: String
    var pinnedBy: String

    enum CodingKeys: String, CodingKey {
        case empresaId = "empresa_id"
        case conversationId = "conversation_id"
        case messageId = "message_id"
        case pinnedBy = "pinned_by"
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

private struct PollInsert: Encodable {
    var empresaId: Int
    var channelId: String?
    var messageId: String?
    var question: String
    var createdBy: String

    enum CodingKeys: String, CodingKey {
        case empresaId = "empresa_id"
        case channelId = "channel_id"
        case messageId = "message_id"
        case question
        case createdBy = "created_by"
    }
}

private struct PollOptionInsert: Encodable {
    var pollId: String
    var label: String
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case pollId = "poll_id"
        case label
        case sortOrder = "sort_order"
    }
}

private struct PollIDRow: Decodable {
    var id: String
}

private struct PollRowDTO: Decodable {
    var id: String
    var messageId: String?
    var question: String
    var options: [PollOptionDTO]

    enum CodingKeys: String, CodingKey {
        case id
        case messageId = "message_id"
        case question
        case options
    }
}

private struct PollOptionDTO: Decodable {
    var id: String
    var label: String
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case sortOrder = "sort_order"
    }
}

private struct PollVoteDTO: Decodable {
    var optionId: String
    var userId: String

    enum CodingKeys: String, CodingKey {
        case optionId = "option_id"
        case userId = "user_id"
    }
}

private struct PollVoteInsert: Encodable {
    var pollId: String
    var optionId: String
    var userId: String

    enum CodingKeys: String, CodingKey {
        case pollId = "poll_id"
        case optionId = "option_id"
        case userId = "user_id"
    }
}

private struct StickerUploadResponse: Decodable {
    var sticker: CoreSticker
}

private struct ParentMessageID: Decodable {
    var parentMessageId: String?

    enum CodingKeys: String, CodingKey {
        case parentMessageId = "parent_message_id"
    }
}

private struct ThreadReplyMeta: Decodable {
    var parentMessageId: String?
    var userId: String
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case parentMessageId = "parent_message_id"
        case userId = "user_id"
        case createdAt = "created_at"
    }
}

private struct ChannelMemberUserID: Decodable {
    var userId: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
    }
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
