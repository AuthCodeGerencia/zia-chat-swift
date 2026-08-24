import Foundation

// Modelos de la bandeja de WhatsApp. Son el espejo Swift de
// `authcode-app/src/chat/types.ts`: la misma API `mobileChat.*` del portal
// de AuthCode sirve a las dos apps, así que los campos coinciden 1:1.

/// Permisos del perfil de AuthCode sobre el chat (`mobileChat.misPermisos`).
nonisolated struct WhatsAppCaps: Decodable, Equatable, Sendable {
    var read = false
    var readAll = false
    var send = false
    var assign = false

    static let none = WhatsAppCaps()
}

/// Perfil del portal de AuthCode resuelto por el correo del usuario de Zia.
nonisolated struct WhatsAppProfile: Decodable, Equatable, Sendable {
    var id: String
    var name: String
    var email: String
    var role: String

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case name
        case email
        case role
    }
}

enum WhatsAppFilter: String, CaseIterable, Identifiable, Sendable {
    case todos
    case sinAsignar = "sin_asignar"
    case mios
    case privados
    case grupos
    case cerrados

    var id: String { rawValue }

    var title: String {
        switch self {
        case .todos: return "Abiertos"
        case .sinAsignar: return "Sin asignar"
        case .mios: return "Míos"
        case .privados: return "Privados"
        case .grupos: return "Grupos"
        case .cerrados: return "Cerrados"
        }
    }
}

enum WhatsAppChatState: String, Decodable, CaseIterable, Sendable {
    case abierto
    case pendiente
    case cerrado

    var title: String {
        switch self {
        case .abierto: return "Abierto"
        case .pendiente: return "Pendiente"
        case .cerrado: return "Cerrado"
        }
    }
}

/// Unidades de negocio del portal (`lib/unidadesNegocio.ts`).
enum WhatsAppBusinessUnit: String, CaseIterable, Identifiable, Sendable {
    case iobot = "IOBOT"
    case iocall = "IOCALL"
    case iodelivery = "IODELIVERY"
    case iopos = "IOPOS"
    case iopay = "IOPAY"
    case authcode = "AUTHCODE"

    var id: String { rawValue }
}

nonisolated struct WhatsAppAgent: Decodable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var role: String?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case name
        case role
    }
}

nonisolated struct WhatsAppCompany: Decodable, Identifiable, Equatable, Sendable {
    var id: String
    var nombre: String

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case nombre
    }
}

nonisolated struct WhatsAppParticipant: Decodable, Identifiable, Equatable, Sendable {
    var waId: String
    var telefono: String?
    var esAdmin: Bool
    var nombre: String
    var avatarUrl: String?
    var aliases: [String]?

    var id: String { waId }
    var avatarURL: URL? { avatarUrl.flatMap(URL.init(string:)) }
}

nonisolated struct WhatsAppChat: Decodable, Identifiable, Equatable, Sendable {
    var id: String
    var chatId: String
    var isGroup: Bool
    var nombreVisible: String
    var telefono: String?
    var pictureUrl: String?
    var lastMessageAt: Double
    var lastMessagePreview: String?
    var lastMessageFromMe: Bool?
    var unreadCount: Int
    var estado: WhatsAppChatState
    var silenciado: Bool?
    var agente: WhatsAppAgent?
    var assignedToIds: [String]
    var assignedAgents: [WhatsAppAgent]
    var empresaNombre: String?
    var unidadNegocio: String?
    var clienteNombre: String?
    var clienteEtiqueta: String?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case chatId
        case isGroup
        case nombreVisible
        case telefono
        case pictureUrl
        case lastMessageAt
        case lastMessagePreview
        case lastMessageFromMe
        case unreadCount
        case estado
        case silenciado
        case agente
        case assignedToIds
        case assignedAgents
        case empresaNombre
        case unidadNegocio
        case clienteNombre
        case clienteEtiqueta
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        chatId = try container.decode(String.self, forKey: .chatId)
        isGroup = try container.decodeIfPresent(Bool.self, forKey: .isGroup) ?? false
        nombreVisible = try container.decodeIfPresent(String.self, forKey: .nombreVisible) ?? chatId
        telefono = try container.decodeIfPresent(String.self, forKey: .telefono)
        pictureUrl = try container.decodeIfPresent(String.self, forKey: .pictureUrl)
        lastMessageAt = try container.decodeIfPresent(Double.self, forKey: .lastMessageAt) ?? 0
        lastMessagePreview = try container.decodeIfPresent(String.self, forKey: .lastMessagePreview)
        lastMessageFromMe = try container.decodeIfPresent(Bool.self, forKey: .lastMessageFromMe)
        // Convex serializa Float64 como `0.0`; `Int` no lo decodifica.
        unreadCount = Int((try? container.decodeIfPresent(Double.self, forKey: .unreadCount)) ?? 0)
        estado = try container.decodeIfPresent(WhatsAppChatState.self, forKey: .estado) ?? .abierto
        silenciado = try container.decodeIfPresent(Bool.self, forKey: .silenciado)
        agente = try container.decodeIfPresent(WhatsAppAgent.self, forKey: .agente)
        assignedToIds = try container.decodeIfPresent([String].self, forKey: .assignedToIds)
            ?? agente.map { [$0.id] }
            ?? []
        assignedAgents = try container.decodeIfPresent([WhatsAppAgent].self, forKey: .assignedAgents)
            ?? agente.map { [$0] }
            ?? []
        empresaNombre = try container.decodeIfPresent(String.self, forKey: .empresaNombre)
        unidadNegocio = try container.decodeIfPresent(String.self, forKey: .unidadNegocio)
        clienteNombre = try container.decodeIfPresent(String.self, forKey: .clienteNombre)
        clienteEtiqueta = try container.decodeIfPresent(String.self, forKey: .clienteEtiqueta)
    }

    var lastMessageDate: Date { Date(timeIntervalSince1970: lastMessageAt / 1_000) }
    var pictureURL: URL? { pictureUrl.flatMap(URL.init(string:)) }
    var isMuted: Bool { silenciado == true }

    var subtitleTags: String? {
        let parts = [unidadNegocio, empresaNombre ?? clienteNombre].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

nonisolated struct WhatsAppQuotedMessage: Decodable, Equatable, Sendable {
    var id: String?
    var body: String
    var author: String?
}

nonisolated struct WhatsAppMedia: Decodable, Equatable, Sendable {
    var storageId: String?
    var mimetype: String?
    var filename: String?
    var size: Double?
    var estado: String

    var isImage: Bool { mimetype?.hasPrefix("image/") == true }
    var isVideo: Bool { mimetype?.hasPrefix("video/") == true }
    var isAudio: Bool { mimetype?.hasPrefix("audio/") == true }
}

nonisolated struct WhatsAppReaction: Decodable, Equatable, Sendable {
    var emoji: String
    var waId: String
}

nonisolated struct WhatsAppMessage: Decodable, Identifiable, Equatable, Sendable {
    var id: String
    var chatId: String
    var fromMe: Bool
    var tipo: String
    var body: String?
    var timestamp: Double
    var estado: String
    var ack: Int?
    var error: String?
    var waMessageId: String?
    var quotedMessageId: String?
    var quotedMessage: WhatsAppQuotedMessage?
    var authorWaId: String?
    var authorName: String?
    var autorNombre: String?
    var autorAvatarUrl: String?
    var agenteNombre: String?
    var mediaUrl: String?
    var media: WhatsAppMedia?
    var reactions: [WhatsAppReaction]?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case chatId
        case fromMe
        case tipo
        case body
        case timestamp
        case estado
        case ack
        case error
        case waMessageId
        case quotedMessageId
        case quotedMessage
        case authorWaId
        case authorName
        case autorNombre
        case autorAvatarUrl
        case agenteNombre
        case mediaUrl
        case media
        case reactions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        chatId = try container.decodeIfPresent(String.self, forKey: .chatId) ?? ""
        fromMe = try container.decodeIfPresent(Bool.self, forKey: .fromMe) ?? false
        tipo = try container.decodeIfPresent(String.self, forKey: .tipo) ?? "chat"
        body = try container.decodeIfPresent(String.self, forKey: .body)
        timestamp = try container.decodeIfPresent(Double.self, forKey: .timestamp) ?? 0
        estado = try container.decodeIfPresent(String.self, forKey: .estado) ?? "recibido"
        ack = (try? container.decodeIfPresent(Double.self, forKey: .ack)).flatMap { $0 }.map { Int($0) }
        error = try container.decodeIfPresent(String.self, forKey: .error)
        waMessageId = try container.decodeIfPresent(String.self, forKey: .waMessageId)
        quotedMessageId = try container.decodeIfPresent(String.self, forKey: .quotedMessageId)
        quotedMessage = try container.decodeIfPresent(WhatsAppQuotedMessage.self, forKey: .quotedMessage)
        authorWaId = try container.decodeIfPresent(String.self, forKey: .authorWaId)
        authorName = try container.decodeIfPresent(String.self, forKey: .authorName)
        autorNombre = try container.decodeIfPresent(String.self, forKey: .autorNombre)
        autorAvatarUrl = try container.decodeIfPresent(String.self, forKey: .autorAvatarUrl)
        agenteNombre = try container.decodeIfPresent(String.self, forKey: .agenteNombre)
        mediaUrl = try container.decodeIfPresent(String.self, forKey: .mediaUrl)
        media = try container.decodeIfPresent(WhatsAppMedia.self, forKey: .media)
        reactions = try container.decodeIfPresent([WhatsAppReaction].self, forKey: .reactions)
    }

    var date: Date { Date(timeIntervalSince1970: timestamp / 1_000) }
    var isNote: Bool { tipo == "nota" }
    var isSystem: Bool { tipo == "system" }
    /// Burbuja alineada a la derecha: enviado por un agente, pero no una nota.
    var isMine: Bool { fromMe && !isNote }
    var mediaURL: URL? { mediaUrl.flatMap(URL.init(string:)) }
    var isImage: Bool { tipo == "image" || tipo == "sticker" || media?.isImage == true }
    var isSticker: Bool { tipo == "sticker" }

    var displayAuthor: String {
        autorNombre ?? agenteNombre ?? authorName ?? "Contacto"
    }

    var authorKey: String {
        authorWaId ?? autorNombre ?? authorName ?? agenteNombre ?? (fromMe ? "__mine__" : id)
    }

    /// Texto para la cita y el preview: cuerpo o nombre del adjunto.
    var quotePreview: String {
        if let body, !body.isEmpty { return body }
        if let filename = media?.filename, !filename.isEmpty { return filename }
        return "Adjunto"
    }

    /// El portal guarda el nombre del archivo como `body` en imágenes sin
    /// caption; en ese caso no se repite debajo de la foto.
    var visibleBody: String? {
        guard let body, !body.isEmpty else { return nil }
        if isImage, let filename = media?.filename, filename == body { return nil }
        return body
    }
}

nonisolated struct WhatsAppSessionStatus: Decodable, Equatable, Sendable {
    var status: String?
    var name: String?
    var meId: String?
    var mePushName: String?

    var isWorking: Bool { status == nil || status == "WORKING" }
    var needsQR: Bool { status == "SCAN_QR_CODE" }
}

/// Página de `mobileChat.listarChats` (paginación estándar de Convex).
nonisolated struct WhatsAppChatPage: Decodable, Sendable {
    var page: [WhatsAppChat]
    var isDone: Bool
    var continueCursor: String?
}

nonisolated enum WhatsAppRoute {
    /// Las rutas del `NavigationStack` son IDs de canal; la bandeja de WhatsApp
    /// usa el mismo tipo con un prefijo para no tocar el resto de la navegación.
    static let prefix = "whatsapp:"

    static func navigationId(for chatId: String) -> String {
        prefix + chatId
    }

    static func chatId(from navigationId: String) -> String? {
        guard navigationId.hasPrefix(prefix) else { return nil }
        return String(navigationId.dropFirst(prefix.count))
    }
}

enum WhatsAppFormat {
    static func listTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "Ayer"
        }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    static func bubbleTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func phone(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.hasPrefix("+") ? raw : "+\(raw)"
    }
}
