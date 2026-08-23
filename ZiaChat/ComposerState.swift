import Foundation
import Observation

/// Estado del compositor (borrador, cita, edición y adjuntos) separado del
/// chat: cada tecla solo re-renderiza `ComposerView`, no la lista de mensajes.
@Observable
final class ComposerState {
    var draft = ""
    var replyTarget: CoreMessage?
    var editTarget: CoreMessage?
    var attachments: [CorePendingAttachment] = []
}
