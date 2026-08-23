import Foundation
import SwiftUI

/// Borrador persistido por conversación (o por hilo, con el id de su raíz).
nonisolated struct ComposerDraft: Codable, Hashable, Sendable {
    nonisolated struct Attachment: Codable, Hashable, Sendable {
        var id: UUID
        var fileName: String
        var mimeType: String
        var sizeBytes: Int
        /// Nombre del archivo dentro de `PendingUploadStorage.directory`.
        var storedFileName: String
    }

    var text = ""
    var replyToMessageId: String?
    var attachments: [Attachment] = []

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && replyToMessageId == nil
            && attachments.isEmpty
    }

    /// Texto para la lista de chats ("Borrador: …").
    var previewText: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if !attachments.isEmpty {
            return attachments.count == 1 ? "1 adjunto" : "\(attachments.count) adjuntos"
        }
        return nil
    }
}

/// Mantiene `ComposerState` sincronizado con el borrador guardado en el store:
/// lo restaura al aparecer y lo guarda al escribir (el store aplica el
/// debounce) y al salir de la vista. Mientras se edita un mensaje no se guarda.
struct ComposerDraftPersistence: ViewModifier {
    let store: CoreChannelsStore
    let key: String?
    let state: ComposerState
    /// Mensajes donde buscar la cita restaurada; puede llenarse después de
    /// aparecer (carga fría), por eso se reintenta cuando cambia su tamaño.
    let replyCandidates: [CoreMessage]

    @State private var pendingReplyId: String?
    @State private var isPersistingAttachments = false
    /// El texto se guarda tras una pausa: tocar el store en cada tecla
    /// redibujaría el chat completo.
    @State private var textSaveTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onAppear(perform: restore)
            .onChange(of: replyCandidates.count) { _, _ in resolvePendingReply() }
            .onChange(of: state.draft) { _, _ in scheduleTextSave() }
            .onChange(of: state.replyTarget?.id) { _, _ in save() }
            .onChange(of: state.attachments) { _, _ in save() }
            .onDisappear { save(flush: true) }
    }

    private func restore() {
        guard let key, let draft = store.drafts[key],
              state.editTarget == nil,
              state.draft.isEmpty, state.attachments.isEmpty, state.replyTarget == nil else {
            return
        }
        state.draft = draft.text
        state.attachments = draft.attachments.compactMap { item in
            let url = PendingUploadStorage.directory.appendingPathComponent(item.storedFileName)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return CorePendingAttachment(
                id: item.id,
                fileURL: url,
                fileName: item.fileName,
                mimeType: item.mimeType,
                sizeBytes: item.sizeBytes
            )
        }
        pendingReplyId = draft.replyToMessageId
        resolvePendingReply()
    }

    private func resolvePendingReply() {
        guard let pendingReplyId,
              let message = replyCandidates.first(where: { $0.id == pendingReplyId }) else { return }
        self.pendingReplyId = nil
        if state.replyTarget == nil {
            state.replyTarget = message
        }
    }

    private func scheduleTextSave() {
        textSaveTask?.cancel()
        textSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save(flush: Bool = false) {
        textSaveTask?.cancel()
        guard let key, state.editTarget == nil else { return }
        if state.draft.isEmpty && state.attachments.isEmpty && state.replyTarget == nil {
            pendingReplyId = nil
        }
        persistInMemoryAttachments()
        let stored = state.attachments.compactMap { attachment -> ComposerDraft.Attachment? in
            guard let url = attachment.fileURL, attachment.isFileBacked else { return nil }
            return ComposerDraft.Attachment(
                id: attachment.id,
                fileName: attachment.fileName,
                mimeType: attachment.mimeType,
                sizeBytes: attachment.sizeBytes,
                storedFileName: url.lastPathComponent
            )
        }
        let draft = ComposerDraft(
            text: state.draft,
            replyToMessageId: state.replyTarget?.id ?? pendingReplyId,
            attachments: stored
        )
        store.setDraft(draft, for: key, flush: flush)
    }

    /// Los adjuntos que viven en memoria (GIF del carrete, etc.) se pasan a
    /// disco para poder guardarlos; la versión en archivo sustituye a la
    /// original en el estado y dispara un nuevo guardado.
    private func persistInMemoryAttachments() {
        let inMemory = state.attachments.filter { !$0.isFileBacked }
        guard !inMemory.isEmpty, !isPersistingAttachments else { return }
        isPersistingAttachments = true
        Task {
            let persisted = await Self.persist(inMemory)
            for attachment in persisted {
                if let index = state.attachments.firstIndex(where: { $0.id == attachment.id && !$0.isFileBacked }) {
                    state.attachments[index] = attachment
                } else {
                    PendingUploadStorage.remove([attachment])
                }
            }
            isPersistingAttachments = false
        }
    }

    @concurrent
    private static func persist(_ attachments: [CorePendingAttachment]) async -> [CorePendingAttachment] {
        attachments.compactMap { try? PendingUploadStorage.persist($0) }
    }
}

extension View {
    func composerDraftPersistence(
        store: CoreChannelsStore,
        key: String?,
        state: ComposerState,
        replyCandidates: [CoreMessage] = []
    ) -> some View {
        modifier(
            ComposerDraftPersistence(
                store: store,
                key: key,
                state: state,
                replyCandidates: replyCandidates
            )
        )
    }
}
