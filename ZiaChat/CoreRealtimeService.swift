import Foundation
import Supabase

final class CoreRealtimeService {
    private let client: SupabaseClient
    private let decoder: JSONDecoder
    private let accessToken: String
    private var channel: RealtimeChannelV2?
    private var tasks: [Task<Void, Never>] = []

    init(configuration: CoreAppConfiguration) throws {
        guard configuration.isUsable else { throw SupabaseCoreError.notConfigured }
        guard let url = URL(string: configuration.supabaseURL) else {
            throw SupabaseCoreError.invalidURL
        }

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(Self.decodeDate)
        accessToken = configuration.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)

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

    func subscribe(
        conversationId: String,
        onInsert: @escaping @Sendable (CoreMessage) async -> Void,
        onUpdate: @escaping @Sendable (CoreMessage) async -> Void,
        onDelete: @escaping @Sendable (CoreMessage) async -> Void,
        onReactionChange: @escaping @Sendable (CoreReaction?, String?) async -> Void,
        onAttachmentChange: @escaping @Sendable (CoreAttachment?, String?) async -> Void,
        onPinChange: @escaping @Sendable (CoreMessagePin?, String?) async -> Void,
        onMessageSignal: @escaping @Sendable () async -> Void,
        onError: @escaping @Sendable (String) async -> Void,
        onDisconnect: @escaping @Sendable () async -> Void
    ) async throws {
        await stop()

        let channel = client.channel("core:conversation:\(conversationId)")
        let messageBroadcastStream = channel.broadcastStream(event: "message:new")
        let messageStream = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "core_messages",
            filter: .eq("conversation_id", value: conversationId)
        )
        let reactionStream = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "core_reactions"
        )
        let attachmentStream = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "core_attachments"
        )
        let pinStream = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "core_message_pins",
            filter: .eq("conversation_id", value: conversationId)
        )

        tasks = [
            Task { [decoder] in
                for await payload in messageBroadcastStream {
                    await onMessageSignal()
                    let layer = payload["payload"]?.objectValue ?? payload
                    guard let messageObject = layer["message"]?.objectValue else {
                        continue
                    }
                    do {
                        let message = try messageObject.decode(as: CoreMessage.self, decoder: decoder)
                        if message.deletedAt != nil {
                            await onUpdate(message)
                        } else {
                            await onInsert(message)
                        }
                    } catch {
                        await onError("Realtime message:new: \(error.localizedDescription)")
                    }
                }
            },
            Task { [decoder] in
                for await action in messageStream {
                    await onMessageSignal()
                    do {
                        switch action {
                        case let .insert(insert):
                            await onInsert(
                                try insert.decodeRecord(as: CoreMessage.self, decoder: decoder)
                            )
                        case let .update(update):
                            await onUpdate(
                                try update.decodeRecord(as: CoreMessage.self, decoder: decoder)
                            )
                        case let .delete(delete):
                            await onDelete(
                                try delete.decodeOldRecord(as: CoreMessage.self, decoder: decoder)
                            )
                        }
                    } catch {
                        await onError("Realtime core_messages: \(error.localizedDescription)")
                    }
                }
            },
            Task { [decoder] in
                for await action in reactionStream {
                    switch action {
                    case let .insert(insert):
                        let reaction = try? insert.decodeRecord(as: CoreReaction.self, decoder: decoder)
                        await onReactionChange(reaction, nil)
                    case let .update(update):
                        let reaction = try? update.decodeRecord(as: CoreReaction.self, decoder: decoder)
                        await onReactionChange(reaction, nil)
                    case let .delete(delete):
                        let reaction = try? delete.decodeOldRecord(as: CoreReaction.self, decoder: decoder)
                        await onReactionChange(reaction, reaction?.id)
                    }
                }
            },
            Task { [decoder] in
                for await action in attachmentStream {
                    switch action {
                    case let .insert(insert):
                        await onAttachmentChange(
                            try? insert.decodeRecord(as: CoreAttachment.self, decoder: decoder),
                            nil
                        )
                    case let .update(update):
                        await onAttachmentChange(
                            try? update.decodeRecord(as: CoreAttachment.self, decoder: decoder),
                            nil
                        )
                    case let .delete(delete):
                        let attachment = try? delete.decodeOldRecord(as: CoreAttachment.self, decoder: decoder)
                        await onAttachmentChange(attachment, attachment?.id)
                    }
                }
            },
            Task { [decoder] in
                for await action in pinStream {
                    switch action {
                    case let .insert(insert):
                        await onPinChange(
                            try? insert.decodeRecord(as: CoreMessagePin.self, decoder: decoder),
                            nil
                        )
                    case let .update(update):
                        await onPinChange(
                            try? update.decodeRecord(as: CoreMessagePin.self, decoder: decoder),
                            nil
                        )
                    case let .delete(delete):
                        let pin = try? delete.decodeOldRecord(as: CoreMessagePin.self, decoder: decoder)
                        await onPinChange(pin, pin?.id)
                    }
                }
            },
            Task {
                var wasSubscribed = false
                for await status in channel.statusChange {
                    switch status {
                    case .subscribed:
                        wasSubscribed = true
                    case .unsubscribed where wasSubscribed:
                        await onDisconnect()
                        return
                    default:
                        break
                    }
                }
            }
        ]

        self.channel = channel
        await client.realtimeV2.setAuth(accessToken)
        try await channel.subscribeWithError()
    }

    func broadcast(message: CoreMessage) async {
        guard let channel else { return }
        try? await channel.broadcast(
            event: "message:new",
            message: CoreMessageBroadcastEnvelope(message: message)
        )
    }

    func stop() async {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()

        if let channel {
            await channel.unsubscribe()
            await client.removeChannel(channel)
            self.channel = nil
        }
    }

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

private struct CoreMessageBroadcastEnvelope: Codable {
    let message: CoreMessage
}
