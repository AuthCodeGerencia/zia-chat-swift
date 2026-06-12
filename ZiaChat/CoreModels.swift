import Foundation
import SwiftUI

enum CoreChannelVisibility: String, Codable, CaseIterable, Hashable {
    case `public`
    case `private`
}

struct CoreChannelTheme: Codable, Hashable {
    var preset: String? = nil
    var background: String? = nil
    var backgroundImage: String? = nil
    var backgroundImageOpacity: Double? = nil
    var accent: String? = nil
    var titleColor: String? = nil
    var surface: String? = nil
    var bubbleMine: String? = nil
    var bubbleOther: String? = nil

    enum CodingKeys: String, CodingKey {
        case preset
        case background
        case backgroundImage
        case backgroundImageOpacity
        case accent
        case titleColor
        case surface
        case bubbleMine
        case bubbleOther
    }

    init(
        preset: String? = nil,
        background: String? = nil,
        backgroundImage: String? = nil,
        backgroundImageOpacity: Double? = nil,
        accent: String? = nil,
        titleColor: String? = nil,
        surface: String? = nil,
        bubbleMine: String? = nil,
        bubbleOther: String? = nil
    ) {
        self.preset = preset
        self.background = background
        self.backgroundImage = backgroundImage
        self.backgroundImageOpacity = backgroundImageOpacity
        self.accent = accent
        self.titleColor = titleColor
        self.surface = surface
        self.bubbleMine = bubbleMine
        self.bubbleOther = bubbleOther
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preset = try? container.decodeIfPresent(String.self, forKey: .preset)
        background = try? container.decodeIfPresent(String.self, forKey: .background)
        backgroundImage = try? container.decodeIfPresent(String.self, forKey: .backgroundImage)
        if let value = try? container.decodeIfPresent(Double.self, forKey: .backgroundImageOpacity) {
            backgroundImageOpacity = value
        } else if let value = try? container.decodeIfPresent(Int.self, forKey: .backgroundImageOpacity) {
            backgroundImageOpacity = Double(value)
        }
        accent = try? container.decodeIfPresent(String.self, forKey: .accent)
        titleColor = try? container.decodeIfPresent(String.self, forKey: .titleColor)
        surface = try? container.decodeIfPresent(String.self, forKey: .surface)
        bubbleMine = try? container.decodeIfPresent(String.self, forKey: .bubbleMine)
        bubbleOther = try? container.decodeIfPresent(String.self, forKey: .bubbleOther)
    }
}

struct CoreChannelMetadata: Codable, Hashable {
    var channelType: String? = nil
    var iconImage: String? = nil
    var theme: CoreChannelTheme? = nil
    var businessUnitId: Int? = nil
    // Claves que la web guarda en metadata y deben sobrevivir a una edición.
    var inviteToken: String? = nil
    var inviteTokenCreatedAt: String? = nil
    var inviteTokenCreatedBy: String? = nil

    enum CodingKeys: String, CodingKey {
        case channelType
        case iconImage
        case theme
        case businessUnitId
        case inviteToken
        case inviteTokenCreatedAt
        case inviteTokenCreatedBy
    }

    init(
        channelType: String? = nil,
        iconImage: String? = nil,
        theme: CoreChannelTheme? = nil,
        businessUnitId: Int? = nil,
        inviteToken: String? = nil,
        inviteTokenCreatedAt: String? = nil,
        inviteTokenCreatedBy: String? = nil
    ) {
        self.channelType = channelType
        self.iconImage = iconImage
        self.theme = theme
        self.businessUnitId = businessUnitId
        self.inviteToken = inviteToken
        self.inviteTokenCreatedAt = inviteTokenCreatedAt
        self.inviteTokenCreatedBy = inviteTokenCreatedBy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channelType = try? container.decodeIfPresent(String.self, forKey: .channelType)
        iconImage = try? container.decodeIfPresent(String.self, forKey: .iconImage)
        theme = try? container.decodeIfPresent(CoreChannelTheme.self, forKey: .theme)
        if let value = try? container.decodeIfPresent(Int.self, forKey: .businessUnitId) {
            businessUnitId = value
        } else if let value = try? container.decodeIfPresent(String.self, forKey: .businessUnitId) {
            businessUnitId = Int(value)
        }
        inviteToken = try? container.decodeIfPresent(String.self, forKey: .inviteToken)
        inviteTokenCreatedAt = try? container.decodeIfPresent(String.self, forKey: .inviteTokenCreatedAt)
        inviteTokenCreatedBy = try? container.decodeIfPresent(String.self, forKey: .inviteTokenCreatedBy)
    }
}

struct CoreChannelMemberRole: Codable, Hashable {
    var userId: String
    var role: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case role
    }
}

struct CoreInternalCompany: Identifiable, Codable, Hashable {
    var id: Int
    var name: String
}

/// Mensaje directo (conversación type='dm' de la web). `id` = conversation id.
struct CoreDirectMessage: Identifiable, Hashable {
    var id: String
    var empresaId: Int
    var dmKey: String?
    var peer: CoreUserLite
    var unreadCount: Int = 0
    var mentionCount: Int = 0
    var lastMessageContent: String?
    var lastMessageAt: Date?
    var lastMessageUserId: String?
}

extension CoreChannel {
    /// Canal "fantasma" que representa un DM para reutilizar las vistas de chat.
    var isDirectMessage: Bool {
        metadata?.channelType == "dm"
    }
}

extension CoreDirectMessage {
    /// Alias del canal fantasma (compatibilidad con código que usa chatTarget).
    var chatTarget: CoreChannel {
        CoreChannel(
            id: id,
            empresaId: empresaId,
            name: peer.displayName,
            slug: "dm-\(id)",
            description: "Mensaje directo",
            visibility: .private,
            metadata: CoreChannelMetadata(channelType: "dm", iconImage: peer.avatarURLString),
            conversationId: id,
            unreadCount: unreadCount,
            mentionCount: mentionCount
        )
    }
}

struct CoreChannel: Identifiable, Codable, Hashable {
    var id: String
    var empresaId: Int
    var teamId: String?
    var name: String
    var slug: String
    var description: String?
    var visibility: CoreChannelVisibility
    var isArchived: Bool
    var createdBy: String?
    var createdAt: Date?
    var updatedAt: Date?
    var metadata: CoreChannelMetadata?
    var conversationId: String?
    var unreadCount: Int
    var mentionCount: Int
    var currentUserIsMember: Bool
    var visibleAsSuperAdmin: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case empresaId = "empresa_id"
        case teamId = "team_id"
        case name
        case slug
        case description
        case visibility
        case isArchived = "is_archived"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case metadata
        case conversationId = "conversation_id"
        case unreadCount = "unread_count"
        case mentionCount = "mention_count"
        case currentUserIsMember = "current_user_is_member"
        case visibleAsSuperAdmin = "visible_as_super_admin"
    }

    init(
        id: String,
        empresaId: Int,
        teamId: String? = nil,
        name: String,
        slug: String,
        description: String? = nil,
        visibility: CoreChannelVisibility = .public,
        isArchived: Bool = false,
        createdBy: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        metadata: CoreChannelMetadata? = nil,
        conversationId: String? = nil,
        unreadCount: Int = 0,
        mentionCount: Int = 0,
        currentUserIsMember: Bool = true,
        visibleAsSuperAdmin: Bool = false
    ) {
        self.id = id
        self.empresaId = empresaId
        self.teamId = teamId
        self.name = name
        self.slug = slug
        self.description = description
        self.visibility = visibility
        self.isArchived = isArchived
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
        self.conversationId = conversationId
        self.unreadCount = unreadCount
        self.mentionCount = mentionCount
        self.currentUserIsMember = currentUserIsMember
        self.visibleAsSuperAdmin = visibleAsSuperAdmin
    }

    var isVoice: Bool {
        metadata?.channelType == "voice"
    }

    var isDirect: Bool {
        metadata?.channelType == "dm"
    }

    var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
    }

    var descriptionText: String {
        description?.isEmpty == false ? description! : (visibility == .private ? "Private Core channel" : "Public Core channel")
    }

    var subtitle: String {
        if isVoice { return "Voice channel" }
        return descriptionText
    }

    var symbolName: String {
        if isVoice { return "speaker.wave.2.fill" }
        if isDirect { return "person.fill" }
        return visibility == .private ? "lock.fill" : "number"
    }

    var tint: Color {
        // Paleta Grupo Zenit: teal corporativo, oliva y khaki.
        if isVoice { return ZenitBrand.khaki }
        return visibility == .private ? ZenitBrand.olive : ZenitBrand.teal
    }
}

struct CoreUserLite: Identifiable, Codable, Hashable {
    var id: String
    var fullName: String?
    var avatarURLString: String?
    var roleId: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case avatarURLString = "avatar_url"
        case roleId = "rol_id"
    }

    var displayName: String {
        fullName?.isEmpty == false ? fullName! : "Unknown"
    }

    var avatarURL: URL? {
        guard let avatarURLString, !avatarURLString.isEmpty else { return nil }
        return URL(string: avatarURLString)
    }
}

struct CoreReaction: Identifiable, Codable, Hashable {
    var id: String
    var empresaId: Int
    var messageId: String
    var userId: String
    var emoji: String
    var customReactionId: String?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case empresaId = "empresa_id"
        case messageId = "message_id"
        case userId = "user_id"
        case emoji
        case customReactionId = "custom_reaction_id"
        case createdAt = "created_at"
    }

    init(
        id: String,
        empresaId: Int,
        messageId: String,
        userId: String,
        emoji: String,
        customReactionId: String? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.empresaId = empresaId
        self.messageId = messageId
        self.userId = userId
        self.emoji = emoji
        self.customReactionId = customReactionId
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        empresaId = try container.decode(Int.self, forKey: .empresaId)
        messageId = try container.decode(String.self, forKey: .messageId)
        userId = try container.decode(String.self, forKey: .userId)
        emoji = (try? container.decode(String.self, forKey: .emoji)).flatMap { $0.isEmpty ? nil : $0 } ?? "\u{1F44D}"
        customReactionId = try? container.decodeIfPresent(String.self, forKey: .customReactionId)
        createdAt = try? container.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}

struct CoreAttachment: Identifiable, Codable, Hashable {
    var id: String
    var empresaId: Int
    var messageId: String?
    var ticketId: String?
    var uploaderId: String
    var bucket: String?
    var path: String?
    var url: String?
    var fileName: String
    var mimeType: String?
    var sizeBytes: Int?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case empresaId = "empresa_id"
        case messageId = "message_id"
        case ticketId = "ticket_id"
        case uploaderId = "uploader_id"
        case bucket
        case path
        case url
        case fileName = "file_name"
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
        case createdAt = "created_at"
    }

    var resolvedURL: URL? {
        if let url, !url.isEmpty { return URL(string: url) }
        return nil
    }

    var systemImage: String {
        if isVideo { return "video" }
        guard let mimeType else { return "paperclip" }
        if mimeType.hasPrefix("image/") { return "photo" }
        if mimeType.contains("pdf") { return "doc.richtext" }
        return "paperclip"
    }

    var isImage: Bool {
        mimeType?.hasPrefix("image/") == true
    }

    var isGIF: Bool {
        mimeType?.lowercased() == "image/gif" ||
        fileName.lowercased().hasSuffix(".gif")
    }

    var isAudio: Bool {
        if mimeType?.hasPrefix("audio/") == true { return true }
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ["m4a", "mp3", "wav", "aac", "caf", "ogg"].contains(ext)
    }

    var isVideo: Bool {
        if mimeType?.hasPrefix("video/") == true { return true }
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "webm", "avi"].contains(ext)
    }
}

struct CorePendingAttachment: Identifiable, Hashable {
    let id: UUID
    var data: Data
    var fileName: String
    var mimeType: String

    init(id: UUID = UUID(), data: Data, fileName: String, mimeType: String) {
        self.id = id
        self.data = data
        self.fileName = fileName
        self.mimeType = mimeType
    }

    var sizeBytes: Int {
        data.count
    }

    var isGIF: Bool {
        mimeType == "image/gif"
    }
}

/// Cita de respuesta (paridad con metadata.replyTo de la web).
struct CoreMessageReplyTo: Codable, Hashable {
    var messageId: String
    var authorId: String?
    var authorName: String?
    var content: String?
    var createdAt: String?
    var hasAttachments: Bool?

    var displayAuthor: String {
        authorName?.isEmpty == false ? authorName! : "Usuario Core"
    }

    var preview: String {
        let text = (content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        return hasAttachments == true ? "Mensaje con adjuntos" : "Mensaje"
    }
}

struct CoreMessageMetadata: Codable, Hashable {
    var attachments: [CoreMetadataAttachment]?
    var replyTo: CoreMessageReplyTo?

    enum CodingKeys: String, CodingKey {
        case attachments
        case replyTo
    }

    init(attachments: [CoreMetadataAttachment]? = nil, replyTo: CoreMessageReplyTo? = nil) {
        self.attachments = attachments
        self.replyTo = replyTo
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attachments = try? container.decodeIfPresent([CoreMetadataAttachment].self, forKey: .attachments)
        replyTo = try? container.decodeIfPresent(CoreMessageReplyTo.self, forKey: .replyTo)
    }
}

struct CoreMetadataAttachment: Codable, Hashable {
    var bucket: String?
    var path: String?
    var url: String?
    var fileName: String?
    var mimeType: String?
    var sizeBytes: Int?

    enum CodingKeys: String, CodingKey {
        case bucket
        case path
        case url
        case fileName
        case fileNameSnake = "file_name"
        case mimeType
        case mimeTypeSnake = "mime_type"
        case sizeBytes
        case sizeBytesSnake = "size_bytes"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bucket = try? container.decodeIfPresent(String.self, forKey: .bucket)
        path = try? container.decodeIfPresent(String.self, forKey: .path)
        url = try? container.decodeIfPresent(String.self, forKey: .url)
        fileName =
            (try? container.decodeIfPresent(String.self, forKey: .fileNameSnake)) ??
            (try? container.decodeIfPresent(String.self, forKey: .fileName))
        mimeType =
            (try? container.decodeIfPresent(String.self, forKey: .mimeTypeSnake)) ??
            (try? container.decodeIfPresent(String.self, forKey: .mimeType))
        sizeBytes =
            (try? container.decodeIfPresent(Int.self, forKey: .sizeBytesSnake)) ??
            (try? container.decodeIfPresent(Int.self, forKey: .sizeBytes))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(bucket, forKey: .bucket)
        try container.encodeIfPresent(path, forKey: .path)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(fileName, forKey: .fileNameSnake)
        try container.encodeIfPresent(mimeType, forKey: .mimeTypeSnake)
        try container.encodeIfPresent(sizeBytes, forKey: .sizeBytesSnake)
    }
}

struct CoreMessage: Identifiable, Codable, Hashable {
    var id: String
    var empresaId: Int
    var conversationId: String
    var channelId: String?
    var parentMessageId: String?
    var userId: String
    var content: String
    var editedAt: Date?
    var deletedAt: Date?
    var createdAt: Date
    var metadata: CoreMessageMetadata? = nil
    var author: CoreUserLite?
    var parent: CoreMessageQuote?
    var reactions: [CoreReaction]?
    var attachments: [CoreAttachment]?
    var replyCount: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case empresaId = "empresa_id"
        case conversationId = "conversation_id"
        case channelId = "channel_id"
        case parentMessageId = "parent_message_id"
        case userId = "user_id"
        case content
        case editedAt = "edited_at"
        case deletedAt = "deleted_at"
        case createdAt = "created_at"
        case metadata
    }

    var authorName: String {
        author?.displayName ?? "Unknown"
    }
}

struct CoreMessageQuote: Identifiable, Hashable {
    var id: String
    var content: String
    var authorName: String
}

/// Summary of one thread (root message + reply stats) used by the channel
/// threads overview.
struct CoreThreadSummary: Identifiable, Hashable {
    var root: CoreMessage
    var replyCount: Int
    var lastReplyAt: Date
    var lastReplyUserId: String?

    var id: String { root.id }
}

struct CoreSticker: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var imageURL: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case imageURL = "image_url"
    }
}

struct CorePoll: Identifiable, Hashable {
    let id: String
    let messageId: String?
    let question: String
    var options: [CorePollOption]

    var totalVotes: Int { options.reduce(0) { $0 + $1.votesCount } }
}

struct CorePollOption: Identifiable, Hashable {
    let id: String
    let label: String
    let sortOrder: Int
    var votesCount: Int
    var votedByMe: Bool
}

extension Array where Element == CoreReaction {
    var groupedByEmoji: [(emoji: String, count: Int)] {
        Dictionary(grouping: self, by: \.emoji)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.emoji < $1.emoji }
    }
}

struct CoreChannelSearchHit: Identifiable, Hashable {
    var channel: CoreChannel
    var incidenceCount: Int
    var previewSnippet: String?

    var id: String { channel.id }

    static func snippet(from content: String, keyword: String, maxLength: Int = 96) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let loweredContent = trimmed.lowercased()
        let loweredKeyword = keyword.lowercased()
        guard let range = loweredContent.range(of: loweredKeyword) else {
            return trimmed.count <= maxLength ? trimmed : String(trimmed.prefix(maxLength - 1)) + "…"
        }

        let matchStart = trimmed.distance(from: trimmed.startIndex, to: range.lowerBound)
        let contextStart = max(0, matchStart - 24)
        let startIndex = trimmed.index(trimmed.startIndex, offsetBy: contextStart)
        let endIndex = trimmed.index(
            startIndex,
            offsetBy: min(maxLength, trimmed.distance(from: startIndex, to: trimmed.endIndex)),
            limitedBy: trimmed.endIndex
        ) ?? trimmed.endIndex

        var snippet = String(trimmed[startIndex..<endIndex])
        if contextStart > 0 { snippet = "…" + snippet }
        if endIndex < trimmed.endIndex { snippet += "…" }
        return snippet
    }
}

enum CoreFormat {
    static func badgeCount(_ value: Int) -> String {
        value > 99 ? "99+" : String(value)
    }

    static func initials(_ value: String) -> String {
        let pieces = value
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
        let text = String(pieces).uppercased()
        return text.isEmpty ? "ZC" : text
    }

    static func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func conversationTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }
}
