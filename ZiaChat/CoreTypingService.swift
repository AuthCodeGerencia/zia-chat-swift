import Combine
import Foundation

/// Indicador de "escribiendo…" respaldado por Convex (`typing:list` /
/// `typing:set`). La app Swift usa polling liviano porque no mantiene un
/// cliente Convex reactivo por WebSocket.
@MainActor
final class CoreTypingService: ObservableObject {
    @Published private(set) var typingNames: [String] = []

    private var pollTask: Task<Void, Never>?
    private var connectedConversationId: String?
    private var lastTypingSentAt: Date = .distantPast
    private var isTypingSent = false
    private var idleTask: Task<Void, Never>?
    private let typingPulseInterval: TimeInterval = 5
    private let typingIdleStopDelay: Duration = .milliseconds(3500)
    private let typingPollInterval: Duration = .seconds(4)

    var typingLabel: String? {
        guard !typingNames.isEmpty else { return nil }
        if typingNames.count == 1 {
            return "\(typingNames[0]) está escribiendo…"
        }
        return "\(typingNames.joined(separator: ", ")) están escribiendo…"
    }

    func connect(conversationId: String, configuration: CoreAppConfiguration) async {
        if connectedConversationId == conversationId, pollTask != nil { return }
        await disconnect()
        guard configuration.isUsable else { return }
        connectedConversationId = conversationId
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshTyping(conversationId: conversationId, configuration: configuration)
                try? await Task.sleep(for: self?.typingPollInterval ?? .seconds(4))
            }
        }
        await refreshTyping(conversationId: conversationId, configuration: configuration)
    }

    func disconnect() async {
        pollTask?.cancel()
        pollTask = nil
        idleTask?.cancel()
        idleTask = nil
        typingNames = []
        connectedConversationId = nil
        lastTypingSentAt = .distantPast
        isTypingSent = false
    }

    /// Notifica que el usuario está escribiendo con pulsos espaciados y programa
    /// el "dejó de escribir" tras una pausa corta de inactividad.
    func userIsTyping(configuration: CoreAppConfiguration) {
        let now = Date()
        if !isTypingSent || now.timeIntervalSince(lastTypingSentAt) >= typingPulseInterval {
            lastTypingSentAt = now
            isTypingSent = true
            Task { await send(isTyping: true, configuration: configuration) }
        }
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: self?.typingIdleStopDelay ?? .milliseconds(3500))
            guard !Task.isCancelled else { return }
            await self?.sendStopIfNeeded(configuration: configuration)
            await MainActor.run {
                self?.lastTypingSentAt = .distantPast
            }
        }
    }

    func userStoppedTyping(configuration: CoreAppConfiguration) {
        idleTask?.cancel()
        idleTask = nil
        lastTypingSentAt = .distantPast
        Task { await sendStopIfNeeded(configuration: configuration) }
    }

    private func sendStopIfNeeded(configuration: CoreAppConfiguration) async {
        guard isTypingSent else { return }
        isTypingSent = false
        await send(isTyping: false, configuration: configuration)
    }

    private func send(isTyping: Bool, configuration: CoreAppConfiguration) async {
        guard let conversationId = connectedConversationId else { return }
        let name = configuration.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = try? ConvexCoreClient(configuration: configuration)
        try? await client?.setTyping(
            conversationId: conversationId,
            userName: name.isEmpty ? "Usuario Core" : name,
            isTyping: isTyping
        )
    }

    private func refreshTyping(conversationId: String, configuration: CoreAppConfiguration) async {
        guard connectedConversationId == conversationId,
              let client = try? ConvexCoreClient(configuration: configuration),
              let statuses = try? await client.listTyping(conversationId: conversationId) else {
            return
        }
        typingNames = statuses
            .filter { $0.isTyping && $0.userId != configuration.userId }
            .map(\.userName)
            .sorted()
    }
}
