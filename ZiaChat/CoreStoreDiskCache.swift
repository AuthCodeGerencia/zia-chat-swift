import Foundation

nonisolated struct CoreStoreCacheSnapshot: Codable, Sendable {
    var channels: [CoreChannel]
    var directMessages: [CoreDirectMessage]
    var channelPreviews: [String: CachedMessage]
}

nonisolated struct CoreChatListCachePayload: Codable, Sendable {
    var directMessages: [CoreDirectMessage]
    var channelPreviews: [String: CachedMessage]
}

/// Mensaje serializable completo: los `CodingKeys` de `CoreMessage` solo
/// cubren las columnas del servidor y descartan autor, reacciones y adjuntos.
nonisolated struct CachedMessage: Codable, Sendable {
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
    var metadata: CoreMessageMetadata?
    var author: CoreUserLite?
    var reactions: [CoreReaction]?
    var attachments: [CoreAttachment]?
    var replyCount: Int?
}

extension CachedMessage {
    @MainActor
    init(_ message: CoreMessage) {
        id = message.id
        empresaId = message.empresaId
        conversationId = message.conversationId
        channelId = message.channelId
        parentMessageId = message.parentMessageId
        userId = message.userId
        content = message.content
        editedAt = message.editedAt
        deletedAt = message.deletedAt
        createdAt = message.createdAt
        metadata = message.metadata
        author = message.author
        reactions = message.reactions
        attachments = message.attachments
        replyCount = message.replyCount
    }

    @MainActor
    var coreMessage: CoreMessage {
        CoreMessage(
            id: id,
            empresaId: empresaId,
            conversationId: conversationId,
            channelId: channelId,
            parentMessageId: parentMessageId,
            userId: userId,
            content: content,
            editedAt: editedAt,
            deletedAt: deletedAt,
            createdAt: createdAt,
            metadata: metadata,
            author: author,
            reactions: reactions,
            attachments: attachments,
            replyCount: replyCount
        )
    }
}

/// Últimos mensajes de cada conversación en disco (un JSON por conversación)
/// para abrir el chat sin esperar la primera página del servidor.
nonisolated enum CoreMessagesCache {
    static let limit = 30
    private static let writeQueue = DispatchQueue(label: "zia.messages-cache", qos: .utility)

    private static func directory(userId: String) -> URL? {
        guard !userId.isEmpty,
              let key = userId.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return root.appendingPathComponent("zia-messages-\(key)", isDirectory: true)
    }

    private static func fileURL(userId: String, conversationId: String) -> URL? {
        guard let directory = directory(userId: userId),
              let name = conversationId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            return nil
        }
        return directory.appendingPathComponent("\(name).json")
    }

    static func load(userId: String, conversationId: String) -> [CachedMessage]? {
        guard let url = fileURL(userId: userId, conversationId: conversationId),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([CachedMessage].self, from: data)
    }

    static func scheduleWrite(_ messages: [CachedMessage], userId: String, conversationId: String) {
        writeQueue.async {
            guard let url = fileURL(userId: userId, conversationId: conversationId) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let data = try? JSONEncoder().encode(messages) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    static func removeAll(userId: String) {
        guard let directory = directory(userId: userId) else { return }
        writeQueue.async {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

/// Caché en disco de la lista de chats. Los íconos y fondos `data:` se
/// guardan en archivos aparte para que el JSON principal sea pequeño y su
/// lectura en el arranque no pese.
nonisolated enum CoreStoreDiskCache {
    private static let iconSuffix = ".icon"
    private static let backgroundSuffix = ".bg"
    private static let legacyDefaultsPrefixes = ["zia-chat.channels.", "zia-chat.chat-list."]

    private static var rootDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }

    private static var iconsDirectory: URL? {
        rootDirectory?.appendingPathComponent("zia-channel-icons", isDirectory: true)
    }

    private static func channelsURL(userId: String) -> URL? {
        guard !userId.isEmpty, let key = safeFileName(userId) else { return nil }
        return rootDirectory?.appendingPathComponent("zia-channels-\(key).json")
    }

    private static func chatListURL(userId: String) -> URL? {
        guard !userId.isEmpty, let key = safeFileName(userId) else { return nil }
        return rootDirectory?.appendingPathComponent("zia-chatlist-\(key).json")
    }

    private static func safeFileName(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
    }

    static func loadChannels(userId: String) -> [CoreChannel]? {
        guard let url = channelsURL(userId: userId), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([CoreChannel].self, from: data)
    }

    static func loadChatList(userId: String) -> CoreChatListCachePayload? {
        guard let url = chatListURL(userId: userId), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CoreChatListCachePayload.self, from: data)
    }

    /// Versiones anteriores guardaban los blobs en UserDefaults; se descartan
    /// para que no se sigan cargando en cada arranque.
    static func removeLegacyDefaults() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where legacyDefaultsPrefixes.contains(where: { key.hasPrefix($0) }) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Devuelve los canales con los íconos/fondos `data:` leídos de disco.
    static func restoringInlineImages(_ channels: [CoreChannel]) -> [CoreChannel] {
        guard let directory = iconsDirectory else { return channels }
        return channels.map { channel in
            // Los inits de los modelos están aislados al main actor; aquí solo
            // se completan metadatos/temas ya existentes.
            guard var metadata = channel.metadata else { return channel }
            var updated = channel
            if metadata.iconImage?.isEmpty != false,
               let icon = readImage(directory: directory, channelId: channel.id, suffix: iconSuffix) {
                metadata.iconImage = icon
            }
            if var theme = metadata.theme, theme.backgroundImage?.isEmpty != false,
               let background = readImage(directory: directory, channelId: channel.id, suffix: backgroundSuffix) {
                theme.backgroundImage = background
                metadata.theme = theme
            }
            updated.metadata = metadata
            return updated
        }
    }

    /// Las escrituras se serializan para que una instantánea vieja y lenta
    /// (con íconos) no termine después de una más reciente.
    private static let writeQueue = DispatchQueue(label: "zia.store-cache", qos: .utility)

    static func scheduleWrite(_ snapshot: CoreStoreCacheSnapshot, userId: String) {
        writeQueue.async {
            write(snapshot, userId: userId)
        }
    }

    private static func write(_ snapshot: CoreStoreCacheSnapshot, userId: String) {
        guard let channelsURL = channelsURL(userId: userId),
              let chatListURL = chatListURL(userId: userId) else { return }
        let encoder = JSONEncoder()
        let strippedChannels = persistingInlineImages(snapshot.channels)
        if let data = try? encoder.encode(strippedChannels) {
            try? data.write(to: channelsURL, options: .atomic)
        }
        let payload = CoreChatListCachePayload(
            directMessages: snapshot.directMessages,
            channelPreviews: snapshot.channelPreviews
        )
        if let data = try? encoder.encode(payload) {
            try? data.write(to: chatListURL, options: .atomic)
        }
    }

    private static func readImage(directory: URL, channelId: String, suffix: String) -> String? {
        guard let name = safeFileName(channelId) else { return nil }
        let url = directory.appendingPathComponent(name + suffix)
        guard let data = try? Data(contentsOf: url), let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Guarda cada imagen `data:` en su archivo (una sola vez mientras no
    /// cambie de tamaño) y devuelve la copia sin imágenes para codificar.
    private static func persistingInlineImages(_ channels: [CoreChannel]) -> [CoreChannel] {
        guard let directory = iconsDirectory else { return channels }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var keep: Set<String> = []

        let stripped = channels.map { channel -> CoreChannel in
            var updated = channel
            guard let name = safeFileName(channel.id) else { return updated }
            if let icon = updated.metadata?.iconImage, icon.hasPrefix("data:") {
                let fileName = name + iconSuffix
                keep.insert(fileName)
                store(icon, at: directory.appendingPathComponent(fileName))
                updated.metadata?.iconImage = nil
            }
            if let background = updated.metadata?.theme?.backgroundImage, background.hasPrefix("data:") {
                let fileName = name + backgroundSuffix
                keep.insert(fileName)
                store(background, at: directory.appendingPathComponent(fileName))
                updated.metadata?.theme?.backgroundImage = nil
            }
            return updated
        }

        if let existing = try? fileManager.contentsOfDirectory(atPath: directory.path) {
            for fileName in existing where !keep.contains(fileName) {
                try? fileManager.removeItem(at: directory.appendingPathComponent(fileName))
            }
        }
        return stripped
    }

    private static func store(_ value: String, at url: URL) {
        let data = Data(value.utf8)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           (attributes[.size] as? NSNumber)?.intValue == data.count {
            return
        }
        try? data.write(to: url, options: .atomic)
    }
}
