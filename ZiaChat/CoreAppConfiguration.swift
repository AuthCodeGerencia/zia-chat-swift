import Foundation

struct CoreAppConfiguration: Codable, Equatable {
    var supabaseURL: String
    var anonKey: String
    var accessToken: String
    var refreshToken: String
    var userId: String
    var empresaId: Int?
    var displayName: String

    init(
        supabaseURL: String = "",
        anonKey: String = "",
        accessToken: String = "",
        refreshToken: String = "",
        userId: String = "",
        empresaId: Int? = nil,
        displayName: String = ""
    ) {
        self.supabaseURL = supabaseURL
        self.anonKey = anonKey
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.userId = userId
        self.empresaId = empresaId
        self.displayName = displayName
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

    mutating func clearSession() {
        accessToken = ""
        refreshToken = ""
        userId = ""
        empresaId = nil
        displayName = ""
    }
}

enum CoreConfigurationStore {
    private static let key = "zia-chat.core.configuration"

    static func load() -> CoreAppConfiguration {
        let environmentDefaults = CoreEnvironment.load()
        guard let data = UserDefaults.standard.data(forKey: key),
              var configuration = try? JSONDecoder().decode(CoreAppConfiguration.self, from: data) else {
            return CoreAppConfiguration(
                supabaseURL: environmentDefaults.supabaseURL,
                anonKey: environmentDefaults.supabaseAnonKey
            )
        }

        if configuration.supabaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            configuration.supabaseURL = environmentDefaults.supabaseURL
        }
        if configuration.anonKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            configuration.anonKey = environmentDefaults.supabaseAnonKey
        }
        return configuration
    }

    static func save(_ configuration: CoreAppConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
