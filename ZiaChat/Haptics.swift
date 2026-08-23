import UIKit

/// Feedback háptico centralizado (estilo Slack: toque ligero al enviar,
/// reaccionar, fijar; selección al cambiar filtros; éxito/error en acciones).
///
/// Los generadores se reutilizan y se preparan para que el primer impacto no
/// llegue con retraso.
@MainActor
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let selection = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()

    /// Toque suave: enviar mensaje, abrir panel, tap en reacción.
    static func tap() {
        light.impactOccurred()
        light.prepare()
    }

    /// Toque medio: long-press que abre el menú de acciones, swipe-to-reply.
    static func press() {
        medium.impactOccurred()
        medium.prepare()
    }

    /// Toque seco: llegar al final/inicio, fijar/desfijar.
    static func snap() {
        rigid.impactOccurred(intensity: 0.8)
        rigid.prepare()
    }

    /// Cambio de selección: chips de filtro, pestañas del picker de emoji.
    static func select() {
        selection.selectionChanged()
        selection.prepare()
    }

    static func success() {
        notification.notificationOccurred(.success)
        notification.prepare()
    }

    static func warning() {
        notification.notificationOccurred(.warning)
        notification.prepare()
    }

    static func error() {
        notification.notificationOccurred(.error)
        notification.prepare()
    }
}
