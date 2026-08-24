import Combine
@preconcurrency import ConvexMobile
import Foundation

/// Cliente del Convex del portal de AuthCode (repo `authcode-tickets`).
///
/// La bandeja de WhatsApp de Zia es la misma que la de authcode-app: ambas
/// consumen `mobileChat.*`, que se autentica con el `profileId` del portal.
/// El perfil se resuelve por el correo de la sesión de Zia. Es un deployment
/// distinto al de Zia, así que lleva su propio cliente de websocket.
final class WhatsAppConvexClient: @unchecked Sendable {
    nonisolated(unsafe) private let realtime: ConvexClient
    private let baseURL: URL
    private let decoder: JSONDecoder

    nonisolated init(deploymentURL: String) throws {
        let raw = deploymentURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !raw.isEmpty, let url = URL(string: raw) else { throw ConvexCoreError.invalidURL }
        baseURL = url
        realtime = ConvexClient(deploymentUrl: raw)
        decoder = ConvexCoreClient.makeDecoder()
    }

    // MARK: - Perfil

    /// Busca el perfil del portal por correo (el portal aplica `ZIA_EMAIL_MAP`
    /// cuando el correo de Zia no coincide). `nil` cuando no existe: el usuario
    /// de Zia no es agente de AuthCode y la bandeja no se muestra.
    func resolveProfile(email: String) async throws -> WhatsAppProfile? {
        do {
            return try await query("mobileChat:perfilPorCorreo", ["email": email])
        } catch ConvexCoreError.server {
            // Portal aún sin `perfilPorCorreo` desplegado (en producción el
            // error no distingue "función inexistente"): la búsqueda directa
            // por correo funciona igual, solo que sin el mapeo de correos.
            return try await query("profile:getProfileByEmail2", ["email": email])
        }
    }

    // MARK: - Suscripciones

    func subscribeCaps(profileId: String) -> AnyPublisher<WhatsAppCaps, ClientError> {
        realtime.subscribe(to: "mobileChat:misPermisos", with: ["profileId": profileId], yielding: WhatsAppCaps.self)
    }

    func subscribeSession(profileId: String) -> AnyPublisher<WhatsAppSessionStatus?, ClientError> {
        realtime.subscribe(to: "mobileChat:estadoSesion", with: ["profileId": profileId], yielding: WhatsAppSessionStatus?.self)
    }

    func subscribeUnreadCount(profileId: String) -> AnyPublisher<Double, ClientError> {
        realtime.subscribe(to: "mobileChat:contarNoLeidos", with: ["profileId": profileId], yielding: Double.self)
    }

    func subscribeChats(
        profileId: String,
        filter: WhatsAppFilter,
        search: String,
        numItems: Int
    ) -> AnyPublisher<WhatsAppChatPage, ClientError> {
        var args: [String: ConvexEncodable?] = [
            "profileId": profileId,
            "filtro": filter.rawValue,
            // `numItems` es Float64 en Convex; Int se codificaría como Int64.
            "paginationOpts": ["numItems": Double(numItems), "cursor": nil] as [String: ConvexEncodable?],
        ]
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { args["busqueda"] = trimmed }
        return realtime.subscribe(to: "mobileChat:listarChats", with: args, yielding: WhatsAppChatPage.self)
    }

    func subscribeChat(profileId: String, chatId: String) -> AnyPublisher<WhatsAppChat?, ClientError> {
        realtime.subscribe(
            to: "mobileChat:obtenerChat",
            with: ["profileId": profileId, "chatId": chatId],
            yielding: WhatsAppChat?.self
        )
    }

    func subscribeMessages(profileId: String, chatId: String, limit: Int) -> AnyPublisher<[WhatsAppMessage], ClientError> {
        realtime.subscribe(
            to: "mobileChat:listarMensajes",
            with: ["profileId": profileId, "chatId": chatId, "limite": Double(limit)],
            yielding: [WhatsAppMessage].self
        )
    }

    func subscribeAgents(profileId: String) -> AnyPublisher<[WhatsAppAgent], ClientError> {
        realtime.subscribe(to: "mobileChat:agentesAsignables", with: ["profileId": profileId], yielding: [WhatsAppAgent].self)
    }

    func subscribeCompanies(profileId: String) -> AnyPublisher<[WhatsAppCompany], ClientError> {
        realtime.subscribe(to: "mobileChat:listarEmpresas", with: ["profileId": profileId], yielding: [WhatsAppCompany].self)
    }

    // MARK: - Mutaciones

    func sendText(profileId: String, chatId: String, body: String, quotedMessageId: String?) async throws {
        var args: [String: ConvexEncodable?] = ["profileId": profileId, "chatId": chatId, "body": body]
        if let quotedMessageId { args["quotedMessageId"] = quotedMessageId }
        try await realtime.mutation("mobileChat:enviarTexto", with: args)
    }

    func sendFile(
        profileId: String,
        chatId: String,
        storageId: String,
        filename: String,
        mimetype: String?,
        caption: String?
    ) async throws {
        var args: [String: ConvexEncodable?] = [
            "profileId": profileId,
            "chatId": chatId,
            "storageId": storageId,
            "filename": filename,
        ]
        if let mimetype { args["mimetype"] = mimetype }
        if let caption, !caption.isEmpty { args["caption"] = caption }
        try await realtime.mutation("mobileChat:enviarArchivo", with: args)
    }

    func addNote(profileId: String, chatId: String, body: String) async throws {
        try await realtime.mutation("mobileChat:agregarNota", with: ["profileId": profileId, "chatId": chatId, "body": body])
    }

    func markRead(profileId: String, chatId: String) async throws {
        try await realtime.mutation("mobileChat:marcarLeido", with: ["profileId": profileId, "chatId": chatId])
    }

    func assign(profileId: String, chatId: String, assignedTo: String?) async throws {
        var args: [String: ConvexEncodable?] = ["profileId": profileId, "chatId": chatId]
        if let assignedTo { args["assignedTo"] = assignedTo }
        try await realtime.mutation("mobileChat:asignarChat", with: args)
    }

    func setState(profileId: String, chatId: String, state: WhatsAppChatState) async throws {
        try await realtime.mutation(
            "mobileChat:cambiarEstado",
            with: ["profileId": profileId, "chatId": chatId, "estado": state.rawValue]
        )
    }

    func mute(profileId: String, chatId: String, muted: Bool) async throws {
        try await realtime.mutation(
            "mobileChat:silenciarChat",
            with: ["profileId": profileId, "chatId": chatId, "silenciado": muted]
        )
    }

    /// `clasificarChat` acepta `null` explícito para limpiar un campo; un campo
    /// ausente se deja como está. Por eso cada argumento es opcional dos veces.
    func classify(
        profileId: String,
        chatId: String,
        businessUnit: String?? = nil,
        companyId: String?? = nil,
        clientName: String?? = nil
    ) async throws {
        var args: [String: ConvexEncodable?] = ["profileId": profileId, "chatId": chatId]
        if let businessUnit { args["unidadNegocio"] = businessUnit }
        if let companyId { args["empresa"] = companyId }
        if let clientName { args["clienteNombre"] = clientName }
        try await realtime.mutation("mobileChat:clasificarChat", with: args)
    }

    func retrySend(profileId: String, messageId: String) async throws {
        try await realtime.mutation("mobileChat:reintentarEnvio", with: ["profileId": profileId, "messageId": messageId])
    }

    // MARK: - Archivos

    /// Sube el adjunto al storage del portal y devuelve su `storageId`.
    func upload(_ attachment: CorePendingAttachment, profileId: String) async throws -> String {
        let uploadURL: String = try await realtime.mutation("mobileChat:generarUploadUrl", with: ["profileId": profileId])
        guard let url = URL(string: uploadURL) else { throw ConvexCoreError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(attachment.mimeType, forHTTPHeaderField: "Content-Type")
        let data: Data
        let response: URLResponse
        if attachment.isFileBacked, let fileURL = attachment.fileURL {
            (data, response) = try await ConvexCoreClient.uploadSession.upload(for: request, fromFile: fileURL)
        } else {
            (data, response) = try await ConvexCoreClient.uploadSession.upload(for: request, from: attachment.data)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ConvexCoreError.server(String(data: data, encoding: .utf8) ?? "No se pudo subir el archivo")
        }
        let payload = try JSONDecoder().decode(WhatsAppUploadResponse.self, from: data)
        return payload.storageId
    }

    // MARK: - HTTP (consultas de una sola vez)

    private func query<T: Decodable>(_ path: String, _ args: [String: Any]) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent("api").appendingPathComponent("query"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ios-zia-chat-whatsapp", forHTTPHeaderField: "Convex-Client")
        let body: [String: Any] = [
            "path": path,
            "format": "convex_encoded_json",
            "args": [ConvexCoreClient.jsonReady(args)],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await ConvexCoreClient.apiSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 560 else {
            throw ConvexCoreError.server(String(data: data, encoding: .utf8) ?? "Convex request failed")
        }
        let envelope = try decoder.decode(ConvexEnvelope<CoreJSONAny>.self, from: data)
        guard envelope.status == "success" else {
            throw ConvexCoreError.server(envelope.errorMessage ?? "Convex request failed")
        }
        guard let value = envelope.value?.value, !(value is NSNull) else {
            // `T` es opcional en las consultas que pueden devolver null.
            let valueData = Data("null".utf8)
            return try decoder.decode(T.self, from: valueData)
        }
        let valueData = try ConvexCoreClient.dataFromJSONValue(ConvexCoreClient.jsonFromConvex(value))
        return try decoder.decode(T.self, from: valueData)
    }
}

private nonisolated struct WhatsAppUploadResponse: Decodable, Sendable {
    var storageId: String
}

extension ClientError {
    /// Mensaje legible para la UI; los errores de Convex llegan con el
    /// prefijo del request ID, que no aporta nada al usuario.
    var whatsAppMessage: String {
        let text: String
        switch self {
        case .InternalError(let msg), .ServerError(let msg):
            text = msg
        case .ConvexError(let data):
            text = data
        }
        if let range = text.range(of: "Uncaught Error: ") {
            let rest = text[range.upperBound...]
            return String(rest.split(separator: "\n").first ?? rest)
        }
        return text
    }
}
