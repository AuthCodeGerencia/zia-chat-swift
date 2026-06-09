import Foundation
import SwiftUI

enum CoreChannelVisibility: String, Codable, CaseIterable, Hashable {
    case `public`
    case `private`
}

struct CoreChannelMetadata: Codable, Hashable {
    var channelType: String?
    var iconImage: String?
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
        return visibility == .private ? "lock.fill" : "number"
    }

    var tint: Color {
        if isVoice { return .blue }
        return visibility == .private ? .purple : .teal
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
        guard let mimeType else { return "paperclip" }
        if mimeType.hasPrefix("image/") { return "photo" }
        if mimeType.contains("pdf") { return "doc.richtext" }
        return "paperclip"
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

extension Array where Element == CoreReaction {
    var groupedByEmoji: [(emoji: String, count: Int)] {
        Dictionary(grouping: self, by: \.emoji)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.emoji < $1.emoji }
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
}
