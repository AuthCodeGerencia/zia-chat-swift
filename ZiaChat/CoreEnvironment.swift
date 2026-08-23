import Foundation

nonisolated struct CoreEnvironment: Sendable {
    var supabaseURL: String = ""
    var supabaseAnonKey: String = ""
    var convexURL: String = ""
    var appURL: String = ""
    var giphyAPIKey: String = ""

    private static let projectSupabaseURL = "https://supabase.authcode.biz"
    private static let projectSupabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlua2Ntb2J0eXB5aml3Y2Vwb3VyIiwicm9sZSI6ImFub24iLCJpYXQiOjE3MzUwNjg1NTUsImV4cCI6MjA1MDY0NDU1NX0.xVJhcEWKizMRP4ZOYXUww2FUG9N2517yv0XggOjaOKM"
    private static let projectConvexURL = "https://spotted-cassowary-104.convex.cloud"
    private static let projectAppURL = "https://portal.agenciadevio.com"
    private static let projectGiphyAPIKey = "LwWVGWkTKc9oLNkkZmhyZlL1v0PlXmI0"

    /// Instancia única: `load()` copia el entorno del proceso y puede leer un
    /// dotenv, así que no debe ejecutarse en rutas de render (avatares, etc.).
    static let shared: CoreEnvironment = load()

    private static func load() -> CoreEnvironment {
        let process = ProcessInfo.processInfo.environment
        var environment = CoreEnvironment(
            supabaseURL: process["NEXT_PUBLIC_SUPABASE_URL"] ?? "",
            supabaseAnonKey: process["NEXT_PUBLIC_SUPABASE_ANON_KEY"] ?? "",
            convexURL: process["NEXT_PUBLIC_CONVEX_URL"] ?? process["CONVEX_URL"] ?? "",
            appURL: process["NEXT_PUBLIC_APP_URL"] ?? "",
            giphyAPIKey: process["NEXT_PUBLIC_GIPHY_API_KEY"] ?? ""
        )

        guard environment.supabaseURL.isEmpty
            || environment.supabaseAnonKey.isEmpty
            || environment.convexURL.isEmpty
            || environment.appURL.isEmpty
            || environment.giphyAPIKey.isEmpty else {
            return environment
        }

        let envValues = dotenvValues()
        if environment.supabaseURL.isEmpty {
            environment.supabaseURL = envValues["NEXT_PUBLIC_SUPABASE_URL"] ?? ""
        }
        if environment.supabaseAnonKey.isEmpty {
            environment.supabaseAnonKey = envValues["NEXT_PUBLIC_SUPABASE_ANON_KEY"] ?? ""
        }
        if environment.convexURL.isEmpty {
            environment.convexURL = envValues["NEXT_PUBLIC_CONVEX_URL"] ?? envValues["CONVEX_URL"] ?? ""
        }
        if environment.appURL.isEmpty {
            environment.appURL = envValues["NEXT_PUBLIC_APP_URL"] ?? ""
        }
        if environment.giphyAPIKey.isEmpty {
            environment.giphyAPIKey = envValues["NEXT_PUBLIC_GIPHY_API_KEY"] ?? ""
        }
        if environment.supabaseURL.isEmpty {
            environment.supabaseURL = projectSupabaseURL
        }
        if environment.supabaseAnonKey.isEmpty {
            environment.supabaseAnonKey = projectSupabaseAnonKey
        }
        if environment.convexURL.isEmpty {
            environment.convexURL = projectConvexURL
        }
        if environment.appURL.isEmpty {
            environment.appURL = projectAppURL
        }
        if environment.giphyAPIKey.isEmpty {
            environment.giphyAPIKey = projectGiphyAPIKey
        }
        return environment
    }

    /// Solo en simulador de desarrollo: `ZIA_DOTENV_PATH` (variable de entorno
    /// del esquema) apunta a un `.env.local`. En dispositivo/release no se toca disco.
    private static func dotenvValues() -> [String: String] {
        #if DEBUG && targetEnvironment(simulator)
        guard let path = ProcessInfo.processInfo.environment["ZIA_DOTENV_PATH"], !path.isEmpty,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return [:]
        }
        return parseDotenv(text)
        #else
        return [:]
        #endif
    }

    private static func parseDotenv(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), let equalsIndex = line.firstIndex(of: "=") else {
                continue
            }

            let key = String(line[..<equalsIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = String(line[line.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            values[key] = unquoted(rawValue)
        }
        return values
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
