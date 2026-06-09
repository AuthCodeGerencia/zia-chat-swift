import Foundation
import Supabase

final class CoreRealtimeService {
    private let client: SupabaseClient
    private let decoder: JSONDecoder
    private var channel: RealtimeChannelV2?
    private var tasks: [Task<Void, Never>] = []

    init(configuration: CoreAppConfiguration) throws {
        guard configuration.isUsable else { throw SupabaseCoreError.notConfigured }
        guard let url = URL(string: configuration.supabaseURL) else {
            throw SupabaseCoreError.invalidURL
        }

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(Self.decodeDate)

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
        onReactionChange: @escaping @Sendable (CoreReaction?, String?) async -> Void
    ) async throws {
        await stop()

        let channel = client.channel("core:conversation:\(conversationId)")
        let insertStream = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "core_messages",
            filter: .eq("conversation_id", value: conversationId)
        )
        let updateStream = channel.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: "core_messages",
            filter: .eq("conversation_id", value: conversationId)
        )
        let reactionStream = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "core_reactions"
        )

        tasks = [
            Task { [decoder] in
                for await action in insertStream {
                    if let message = try? action.decodeRecord(as: CoreMessage.self, decoder: decoder) {
                        await onInsert(message)
                    }
                }
            },
            Task { [decoder] in
                for await action in updateStream {
                    if let message = try? action.decodeRecord(as: CoreMessage.self, decoder: decoder) {
                        await onUpdate(message)
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
            }
        ]

        self.channel = channel
        try await channel.subscribe()
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
