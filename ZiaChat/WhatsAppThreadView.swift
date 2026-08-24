import ConvexMobile
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Hilo de una conversación de WhatsApp. Espejo de `ChatHilo.tsx` de
/// authcode-app: burbujas agrupadas, adjuntos, notas internas, cita,
/// reintento de envío y hoja de operaciones (estado, asignación, unidad,
/// cliente).
struct WhatsAppThreadView: View {
    @ObservedObject var store: WhatsAppStore
    let chatId: String
    @Binding var navigationPath: [CoreChannel.ID]

    @State private var draft = ""
    @State private var noteMode = false
    @State private var quoted: WhatsAppMessage?
    @State private var showOptions = false
    @State private var errorMessage: String?
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showPhotosPicker = false
    @State private var showFileImporter = false
    @State private var isImportingAttachments = false
    @State private var viewerAttachment: CoreAttachment?
    @StateObject private var audioRecorder = WhatsAppAudioRecorder()
    @FocusState private var composerFocused: Bool

    private static let maxMediaBytes = 25 * 1_024 * 1_024
    private let bottomID = "whatsapp-bottom-anchor"

    private var chat: WhatsAppChat? { store.activeChat }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if let errorMessage {
                errorBanner(errorMessage)
            }
            content
            if let quoted {
                quoteBar(quoted)
            }
            composer
        }
        .toolbar(.hidden, for: .navigationBar)
        .background(InteractivePopGestureEnabler())
        .background(ZenitBrand.cream)
        .task(id: chatId) {
            store.openChat(chatId)
        }
        .onDisappear {
            audioRecorder.cancel()
            if store.activeChatId == chatId, !navigationPath.contains(WhatsAppRoute.navigationId(for: chatId)) {
                store.closeChat()
            }
        }
        .sheet(isPresented: $showOptions) {
            if let chat {
                WhatsAppChatOptionsSheet(store: store, chat: chat)
            }
        }
        .sheet(item: $viewerAttachment) { attachment in
            AttachmentViewerView(attachment: attachment)
        }
        .photosPicker(
            isPresented: $showPhotosPicker,
            selection: $selectedPhotos,
            maxSelectionCount: 5,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            Task { await sendPhotos(items) }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await sendFiles(urls) }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Cabecera

    private var topBar: some View {
        HStack(spacing: 4) {
            Button {
                goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel("Atrás")

            Button {
                showOptions = true
            } label: {
                HStack(spacing: 8) {
                    WhatsAppAvatar(
                        name: chat?.nombreVisible ?? "WhatsApp",
                        url: chat?.pictureURL,
                        isGroup: chat?.isGroup ?? false,
                        size: 32
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(chat?.nombreVisible ?? "WhatsApp")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(chat == nil)
            .accessibilityLabel("Detalles de la conversación")

            Spacer(minLength: 0)

            Button {
                showOptions = true
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .disabled(chat == nil)
            .accessibilityLabel("Opciones de la conversación")
        }
        .padding(.horizontal, 4)
        .background(ZenitBrand.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ZenitBrand.hairline).frame(height: 0.5)
        }
    }

    private var subtitle: String {
        guard let chat else { return "Cargando…" }
        var parts: [String] = []
        if chat.isGroup {
            parts.append("Grupo")
        } else if let phone = WhatsAppFormat.phone(chat.telefono) {
            parts.append(phone)
        } else {
            parts.append("Chat privado")
        }
        if let unit = chat.unidadNegocio { parts.append(unit) }
        if let company = chat.empresaNombre ?? chat.clienteNombre { parts.append(company) }
        if let agent = chat.agente { parts.append(agent.name) }
        parts.append(chat.estado.title)
        return parts.joined(separator: " · ")
    }

    private func goBack() {
        if let index = navigationPath.lastIndex(of: WhatsAppRoute.navigationId(for: chatId)) {
            navigationPath.removeSubrange(index...)
        } else if !navigationPath.isEmpty {
            navigationPath.removeLast()
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button {
                errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cerrar aviso")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.12))
        .foregroundStyle(.primary)
    }

    // MARK: - Mensajes

    @ViewBuilder
    private var content: some View {
        if let threadError = store.threadError {
            ContentUnavailableView {
                Label("Chat no disponible", systemImage: "lock")
            } description: {
                Text(threadError)
            } actions: {
                Button("Volver") { goBack() }
            }
            .frame(maxHeight: .infinity)
        } else if store.hasLoadedActiveChat, chat == nil {
            ContentUnavailableView(
                "Chat no disponible",
                systemImage: "lock",
                description: Text("No tienes acceso o ya no existe.")
            )
            .frame(maxHeight: .infinity)
        } else {
            messagesArea
        }
    }

    private var groupedMessages: [(message: WhatsAppMessage, grouped: Bool)] {
        let items = store.messages
        return items.enumerated().map { index, message in
            guard index > 0 else { return (message, false) }
            let previous = items[index - 1]
            let sameAuthor = previous.fromMe == message.fromMe
                && previous.isNote == message.isNote
                && previous.authorKey == message.authorKey
                && message.timestamp - previous.timestamp < 120_000
                && !previous.isSystem && !message.isSystem
            return (message, sameAuthor)
        }
    }

    private var participantIndexes: [String: Int] {
        let keys = Set(store.messages.filter { !$0.fromMe && !$0.isNote && !$0.isSystem }.map(\.authorKey))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($0.element, $0.offset) })
    }

    private var messagesArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if store.canLoadOlderMessages {
                        Button("Cargar anteriores") { store.loadOlderMessages() }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.bordered)
                            .tint(ZenitBrand.accent)
                            .padding(.vertical, 8)
                    }
                    if !store.hasLoadedMessages {
                        ProgressView().padding(.top, 32)
                    } else if store.messages.isEmpty {
                        Text("Sé el primero en responder.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 32)
                    } else {
                        ForEach(groupedMessages, id: \.message.id) { item in
                            messageRow(item.message, grouped: item.grouped)
                                .id(item.message.id)
                        }
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.messages.count) { _, _ in
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            .onChange(of: store.hasLoadedMessages) { _, loaded in
                guard loaded else { return }
                DispatchQueue.main.async { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .onChange(of: composerFocused) { _, focused in
                guard focused else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: WhatsAppMessage, grouped: Bool) -> some View {
        if message.isSystem {
            Text(message.body ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(ZenitBrand.surfaceMuted)
                .clipShape(Capsule())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        } else {
            WhatsAppBubble(
                message: message,
                grouped: grouped,
                isGroup: chat?.isGroup == true,
                participantIndex: participantIndexes[message.authorKey],
                participant: store.participants.first {
                    $0.waId == message.authorWaId
                        || $0.aliases?.contains(message.authorWaId ?? "") == true
                        || $0.nombre == message.displayAuthor
                },
                canQuote: store.caps.send && !message.isNote,
                onQuote: { quoted = message; composerFocused = true },
                onRetry: { Task { await run { try await store.retry(message) } } },
                onOpenMedia: { openMedia(message) }
            )
        }
    }

    private func openMedia(_ message: WhatsAppMessage) {
        guard let url = message.mediaURL else { return }
        viewerAttachment = CoreAttachment(
            id: message.id,
            empresaId: 0,
            messageId: message.id,
            ticketId: nil,
            uploaderId: "",
            bucket: nil,
            path: nil,
            url: url.absoluteString,
            fileName: message.media?.filename ?? "Adjunto",
            mimeType: message.media?.mimetype,
            sizeBytes: message.media?.size.map { Int($0) },
            createdAt: message.date
        )
    }

    // MARK: - Cita

    private func quoteBar(_ message: WhatsAppMessage) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(ZenitBrand.accentFill)
                .frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Respondiendo a \(message.isMine ? "ti" : message.displayAuthor)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ZenitBrand.accent)
                Text(message.quotePreview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                quoted = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancelar respuesta")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ZenitBrand.surface)
    }

    // MARK: - Compositor

    @ViewBuilder
    private var composer: some View {
        if store.caps.send {
            VStack(spacing: 0) {
                Rectangle().fill(ZenitBrand.hairline).frame(height: 0.5)
                if audioRecorder.isRecording {
                    HStack(spacing: 12) {
                        Button(role: .destructive) {
                            audioRecorder.cancel()
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 38, height: 38)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Cancelar grabación")

                        Circle()
                            .fill(.red)
                            .frame(width: 9, height: 9)
                        Text(recordingTime(audioRecorder.duration))
                            .font(.body.monospacedDigit().weight(.semibold))
                        Text("Grabando nota de voz")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            Task { await sendRecording() }
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.body.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                                .background(ZenitBrand.accentFill)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Enviar nota de voz")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                } else {
                HStack(alignment: .bottom, spacing: 6) {
                    Button {
                        noteMode.toggle()
                        quoted = nil
                    } label: {
                        Image(systemName: noteMode ? "note.text" : "note.text")
                            .font(.title3)
                            .frame(width: 38, height: 38)
                            .background(noteMode ? Color.yellow.opacity(0.35) : Color.clear)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(noteMode ? .primary : .secondary)
                    .accessibilityLabel(noteMode ? "Nota interna activada" : "Escribir nota interna")

                    Menu {
                        Button {
                            showPhotosPicker = true
                        } label: {
                            Label("Fotos y videos", systemImage: "photo.on.rectangle")
                        }
                        Button {
                            showFileImporter = true
                        } label: {
                            Label("Archivos", systemImage: "doc")
                        }
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.title3)
                            .frame(width: 38, height: 38)
                    }
                    .disabled(noteMode || store.isSending || isImportingAttachments)
                    .foregroundStyle(noteMode ? .tertiary : .secondary)
                    .accessibilityLabel("Adjuntar archivo")

                    TextField(
                        noteMode ? "Nota interna (no sale a WhatsApp)" : "Mensaje",
                        text: $draft,
                        axis: .vertical
                    )
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(noteMode ? Color.yellow.opacity(0.18) : ZenitBrand.surfaceMuted)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                    Button {
                        if canSend || noteMode {
                            Task { await send() }
                        } else {
                            Task { await startRecording() }
                        }
                    } label: {
                        Group {
                            if store.isSending || isImportingAttachments {
                                ProgressView()
                            } else if canSend || noteMode {
                                Image(systemName: "arrow.up")
                                    .font(.body.weight(.bold))
                                    .foregroundStyle(.white)
                            } else {
                                Image(systemName: "mic.fill")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 38, height: 38)
                        .background((canSend || !noteMode) ? ZenitBrand.accentFill : Color.gray.opacity(0.4))
                        .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(noteMode && !canSend)
                    .accessibilityLabel(canSend || noteMode ? (noteMode ? "Guardar nota" : "Enviar") : "Grabar nota de voz")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                }
            }
            .background(ZenitBrand.surface)
        } else {
            Text("No tienes permiso para responder.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(ZenitBrand.surface)
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.isSending && !isImportingAttachments
    }

    private func recordingTime(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func startRecording() async {
        do {
            try await audioRecorder.start()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    private func sendRecording() async {
        do {
            let url = try audioRecorder.stop()
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let attachment = CorePendingAttachment(
                fileURL: url,
                fileName: "nota-de-voz-\(UUID().uuidString.prefix(8)).m4a",
                mimeType: "audio/mp4",
                sizeBytes: size
            )
            let quotedMessage = quoted
            quoted = nil
            try await store.sendAttachments([attachment], caption: "", quoting: quotedMessage)
            PendingUploadStorage.remove([attachment])
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    private func send() async {
        let body = draft
        let quotedMessage = quoted
        let asNote = noteMode
        draft = ""
        quoted = nil
        do {
            try await store.sendText(body, quoting: quotedMessage, asNote: asNote)
        } catch {
            draft = body
            quoted = quotedMessage
            errorMessage = Self.describe(error)
        }
    }

    private func run(_ operation: () async throws -> Void) async {
        do {
            try await operation()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    static func describe(_ error: Error) -> String {
        if let clientError = error as? ClientError { return clientError.whatsAppMessage }
        return error.localizedDescription
    }

    // MARK: - Adjuntos

    private func sendPhotos(_ items: [PhotosPickerItem]) async {
        isImportingAttachments = true
        defer {
            selectedPhotos = []
            isImportingAttachments = false
        }
        var attachments: [CorePendingAttachment] = []
        for item in items {
            do {
                let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
                if isVideo {
                    guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { continue }
                    let size = (try? movie.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    guard size <= Self.maxMediaBytes else {
                        try? FileManager.default.removeItem(at: movie.url)
                        errorMessage = "El video supera 25 MB, el máximo de WhatsApp."
                        continue
                    }
                    let ext = movie.url.pathExtension.lowercased()
                    attachments.append(
                        CorePendingAttachment(
                            fileURL: movie.url,
                            fileName: movie.url.lastPathComponent,
                            mimeType: ext == "mov" ? "video/quicktime" : "video/mp4",
                            sizeBytes: size
                        )
                    )
                    continue
                }
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let isGIF = item.supportedContentTypes.contains { $0.conforms(to: .gif) }
                if isGIF {
                    guard data.count <= Self.maxMediaBytes else {
                        errorMessage = "El GIF supera 25 MB."
                        continue
                    }
                    attachments.append(CorePendingAttachment(data: data, fileName: "imagen-\(UUID().uuidString.prefix(8)).gif", mimeType: "image/gif"))
                } else if let image = UIImage(data: data) {
                    // HEIC no es compatible con WhatsApp: se re-codifica a JPEG.
                    guard let jpeg = image.jpegData(compressionQuality: 0.85) else { continue }
                    guard jpeg.count <= Self.maxMediaBytes else {
                        errorMessage = "La imagen supera 25 MB."
                        continue
                    }
                    attachments.append(CorePendingAttachment(data: jpeg, fileName: "imagen-\(UUID().uuidString.prefix(8)).jpg", mimeType: "image/jpeg"))
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        await sendAttachments(attachments)
    }

    private func sendFiles(_ urls: [URL]) async {
        isImportingAttachments = true
        defer { isImportingAttachments = false }
        var attachments: [CorePendingAttachment] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= Self.maxMediaBytes else {
                errorMessage = "\(url.lastPathComponent) supera 25 MB."
                continue
            }
            guard let copy = try? PendingUploadStorage.importFile(at: url, fileName: url.lastPathComponent) else {
                errorMessage = "No se pudo leer \(url.lastPathComponent)."
                continue
            }
            let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            attachments.append(
                CorePendingAttachment(fileURL: copy, fileName: url.lastPathComponent, mimeType: mimeType, sizeBytes: size)
            )
        }
        await sendAttachments(attachments)
    }

    private func sendAttachments(_ attachments: [CorePendingAttachment]) async {
        guard !attachments.isEmpty else { return }
        let caption = draft
        let quotedMessage = quoted
        draft = ""
        quoted = nil
        do {
            try await store.sendAttachments(attachments, caption: caption, quoting: quotedMessage)
        } catch {
            draft = caption
            quoted = quotedMessage
            errorMessage = Self.describe(error)
        }
        PendingUploadStorage.remove(attachments)
    }
}

// MARK: - Burbuja

private struct WhatsAppBubble: View {
    let message: WhatsAppMessage
    let grouped: Bool
    let isGroup: Bool
    let participantIndex: Int?
    let participant: WhatsAppParticipant?
    let canQuote: Bool
    let onQuote: () -> Void
    let onRetry: () -> Void
    let onOpenMedia: () -> Void

    private var isMine: Bool { message.isMine }
    private var isNote: Bool { message.isNote }
    private var alignsRight: Bool {
        isMine || (isGroup && !isNote && (participantIndex ?? 0).isMultiple(of: 2) == false)
    }

    private var participantHue: Double {
        Double(((participantIndex ?? 0) * 137 + 205) % 360) / 360
    }

    private var bubbleColor: Color {
        if isNote { return Color.yellow.opacity(0.28) }
        if isMine { return ZenitBrand.bubbleMine }
        guard isGroup else { return ZenitBrand.surface }
        return Color(hue: participantHue, saturation: 0.26, brightness: 0.99)
    }

    private var participantColor: Color {
        Color(hue: participantHue, saturation: 0.78, brightness: 0.58)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if alignsRight { Spacer(minLength: 48) }
            if isGroup && !isMine && !isNote && !alignsRight {
                participantAvatar
                    .padding(.trailing, 7)
            }
            VStack(alignment: .leading, spacing: 4) {
                if !grouped, !isMine {
                    Text(isNote ? "Nota interna · \(message.agenteNombre ?? "Agente")" : message.displayAuthor)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isNote ? Color.orange : participantColor)
                }
                if let quote = message.quotedMessage {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(quote.author ?? "Mensaje citado")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(ZenitBrand.accent)
                        Text(quote.body)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.055))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(ZenitBrand.accentFill).frame(width: 3)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                attachment
                if let body = message.visibleBody {
                    Text(body)
                        .font(.body)
                        .textSelection(.enabled)
                        .foregroundStyle(.primary)
                }
                HStack(spacing: 4) {
                    if let reactions = message.reactions, !reactions.isEmpty {
                        Text(reactions.map(\.emoji).joined())
                            .font(.caption)
                    }
                    Spacer(minLength: 0)
                    Text(WhatsAppFormat.bubbleTime(message.date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    statusIcon
                    if message.estado == "error" {
                        Button("Reintentar", action: onRetry)
                            .font(.caption2.weight(.semibold))
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(bubbleColor)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                if isNote {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.orange.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .frame(maxWidth: 300, alignment: .leading)
            .contextMenu {
                if canQuote {
                    Button {
                        onQuote()
                    } label: {
                        Label("Responder", systemImage: "arrowshape.turn.up.left")
                    }
                }
                if let body = message.body, !body.isEmpty {
                    Button {
                        UIPasteboard.general.string = body
                    } label: {
                        Label("Copiar", systemImage: "doc.on.doc")
                    }
                }
            }
            if isGroup && !isMine && !isNote && alignsRight {
                participantAvatar
                    .padding(.leading, 7)
            }
            if !alignsRight { Spacer(minLength: 48) }
        }
        .padding(.top, grouped ? 0 : 6)
        .accessibilityElement(children: .combine)
    }

    private var participantAvatar: some View {
        WhatsAppAvatar(
            name: participant?.nombre ?? message.displayAuthor,
            url: participant?.avatarURL ?? message.autorAvatarUrl.flatMap(URL.init(string:)),
            size: 28
        )
        .opacity(grouped ? 0 : 1)
        .accessibilityHidden(grouped)
    }

    @ViewBuilder
    private var attachment: some View {
        if let media = message.media {
            if media.estado == "pendiente" {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Descargando archivo…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if media.estado == "error" || message.mediaURL == nil {
                Label("No se pudo descargar el archivo", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if message.isImage, let url = message.mediaURL {
                Button(action: onOpenMedia) {
                    AttachmentMediaView(url: url, isGIF: media.mimetype == "image/gif")
                        .frame(
                            width: message.isSticker ? 120 : 220,
                            height: message.isSticker ? 120 : 180
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Imagen")
            } else {
                Button(action: onOpenMedia) {
                    HStack(spacing: 8) {
                        Image(systemName: media.isVideo ? "video" : media.isAudio ? "waveform" : "doc")
                            .font(.title3)
                            .foregroundStyle(ZenitBrand.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(media.filename ?? (media.isAudio ? "Nota de voz" : "Documento"))
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            if let size = media.size {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(ZenitBrand.surfaceMuted.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isMine {
            switch message.estado {
            case "error":
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Error de envío")
            case "cola":
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("En cola")
            case "leido":
                ReceiptTicks(receipt: .readByAll)
            case "entregado":
                ReceiptTicks(receipt: .readBySome)
            default:
                ReceiptTicks(receipt: .sent)
            }
        }
    }
}

// MARK: - Opciones

struct WhatsAppChatOptionsSheet: View {
    @ObservedObject var store: WhatsAppStore
    let chat: WhatsAppChat

    @Environment(\.dismiss) private var dismiss
    @State private var clientDraft = ""
    @State private var errorMessage: String?

    private var current: WhatsAppChat { store.activeChat ?? chat }

    private var companySuggestions: [WhatsAppCompany] {
        let term = clientDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return [] }
        return Array(store.companies.filter { $0.nombre.lowercased().contains(term) }.prefix(8))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        WhatsAppAvatar(name: current.nombreVisible, url: current.pictureURL, isGroup: current.isGroup, size: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(current.nombreVisible).font(.headline)
                            if let phone = WhatsAppFormat.phone(current.telefono) {
                                Text(phone).font(.subheadline).foregroundStyle(.secondary)
                            } else if current.isGroup {
                                Text("Grupo de WhatsApp").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listRowBackground(ZenitBrand.surface)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("Estado") {
                    Picker("Estado", selection: Binding(
                        get: { current.estado },
                        set: { state in perform { try await store.setState(state) } }
                    )) {
                        ForEach(WhatsAppChatState.allCases, id: \.self) { state in
                            Text(state.title).tag(state)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!store.caps.assign)
                    .listRowBackground(ZenitBrand.surface)

                    Toggle(isOn: Binding(
                        get: { current.isMuted },
                        set: { muted in perform { try await store.setMuted(muted) } }
                    )) {
                        Label("Silenciar", systemImage: "bell.slash")
                    }
                    .disabled(!store.caps.assign)
                    .listRowBackground(ZenitBrand.surface)
                }

                if store.caps.assign {
                    Section("Agentes asignados") {
                        ForEach(store.agents) { agent in
                            assignRow(
                                title: agent.name,
                                agentId: agent.id,
                                selected: current.assignedToIds.contains(agent.id)
                            )
                        }
                        if current.assignedToIds.isEmpty {
                            Text("Sin asignar")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Unidad de negocio") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                unitChip(title: "Ninguna", selected: current.unidadNegocio == nil) {
                                    perform { try await store.setBusinessUnit(nil) }
                                }
                                ForEach(WhatsAppBusinessUnit.allCases) { unit in
                                    unitChip(title: unit.rawValue, selected: current.unidadNegocio == unit.rawValue) {
                                        perform { try await store.setBusinessUnit(unit) }
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .listRowBackground(ZenitBrand.surface)
                    }

                    Section("Cliente") {
                        if let company = current.empresaNombre ?? current.clienteNombre {
                            HStack {
                                Label(company, systemImage: "building.2")
                                Spacer()
                                Button("Quitar", role: .destructive) {
                                    perform { try await store.clearClient() }
                                }
                                .font(.subheadline)
                            }
                            .listRowBackground(ZenitBrand.surface)
                        } else {
                            Text("Sin cliente vinculado")
                                .foregroundStyle(.secondary)
                                .listRowBackground(ZenitBrand.surface)
                        }
                        TextField("Buscar interno o escribir un nombre", text: $clientDraft)
                            .submitLabel(.done)
                            .onSubmit {
                                let name = clientDraft
                                perform {
                                    try await store.setClientName(name)
                                    clientDraft = ""
                                }
                            }
                            .listRowBackground(ZenitBrand.surface)
                        ForEach(companySuggestions) { company in
                            Button {
                                perform {
                                    try await store.linkCompany(company)
                                    clientDraft = ""
                                }
                            } label: {
                                Label(company.nombre, systemImage: "building.2")
                            }
                            .listRowBackground(ZenitBrand.surface)
                        }
                    }
                }

                if current.isGroup {
                    Section("Miembros · \(store.participants.count)") {
                        if store.participants.isEmpty {
                            Text("WhatsApp todavía no ha sincronizado los miembros.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(store.participants) { participant in
                                HStack(spacing: 10) {
                                    WhatsAppAvatar(name: participant.nombre, url: participant.avatarURL, size: 30)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(participant.nombre).lineLimit(1)
                                        if let phone = WhatsAppFormat.phone(participant.telefono) {
                                            Text(phone).font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if participant.esAdmin {
                                        Text("ADMIN")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(ZenitBrand.surfaceMuted)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ZenitBrand.cream)
            .navigationTitle("Conversación")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }

    private func assignRow(title: String, agentId: String, selected: Bool) -> some View {
        Button {
            var next = current.assignedToIds
            if selected {
                next.removeAll { $0 == agentId }
            } else if !next.contains(agentId) {
                next.append(agentId)
            }
            perform { try await store.assign(to: next) }
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(ZenitBrand.accent)
                }
            }
        }
        .listRowBackground(ZenitBrand.surface)
    }

    private func unitChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selected ? ZenitBrand.ink : ZenitBrand.surfaceMuted)
                .foregroundStyle(selected ? ZenitBrand.cream : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        Task {
            do {
                try await operation()
                errorMessage = nil
            } catch {
                errorMessage = WhatsAppThreadView.describe(error)
            }
        }
    }
}
