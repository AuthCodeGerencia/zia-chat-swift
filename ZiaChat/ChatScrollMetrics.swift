import SwiftUI

/// Geometría de la lista de mensajes (cronológica, anclada al final) reducida
/// a lo que el chat necesita: si está al final y si el área visible se encogió
/// (teclado o panel), en cuyo caso debe seguir pegada al final.
struct ChatScrollMetrics: Equatable {
    var distanceToBottom: CGFloat
    var visibleHeight: CGFloat

    init(_ geometry: ScrollGeometry) {
        distanceToBottom = geometry.contentSize.height - geometry.visibleRect.maxY
        visibleHeight = geometry.visibleRect.height
    }

    /// También es cierto cuando el contenido es más corto que la ventana.
    var isNearBottom: Bool { distanceToBottom < 80 }
}
