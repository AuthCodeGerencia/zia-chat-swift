import SwiftUI
import UIKit

/// Línea gráfica de Grupo Zenit (Manual de Marca).
/// Paleta oficial: cuatro tonalidades de verde que contrastan entre sí,
/// con el #1f221b como color principal. Tipografía: Funnel Display.
enum ZenitBrand {
    /// #1f221b — color principal de la marca (tinta verde oscura).
    /// En modo oscuro pasa a ser el tono claro de lectura sobre el fondo.
    static let ink = Color(zenitLight: 0x1F221B, dark: 0xECEBE5)
    /// #1b5b64 — teal corporativo. Valor fijo, pensado para rellenos con texto blanco.
    static let teal = Color(zenitHex: 0x1B5B64)
    /// #4a4d3c — verde oliva oscuro.
    static let olive = Color(zenitLight: 0x4A4D3C, dark: 0xA7AA95)
    /// #868364 — verde khaki claro.
    static let khaki = Color(zenitLight: 0x868364, dark: 0xB9B69C)
    /// Valores fijos de oliva/khaki para rellenos con icono blanco encima.
    static let oliveFill = Color(zenitHex: 0x4A4D3C)
    static let khakiFill = Color(zenitHex: 0x868364)

    /// Fondo claro estilo papel del manual de marca (fondo base de pantallas).
    static let cream = Color(zenitLight: 0xF5F4F0, dark: 0x15170F)
    /// Burbuja propia: teal muy suave derivado del acento.
    static let bubbleMine = Color(zenitLight: 0xDCEAEC, dark: 0x1E3A40)
    /// Variante suave del acento para fondos seleccionados/badges.
    static let tealSoft = Color(zenitLight: 0xE6EFF0, dark: 0x1E3034)

    /// Acento para texto, iconos y tints: en oscuro se aclara para mantener contraste.
    static let accent = Color(zenitLight: 0x1B5B64, dark: 0x7FBFC8)
    /// Acento para rellenos (botones, badges) con texto blanco encima;
    /// en oscuro sube un poco para despegarse de las superficies.
    static let accentFill = Color(zenitLight: 0x1B5B64, dark: 0x2A7A86)

    // MARK: Tokens semánticos

    /// Fondo base de pantallas y listas.
    static let ground = cream
    /// Tarjetas, burbujas ajenas y filas "blancas".
    static let surface = Color(zenitLight: 0xFFFFFF, dark: 0x1F221B)
    /// Superficies elevadas (barras, paneles del composer, hojas).
    static let surfaceElevated = Color(zenitLight: 0xFFFFFF, dark: 0x262A22)
    /// Paneles apagados (chips, previews, campos) que antes usaban gris claro.
    static let surfaceMuted = Color(zenitLight: 0xF2F4F4, dark: 0x262A22)
    /// Trazo fino de separación sobre cualquier superficie.
    static let hairline = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.09)
            : UIColor.black.withAlphaComponent(0.07)
    })
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary

    /// Sombra con la opacidad indicada en claro; en oscuro se refuerza para que
    /// siga separando la superficie del fondo.
    static func shadow(_ lightOpacity: Double) -> Color {
        Color(uiColor: UIColor { trait in
            let alpha = trait.userInterfaceStyle == .dark ? min(1, lightOpacity * 2.5) : lightOpacity
            return UIColor.black.withAlphaComponent(alpha)
        })
    }
}

extension Color {
    init(zenitHex hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// Color que cambia según la apariencia del sistema.
    init(zenitLight light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { trait in
            UIColor(zenitHex: trait.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(zenitHex hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
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
