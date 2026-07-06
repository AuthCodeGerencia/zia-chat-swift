import Foundation

struct CoreAppConfiguration: Codable, Equatable {
    var supabaseURL: String
    var anonKey: String
    var convexURL: String
    var accessToken: String
    var refreshToken: String
    var userId: String
    var empresaId: Int?
    var displayName: String

    enum CodingKeys: String, CodingKey {
        case supabaseURL
        case anonKey
        case convexURL
        case accessToken
        case refreshToken
        case userId
        case empresaId
        case displayName
    }

    init(
        supabaseURL: String = "",
        anonKey: String = "",
        convexURL: String = "",
        accessToken: String = "",
        refreshToken: String = "",
        userId: String = "",
        empresaId: Int? = nil,
        displayName: String = ""
    ) {
        self.supabaseURL = supabaseURL
        self.anonKey = anonKey
        self.convexURL = convexURL
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.userId = userId
        self.empresaId = empresaId
        self.displayName = displayName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        supabaseURL = try container.decodeIfPresent(String.self, forKey: .supabaseURL) ?? ""
        anonKey = try container.decodeIfPresent(String.self, forKey: .anonKey) ?? ""
        convexURL = try container.decodeIfPresent(String.self, forKey: .convexURL) ?? ""
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken) ?? ""
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken) ?? ""
        userId = try container.decodeIfPresent(String.self, forKey: .userId) ?? ""
        empresaId = try container.decodeIfPresent(Int.self, forKey: .empresaId)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
    }

    var isUsable: Bool {
        hasSupabaseEnvironment &&
        hasSessionContext
    }

    var hasSupabaseEnvironment: Bool {
        URL(string: supabaseURL) != nil &&
        !anonKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasSessionContext: Bool {
        !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        empresaId != nil
    }

    var empresaIdText: String {
        get { empresaId.map(String.init) ?? "" }
        set { empresaId = Int(newValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func accessTokenExpires(within interval: TimeInterval = 300) -> Bool {
        guard let expirationDate = accessTokenExpirationDate else { return true }
        return expirationDate.timeIntervalSinceNow <= interval
    }

    func accessTokenRefreshDelay(leadTime: TimeInterval = 300) -> TimeInterval {
        guard let expirationDate = accessTokenExpirationDate else { return 0 }
        return max(0, expirationDate.timeIntervalSinceNow - leadTime)
    }

    mutating func clearSession() {
        accessToken = ""
        refreshToken = ""
        userId = ""
        empresaId = nil
        displayName = ""
    }

    private var accessTokenExpirationDate: Date? {
        let parts = accessToken.split(separator: ".")
        guard parts.count > 1 else { return nil }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload.append(String(repeating: "=", count: (4 - payload.count % 4) % 4))

        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiration = object["exp"] as? NSNumber else {
            return nil
        }
        return Date(timeIntervalSince1970: expiration.doubleValue)
    }
}

enum CoreConfigurationStore {
    private static let key = "zia-chat.core.configuration"
    private static let legacyConvexURLs = [
        "https://calculating-goshawk-157.convex.cloud",
    ]

    /// App Group compartido entre la app y la Share Extension. Debe estar
    /// habilitado en ambos targets (Signing & Capabilities) y en el portal
    /// de Apple Developer.
    static let appGroupIdentifier = "group.authcode.ZiaChat"

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    static func load() -> CoreAppConfiguration {
        let environmentDefaults = CoreEnvironment.load()
        // Lee primero del contenedor compartido (extensión + app); cae al
        // standard para sesiones guardadas antes de introducir el App Group.
        let sharedData = sharedDefaults?.data(forKey: key)
        let stored = sharedData ?? UserDefaults.standard.data(forKey: key)
        // Migra sesiones previas al contenedor compartido para que la
        // Share Extension pueda verlas sin esperar a un nuevo login.
        if sharedData == nil, let legacy = stored {
            sharedDefaults?.set(legacy, forKey: key)
        }
        guard let data = stored,
              var configuration = try? JSONDecoder().decode(CoreAppConfiguration.self, from: data) else {
            return CoreAppConfiguration(
                supabaseURL: environmentDefaults.supabaseURL,
                anonKey: environmentDefaults.supabaseAnonKey,
                convexURL: environmentDefaults.convexURL
            )
        }

        if configuration.supabaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            configuration.supabaseURL = environmentDefaults.supabaseURL
        }
        if configuration.anonKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            configuration.anonKey = environmentDefaults.supabaseAnonKey
        }
        if configuration.convexURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            legacyConvexURLs.contains(Self.normalizedURL(configuration.convexURL)) {
            configuration.convexURL = environmentDefaults.convexURL
        }
        return configuration
    }

    static func save(_ configuration: CoreAppConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        sharedDefaults?.set(data, forKey: key)
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func normalizedURL(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t/"))
    }
}
