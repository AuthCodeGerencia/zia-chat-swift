import SwiftUI
import UIKit

/// Línea gráfica de Grupo Zenit (Manual de Marca).
/// Paleta oficial: cuatro tonalidades de verde que contrastan entre sí,
/// con el #1f221b como color principal. Tipografía: Funnel Display.
enum ZenitBrand {
    /// #1f221b — color principal de la marca (tinta verde oscura).
    static let ink = Color(zenitHex: 0x1F221B)
    /// #1b5b64 — teal corporativo (acento).
    static let teal = Color(zenitHex: 0x1B5B64)
    /// #4a4d3c — verde oliva oscuro.
    static let olive = Color(zenitHex: 0x4A4D3C)
    /// #868364 — verde khaki claro.
    static let khaki = Color(zenitHex: 0x868364)

    /// Fondo claro estilo papel del manual de marca.
    static let cream = Color(zenitHex: 0xF5F4F0)
    /// Burbuja propia: teal muy suave derivado del acento.
    static let bubbleMine = Color(zenitHex: 0xDCEAEC)
    /// Variante suave del acento para fondos seleccionados/badges.
    static let tealSoft = Color(zenitHex: 0xE6EFF0)

    /// Acento por defecto de la app.
    static let accent = teal
}

extension Color {
    init(zenitHex hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Tipografía de marca: Funnel Display (Google Fonts), con fallback al
/// sistema si los .ttf no están agregados al target.
/// Para activarla: agrega FunnelDisplay-Regular.ttf (y los pesos que quieras)
/// al proyecto y decláralos en Info.plist (UIAppFonts).
enum ZenitFont {
    static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .light: name = "FunnelDisplay-Light"
        case .medium: name = "FunnelDisplay-Medium"
        case .semibold: name = "FunnelDisplay-SemiBold"
        case .bold: name = "FunnelDisplay-Bold"
        case .heavy, .black: name = "FunnelDisplay-ExtraBold"
        default: name = "FunnelDisplay-Regular"
        }
        if UIFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: weight)
    }
}
