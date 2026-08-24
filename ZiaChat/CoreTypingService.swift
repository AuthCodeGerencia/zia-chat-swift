import Foundation
import Observation

/// Indicador de escritura respaldado por Convex (`typing:set`).
/// No se consulta `typing:list` en loop; sin canal reactivo, la app solo publica
/// el estado local para no abrir polling.
@Observable
@MainActor
final class CoreTypingService {
    private(set) var typingNames: [String] = []

    @ObservationIgnored private var connectedConversationId: String?
    @ObservationIgnored private var lastTypingSentAt: Date = .distantPast
    @ObservationIgnored private var isTypingSent = false
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private let typingPulseInterval: TimeInterval = 5
    @ObservationIgnored private let typingIdleStopDelay: Duration = .milliseconds(3500)

    var typingLabel: String? {
        guard !typingNames.isEmpty else { return nil }
        if typingNames.count == 1 {
            return "\(typingNames[0]) está escribiendo…"
        }
        return "\(typingNames.joined(separator: ", ")) están escribiendo…"
    }

    func connect(conversationId: String, configuration: CoreAppConfiguration) async {
        if connectedConversationId == conversationId { return }
        await disconnect()
        guard configuration.isUsable else { return }
        connectedConversationId = conversationId
        typingNames = []
    }

    func disconnect() async {
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
        guard let conversationId = connectedConversationId, !ZiaDemoMode.isEnabled else { return }
        let name = configuration.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = try? ConvexCoreClient(configuration: configuration)
        try? await client?.setTyping(
            conversationId: conversationId,
            userName: name.isEmpty ? "Usuario Core" : name,
            isTyping: isTyping
        )
    }

}
