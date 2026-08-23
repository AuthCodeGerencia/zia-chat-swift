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
}
