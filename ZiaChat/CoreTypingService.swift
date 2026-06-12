import Combine
import Foundation
import Supabase

/// Indicador de "escribiendo…" con paridad a la web (services/core/typing.ts):
/// canal realtime `core:conversation:{id}:typing`, evento broadcast "typing",
/// payload {userId, userName, isTyping, parentMessageId}.
@MainActor
final class CoreTypingService: ObservableObject {
    @Published private(set) var typingNames: [String] = []

    private var client: SupabaseClient?
    private var channel: RealtimeChannelV2?
    private var listenTask: Task<Void, Never>?
    private var expiryTasks: [String: Task<Void, Never>] = [:]
    private var namesByUserId: [String: String] = [:]
    private var connectedConversationId: String?
    private var lastTypingSentAt: Date = .distantPast
    private var idleTask: Task<Void, Never>?

    var typingLabel: String? {
        guard !typingNames.isEmpty else { return nil }
        if typingNames.count == 1 {
            return "\(typingNames[0]) está escribiendo…"
        }
        return "\(typingNames.joined(separator: ", ")) están escribiendo…"
    }

    func connect(conversationId: String, configuration: CoreAppConfiguration) async {
        if connectedConversationId == conversationId, channel != nil { return }
        await disconnect()
        guard configuration.isUsable, let url = URL(string: configuration.supabaseURL) else { return }

        let client = SupabaseClient(
            supabaseURL: url,
            supabaseKey: configuration.anonKey,
            options: SupabaseClientOptions(
                auth: .init(
                    accessToken: {
                        configuration.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                )
            )
        )
        self.client = client
        connectedConversationId = conversationId

        let channel = client.channel("core:conversation:\(conversationId):typing")
        self.channel = channel
        let stream = channel.broadcastStream(event: "typing")
        let currentUserId = configuration.userId
        listenTask = Task { [weak self] in
            for await message in stream {
                await self?.handle(message, currentUserId: currentUserId)
            }
        }
        try? await channel.subscribe()
    }

    func disconnect() async {
        listenTask?.cancel()
        listenTask = nil
        idleTask?.cancel()
        idleTask = nil
        expiryTasks.values.forEach { $0.cancel() }
        expiryTasks.removeAll()
        namesByUserId.removeAll()
        typingNames = []
        connectedConversationId = nil
        if let channel {
            await channel.unsubscribe()
            if let client {
                await client.removeChannel(channel)
            }
        }
        channel = nil
        client = nil
    }

    /// Notifica que el usuario está escribiendo (throttle de 2 s) y programa el
    /// "dejó de escribir" tras 3 s de inactividad.
    func userIsTyping(configuration: CoreAppConfiguration) {
        let now = Date()
        if now.timeIntervalSince(lastTypingSentAt) > 2 {
            lastTypingSentAt = now
            send(isTyping: true, configuration: configuration)
        }
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.send(isTyping: false, configuration: configuration)
            self?.lastTypingSentAt = .distantPast
        }
    }

    func userStoppedTyping(configuration: CoreAppConfiguration) {
        idleTask?.cancel()
        idleTask = nil
        lastTypingSentAt = .distantPast
        send(isTyping: false, configuration: configuration)
    }

    private func send(isTyping: Bool, configuration: CoreAppConfiguration) {
        guard let channel else { return }
        let name = configuration.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: JSONObject = [
            "userId": .string(configuration.userId),
            "userName": .string(name.isEmpty ? "Usuario Core" : name),
            "isTyping": .bool(isTyping),
            "parentMessageId": .null
        ]
        Task {
            try? await channel.broadcast(event: "typing", message: payload)
        }
    }

    private func handle(_ message: JSONObject, currentUserId: String) {
        // Igual de defensivo que la web: el payload puede venir envuelto.
        let layer = message["payload"]?.objectValue ?? message
        let data = layer["payload"]?.objectValue ?? layer
        guard let userId = data["userId"]?.stringValue, !userId.isEmpty, userId != currentUserId else { return }
        let userName = data["userName"]?.stringValue ?? "Usuario Core"
        let isTyping = data["isTyping"]?.boolValue ?? false

        expiryTasks[userId]?.cancel()
        if isTyping {
            namesByUserId[userId] = userName
            expiryTasks[userId] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.namesByUserId[userId] = nil
                self?.publishNames()
            }
        } else {
            namesByUserId[userId] = nil
            expiryTasks[userId] = nil
        }
        publishNames()
    }

    private func publishNames() {
        typingNames = namesByUserId.values.sorted()
    }
}
