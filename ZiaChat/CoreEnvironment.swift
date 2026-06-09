import Foundation

struct CoreEnvironment {
    var supabaseURL: String = ""
    var supabaseAnonKey: String = ""

    private static let projectSupabaseURL = "https://supabase.authcode.biz"
    private static let projectSupabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlua2Ntb2J0eXB5aml3Y2Vwb3VyIiwicm9sZSI6ImFub24iLCJpYXQiOjE3MzUwNjg1NTUsImV4cCI6MjA1MDY0NDU1NX0.xVJhcEWKizMRP4ZOYXUww2FUG9N2517yv0XggOjaOKM"

    static func load(filePath: String = #filePath) -> CoreEnvironment {
        let process = ProcessInfo.processInfo.environment
        var environment = CoreEnvironment(
            supabaseURL: process["NEXT_PUBLIC_SUPABASE_URL"] ?? "",
            supabaseAnonKey: process["NEXT_PUBLIC_SUPABASE_ANON_KEY"] ?? ""
        )

        guard environment.supabaseURL.isEmpty || environment.supabaseAnonKey.isEmpty else {
            return environment
        }

        let envValues = dotenvValues(from: azankReactEnvURL(filePath: filePath))
        if environment.supabaseURL.isEmpty {
            environment.supabaseURL = envValues["NEXT_PUBLIC_SUPABASE_URL"] ?? ""
        }
        if environment.supabaseAnonKey.isEmpty {
            environment.supabaseAnonKey = envValues["NEXT_PUBLIC_SUPABASE_ANON_KEY"] ?? ""
        }
        if environment.supabaseURL.isEmpty {
            environment.supabaseURL = projectSupabaseURL
        }
        if environment.supabaseAnonKey.isEmpty {
            environment.supabaseAnonKey = projectSupabaseAnonKey
        }
        return environment
    }

    private static func azankReactEnvURL(filePath: String) -> URL {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("azank-react")
            .appendingPathComponent(".env.local")
    }

    private static func dotenvValues(from url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }

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
