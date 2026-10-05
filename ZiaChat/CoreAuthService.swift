import Foundation
import os
import Supabase

enum CoreAuthError: LocalizedError {
    case missingSupabaseEnvironment
    case invalidSupabaseURL
    case missingProfile
    case missingRefreshToken
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .missingSupabaseEnvironment:
            return "Supabase URL and anon key are required before login."
        case .invalidSupabaseURL:
            return "Invalid Supabase project URL."
        case .missingProfile:
            return "This user does not have an Azank profile."
        case .missingRefreshToken:
            return "The saved session cannot be refreshed. Please sign in again."
        case .sessionExpired:
            return "Tu sesión expiró. Vuelve a iniciar sesión."
        }
    }
}

struct CoreAuthenticatedProfile: Decodable {
    var id: String
    var fullName: String?
    var avatarURLString: String?
    var empresaId: Int?
    var roleId: Int?
    var clientId: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case avatarURLString = "avatar_url"
        case empresaId = "empresa_id"
        case roleId = "rol_id"
        case clientId = "client_id"
    }
}

struct CoreLoginResult {
    var configuration: CoreAppConfiguration
    var profile: CoreAuthenticatedProfile
}

final class CoreAuthService {
    private let configuration: CoreAppConfiguration
    private let client: SupabaseClient

    init(configuration: CoreAppConfiguration) throws {
        guard !configuration.supabaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !configuration.anonKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoreAuthError.missingSupabaseEnvironment
        }
        guard let url = URL(string: configuration.supabaseURL) else {
            throw CoreAuthError.invalidSupabaseURL
        }

        self.configuration = configuration
        client = Self.sharedClient(url: url, anonKey: configuration.anonKey)
    }

    /// supabase-swift nunca libera un `SupabaseClient` (su tarea de eventos de
    /// auth lo retiene) y cada uno arranca su propio bucle de auto-refresco al
    /// volver la app a primer plano. Uno nuevo por refresco acumulaba bucles
    /// que rotaban el refresh token a espaldas de la app y agotaban el límite
    /// de peticiones de Supabase. Se comparte uno por proyecto y sin
    /// auto-refresco: la app ya refresca la sesión (`ensureFreshSession`).
    nonisolated private static let clients = OSAllocatedUnfairLock<[String: SupabaseClient]>(initialState: [:])

    nonisolated private static func sharedClient(url: URL, anonKey: String) -> SupabaseClient {
        clients.withLock { clients in
            let key = "\(url.absoluteString)|\(anonKey)"
            if let existing = clients[key] {
                return existing
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom(decodeDate)
            let created = SupabaseClient(
                supabaseURL: url,
                supabaseKey: anonKey,
                options: SupabaseClientOptions(
                    db: .init(schema: "public", decoder: decoder),
                    auth: .init(autoRefreshToken: false)
                )
            )
            clients[key] = created
            return created
        }
    }

    func login(email: String, password: String) async throws -> CoreLoginResult {
        let session = try await client.auth.signIn(email: email, password: password)

        let profiles: [CoreAuthenticatedProfile] = try await client
            .from("profiles")
            .select("id,full_name,avatar_url,empresa_id,rol_id,client_id")
            .eq("id", value: session.user.id.uuidString)
            .limit(1)
            .execute()
            .value

        guard let profile = profiles.first else {
            throw CoreAuthError.missingProfile
        }

        var next = configuration
        next.accessToken = session.accessToken
        next.refreshToken = session.refreshToken
        next.userId = profile.id
        next.empresaId = profile.empresaId
        next.displayName = profile.fullName ?? session.user.email ?? ""
        return CoreLoginResult(configuration: next, profile: profile)
    }

    func refreshSession() async throws -> CoreAppConfiguration {
        let refreshToken = configuration.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refreshToken.isEmpty else {
            throw CoreAuthError.missingRefreshToken
        }

        let session: Session
        do {
            session = try await client.auth.refreshSession(refreshToken: refreshToken)
        } catch AuthError.sessionMissing {
            // Supabase rechazó el refresh token (ya usado, revocado o la sesión
            // cerrada): reintentar no sirve, hay que volver a iniciar sesión.
            throw CoreAuthError.sessionExpired
        }
        var next = configuration
        next.accessToken = session.accessToken
        next.refreshToken = session.refreshToken
        return next
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
