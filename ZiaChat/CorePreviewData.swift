import Foundation

#if DEBUG
/// Datos de muestra para previews y para el modo demo (`-zia-demo`).
enum CorePreviewData {
    static let currentUserId = "preview-user"
    static let empresaId = 1
    static let generalConversationId = "preview-conversation-general"
    static let productoConversationId = "preview-conversation-producto"
    static let dmAnaId = "preview-dm-ana"
    static let dmLuisId = "preview-dm-luis"

    static let me = CoreUserLite(id: currentUserId, fullName: "Fernando Alfaro")
    static let ana = CoreUserLite(id: "ana", fullName: "Ana Martínez")
    static let luis = CoreUserLite(id: "luis", fullName: "Luis Pérez")
    static let users: [CoreUserLite] = [me, ana, luis]

    static let configuration = CoreAppConfiguration(
        supabaseURL: "https://demo.invalid",
        anonKey: "demo-anon-key",
        convexURL: "https://demo.invalid",
        accessToken: "demo-access-token",
        refreshToken: "demo-refresh-token",
        userId: currentUserId,
        empresaId: empresaId,
        displayName: "Fernando Alfaro"
    )

    static let channels: [CoreChannel] = [
        CoreChannel(
            id: "preview-general",
            empresaId: empresaId,
            name: "general",
            slug: "general",
            description: "Anuncios y coordinación de todo el equipo",
            conversationId: generalConversationId,
            unreadCount: 4
        ),
        CoreChannel(
            id: "preview-producto",
            empresaId: empresaId,
            name: "producto",
            slug: "producto",
            description: "Decisiones de producto y seguimiento",
            visibility: .private,
            conversationId: productoConversationId,
            unreadCount: 2,
            mentionCount: 1
        ),
        CoreChannel(
            id: "preview-voice",
            empresaId: empresaId,
            name: "daily-standup",
            slug: "daily-standup",
            description: "Sala de voz",
            metadata: CoreChannelMetadata(channelType: "voice", iconImage: nil),
            conversationId: "preview-conversation-voice"
        )
    ]

    static let directMessages: [CoreDirectMessage] = [
        CoreDirectMessage(
            id: dmAnaId,
            empresaId: empresaId,
            peer: ana,
            unreadCount: 2,
            lastMessageContent: "¿Me pasas el acceso al tablero?",
            lastMessageAt: today(hour: 11, minute: 5),
            lastMessageUserId: ana.id
        ),
        CoreDirectMessage(
            id: dmLuisId,
            empresaId: empresaId,
            peer: luis,
            lastMessageContent: "Va, lo vemos mañana temprano.",
            lastMessageAt: yesterday(hour: 18, minute: 42),
            lastMessageUserId: currentUserId
        )
    ]

    static let messages: [String: [CoreMessage]] = [
        generalConversationId: generalMessages,
        productoConversationId: productoMessages,
        dmAnaId: dmAnaMessages,
        dmLuisId: dmLuisMessages
    ]

    static var channelPreviews: [String: CoreMessage] {
        messages.compactMapValues(\.last)
    }

    static let pins: [String: [CoreMessagePin]] = [
        generalConversationId: [
            CoreMessagePin(
                id: "pin-g12",
                empresaId: empresaId,
                conversationId: generalConversationId,
                messageId: "g12",
                pinnedBy: ana.id,
                createdAt: today(hour: 9, minute: 15)
            )
        ]
    ]

    static let threadReplies: [String: [CoreMessage]] = [
        "g08": [
            general("g08-r1", luis, "Lo reviso ahora mismo.", at: yesterday(hour: 17, minute: 35), parent: "g08"),
            general("g08-r2", me, "Dejé dos comentarios sobre el manejo de errores.", at: yesterday(hour: 17, minute: 50), parent: "g08"),
            general("g08-r3", ana, "Gracias a los dos, ya lo mergeé.", at: yesterday(hour: 18, minute: 10), parent: "g08")
        ]
    ]

    private static let generalMessages: [CoreMessage] = {
        var list: [CoreMessage] = [
            general("g01", ana, "Buenos días equipo, arrancamos el sprint 14 hoy. Prioridades: cierre de facturación y el nuevo onboarding.", at: yesterday(hour: 9, minute: 15)),
            general("g02", ana, "Les dejo el tablero actualizado, cualquier duda me escriben.", at: yesterday(hour: 9, minute: 16)),
            general("g03", me, "Perfecto, yo tomo la parte de facturación.", at: yesterday(hour: 9, minute: 20)),
            general(
                "g04",
                luis,
                """
                Resumen de lo que hablamos con el cliente:

                1. Quieren exportar las facturas a PDF con su logo.
                2. El corte de nómina debe correr en un ambiente separado.
                3. Piden acceso de solo lectura para contabilidad.

                Yo propongo atacar primero el punto 1 porque es lo que más ruido hace.
                """,
                at: yesterday(hour: 11, minute: 40)
            ),
            general("g05", luis, "Lo discutimos en el daily de mañana.", at: yesterday(hour: 11, minute: 41)),
            general("g06", me, "Me parece bien, pero el punto 2 depende de infraestructura.", at: yesterday(hour: 15, minute: 5)),
            general("g07", me, "Ya pedí acceso al ambiente de pruebas.", at: yesterday(hour: 15, minute: 6)),
            general("g08", ana, "¿Alguien puede revisar el PR de notificaciones antes de las 6?", at: yesterday(hour: 17, minute: 30)),
            general("g09", luis, "Buenos días. Subí el resumen del daily: https://zenit.example.com/daily/2026-08-23", at: today(hour: 8, minute: 5)),
            general("g10", luis, "Incluye los acuerdos sobre facturación.", at: today(hour: 8, minute: 6)),
            general("g11", me, "Gracias, lo reviso en un rato.", at: today(hour: 8, minute: 30)),
            general("g12", ana, "📌 Recordatorio: el viernes cerramos el corte de nómina. Favor de cargar sus horas antes del jueves.", at: today(hour: 9, minute: 10)),
            general("g13", ana, "Y si tienen pendientes de vacaciones, también esta semana.", at: today(hour: 9, minute: 12)),
            general("g14", me, "Listo, ya cargué las mías.", at: today(hour: 9, minute: 40)),
            general("g15", luis, "Fernando, ¿puedes ver el ticket #4821? El cliente reporta que el PDF de la factura sale en blanco.", at: today(hour: 10, minute: 15)),
            general("g16", luis, "Te adjunto el log en el hilo.", at: today(hour: 10, minute: 16)),
            general("g17", ana, "Ya lo vi, parece que es el tamaño del logo. Lo estoy probando con un archivo más chico.", at: Date().addingTimeInterval(-20 * 60)),
            general("g18", ana, "Confirmado, con logo < 200 KB sale bien. Lo documento en el wiki.", at: Date().addingTimeInterval(-5 * 60))
        ]
        list[5].metadata = CoreMessageMetadata(
            replyTo: CoreMessageReplyTo(
                messageId: "g04",
                authorId: luis.id,
                authorName: luis.displayName,
                content: String(list[3].content.prefix(240)),
                createdAt: ISO8601DateFormatter().string(from: list[3].createdAt),
                hasAttachments: false
            )
        )
        list[6].editedAt = list[6].createdAt.addingTimeInterval(90)
        list[7].replyCount = 3
        list[11].reactions = [
            CoreReaction(id: "r1", empresaId: empresaId, messageId: "g12", userId: currentUserId, emoji: "👍", createdAt: today(hour: 9, minute: 20)),
            CoreReaction(id: "r2", empresaId: empresaId, messageId: "g12", userId: luis.id, emoji: "👍", createdAt: today(hour: 9, minute: 21)),
            CoreReaction(id: "r3", empresaId: empresaId, messageId: "g12", userId: luis.id, emoji: "🔥", createdAt: today(hour: 9, minute: 22))
        ]
        return list
    }()

    private static let productoMessages: [CoreMessage] = [
        message("p01", ana, "Propuesta: mover el onboarding a tres pasos en vez de cinco.", conversation: productoConversationId, channel: "preview-producto", at: yesterday(hour: 16, minute: 0)),
        message("p02", me, "De acuerdo, el paso de verificación se puede fusionar con el perfil.", conversation: productoConversationId, channel: "preview-producto", at: yesterday(hour: 16, minute: 20)),
        message("p03", luis, "@Fernando Alfaro ¿revisas el prototipo antes del jueves?", conversation: productoConversationId, channel: "preview-producto", at: today(hour: 10, minute: 45)),
        message("p04", luis, "Está en Figma, carpeta Onboarding v3.", conversation: productoConversationId, channel: "preview-producto", at: today(hour: 10, minute: 46))
    ]

    private static let dmAnaMessages: [CoreMessage] = [
        message("da01", me, "Ana, ¿ya quedó el reporte de ventas?", conversation: dmAnaId, channel: nil, at: today(hour: 10, minute: 50)),
        message("da02", ana, "Casi, me falta la parte de Monterrey.", conversation: dmAnaId, channel: nil, at: today(hour: 11, minute: 2)),
        message("da03", ana, "¿Me pasas el acceso al tablero?", conversation: dmAnaId, channel: nil, at: today(hour: 11, minute: 5))
    ]

    private static let dmLuisMessages: [CoreMessage] = [
        message("dl01", luis, "¿Tienes un rato para ver lo del deploy?", conversation: dmLuisId, channel: nil, at: yesterday(hour: 18, minute: 30)),
        message("dl02", me, "Va, lo vemos mañana temprano.", conversation: dmLuisId, channel: nil, at: yesterday(hour: 18, minute: 42))
    ]

    /// Página sintética de mensajes anteriores al más antiguo cargado, para
    /// ejercitar la paginación hacia arriba sin servidor.
    static func olderPage(before oldest: CoreMessage, count: Int = 21) -> [CoreMessage] {
        let authors = [ana, luis, me]
        return (0..<count).map { offset in
            let index = count - offset
            let author = authors[index % authors.count]
            return message(
                "\(oldest.id)-older-\(index)",
                author,
                "Mensaje anterior #\(index) del historial de \(author.displayName.split(separator: " ").first ?? "").",
                conversation: oldest.conversationId,
                channel: oldest.channelId,
                at: oldest.createdAt.addingTimeInterval(-Double(index) * 7 * 60)
            )
        }
    }

    private static func general(
        _ id: String,
        _ author: CoreUserLite,
        _ content: String,
        at date: Date,
        parent: String? = nil
    ) -> CoreMessage {
        message(id, author, content, conversation: generalConversationId, channel: "preview-general", at: date, parent: parent)
    }

    private static func message(
        _ id: String,
        _ author: CoreUserLite,
        _ content: String,
        conversation: String,
        channel: String?,
        at date: Date,
        parent: String? = nil
    ) -> CoreMessage {
        CoreMessage(
            id: id,
            empresaId: empresaId,
            conversationId: conversation,
            channelId: channel,
            parentMessageId: parent,
            userId: author.id,
            content: content,
            createdAt: date,
            author: author
        )
    }

    /// Las horas fijas de hoy se corren hacia atrás si la app se lanza antes
    /// de la última (11:05) para que ningún mensaje quede en el futuro.
    private static let todayShift: TimeInterval = {
        let latest = fixedToday(hour: 11, minute: 5)
        return max(0, latest.timeIntervalSince(Date().addingTimeInterval(-25 * 60)))
    }()

    private static func fixedToday(hour: Int, minute: Int) -> Date {
        let start = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: start) ?? start
    }

    private static func today(hour: Int, minute: Int) -> Date {
        fixedToday(hour: hour, minute: minute).addingTimeInterval(-todayShift)
    }

    private static func yesterday(hour: Int, minute: Int) -> Date {
        fixedToday(hour: hour, minute: minute).addingTimeInterval(-86_400)
    }
}
#endif
