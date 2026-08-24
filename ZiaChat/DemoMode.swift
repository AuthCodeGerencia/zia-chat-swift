import Foundation

/// Modo demo (solo DEBUG): la app arranca con datos de muestra y sin tocar la
/// red, para ejercitar la UI en el simulador sin credenciales.
/// `-zia-demo` activa el modo; `-zia-demo-open` además abre el primer canal.
enum ZiaDemoMode {
    nonisolated static let isEnabled: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-zia-demo")
            || ProcessInfo.processInfo.arguments.contains("-zia-demo-open")
        #else
        return false
        #endif
    }()

    nonisolated static let opensFirstChannel: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-zia-demo-open")
        #else
        return false
        #endif
    }()

    /// `-zia-demo-open <slug>` abre ese canal en vez del primero de texto.
    nonisolated static let openChannelSlug: String? = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-zia-demo-open"),
              arguments.indices.contains(index + 1),
              !arguments[index + 1].hasPrefix("-") else { return nil }
        return arguments[index + 1]
        #else
        return nil
        #endif
    }()

    /// `-zia-demo-new-channel` abre la hoja de crear canal (ChannelSettingsView).
    nonisolated static let opensNewChannelSheet: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-zia-demo-new-channel")
        #else
        return false
        #endif
    }()

    /// `-zia-demo-panel <menu|poll|gif|sticker|emoji|command>` abre ese panel
    /// del composer al entrar al canal.
    nonisolated static let composerPanel: String? = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-zia-demo-panel"),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
        #else
        return nil
        #endif
    }()
}
