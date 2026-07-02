import SwiftUI
import Combine
import PhotosUI
import AVFoundation
import UIKit
import UniformTypeIdentifiers

// MARK: - Models
// CoreSticker, CorePoll y CorePollOption viven en CoreModels.swift para que
// la Share Extension pueda compilar ConvexCoreClient sin este archivo de UI.

struct CoreSlashCommand: Identifiable, Hashable {
    let id = UUID()
    let command: String
    let title: String
    let detail: String
}

let coreSlashCommands: [CoreSlashCommand] = [
    .init(command: "/dado", title: "Dado", detail: "Lanza un dado de 6 caras y gana XP."),
    .init(command: "/trivia", title: "Trivia", detail: "Lanza una pregunta; 60 s para responder."),
    .init(command: "/battle @", title: "Battle", detail: "Reta a un miembro por reacciones."),
    .init(command: "/reto", title: "Reto", detail: "Crea un reto colectivo para el equipo."),
    .init(command: "/pendiente @", title: "Pendiente", detail: "Asigna una tarea a alguien."),
    .init(command: "/reclamar", title: "Reclamar", detail: "Reclama un drop activo del admin."),
    .init(command: "/poll", title: "Encuesta", detail: "Crea una encuesta: pregunta | opción 1 | opción 2."),
    .init(command: "/xp", title: "XP", detail: "Consulta tu XP, ranking, progreso e insignias.")
]

// MARK: - Giphy

struct GiphyGif: Identifiable, Hashable {
    let id: String
    let title: String
    let previewURL: String
    let originalURL: String
}

enum GiphyClient {
    static func search(query: String, apiKey: String) async throws -> [GiphyGif] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let trending = trimmed.isEmpty
        guard var components = URLComponents(
            string: trending
                ? "https://api.giphy.com/v1/gifs/trending"
                : "https://api.giphy.com/v1/gifs/search"
        ) else { return [] }

        var items = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "limit", value: "18"),
            URLQueryItem(name: "rating", value: "g")
        ]
        if !trending { items.append(URLQueryItem(name: "q", value: trimmed)) }
        components.queryItems = items

        guard let url = components.url else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        let decoded = try JSONDecoder().decode(GiphyResponse.self, from: data)
        return decoded.data.compactMap { item in
            let preview = item.images.fixedWidth?.url ?? item.images.downsizedMedium?.url
            let original = item.images.original?.url ?? item.url
            guard let preview, let original else { return nil }
            return GiphyGif(
                id: item.id,
                title: item.title ?? "GIF",
                previewURL: preview,
                originalURL: original
            )
        }
    }
}

private struct GiphyResponse: Decodable {
    let data: [GiphyItem]
}

private struct GiphyItem: Decodable {
    let id: String
    let title: String?
    let url: String?
    let images: GiphyImages
}

private struct GiphyImages: Decodable {
    let original: GiphyImage?
    let fixedWidth: GiphyImage?
    let downsizedMedium: GiphyImage?

    enum CodingKeys: String, CodingKey {
        case original
        case fixedWidth = "fixed_width"
        case downsizedMedium = "downsized_medium"
    }
}

private struct GiphyImage: Decodable {
    let url: String?
}

// MARK: - Voice note recorder

@MainActor
final class VoiceNoteRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private(set) var fileURL: URL?
    private var finishContinuation: CheckedContinuation<Bool, Never>?
    private var finishGeneration = 0

    static func requestPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    /// Requests permission (if needed) and starts recording. Returns false when
    /// the microphone is unavailable or denied.
    func requestAndStart() async -> Bool {
        guard await Self.requestPermission() else { return false }
        return start()
    }

    @discardableResult
    private func start() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("nota-de-voz-\(Int(Date().timeIntervalSince1970)).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            guard recorder.prepareToRecord(), recorder.record() else {
                try? FileManager.default.removeItem(at: url)
                try? session.setActive(false)
                return false
            }

            self.recorder = recorder
            self.fileURL = url
            self.isRecording = true
            self.elapsed = 0

            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let recorder = self.recorder else { return }
                    self.elapsed = recorder.currentTime
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            return true
        } catch {
            return false
        }
    }

    /// Stops recording, waits for the encoder to finish writing the file, and
    /// returns the captured audio data, if any.
    func stopAndFetch() async -> Data? {
        cleanupTimer()
        guard let recorder, finishContinuation == nil else {
            isRecording = false
            return nil
        }

        // `AVAudioRecorder.stop()` finalizes the file asynchronously; reading the
        // file before `audioRecorderDidFinishRecording` fires can return empty
        // data, which made voice notes silently fail to send.
        finishGeneration += 1
        let generation = finishGeneration
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            finishContinuation = continuation
            recorder.stop()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.finishGeneration == generation else { return }
                self.resumeFinish(success: true)
            }
        }

        self.recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              !data.isEmpty else { return nil }
        return data
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        resumeFinish(success: false)
        cleanupTimer()
        isRecording = false
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        fileURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            self.resumeFinish(success: flag)
        }
    }

    private func resumeFinish(success: Bool) {
        finishContinuation?.resume(returning: success)
        finishContinuation = nil
    }

    private func cleanupTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Store helpers

extension CoreChannelsStore {
    var giphyAPIKey: String { CoreEnvironment.load().giphyAPIKey }

    func loadStickers() async -> [CoreSticker] {
        guard configuration.isUsable else { return [] }
        do {
            let config = try await ensureFreshSession()
            let client = try ConvexCoreClient(configuration: config)
            return try await client.listStickers()
        } catch {
            return []
        }
    }

    func uploadSticker(name: String, data: Data, fileName: String, mimeType: String) async -> CoreSticker? {
        guard configuration.isUsable else { return nil }
        do {
            let config = try await ensureFreshSession()
            let client = try ConvexCoreClient(configuration: config)
            return try await client.uploadSticker(name: name, data: data, fileName: fileName, mimeType: mimeType)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Descarga la imagen/sticker de un mensaje recibido y la guarda en la
    /// colección de stickers del usuario (visible también en el stock global).
    func saveStickerFromAttachment(_ attachment: CoreAttachment) async -> Bool {
        guard let url = attachment.resolvedURL else { return false }
        return await saveSticker(name: attachment.fileName, from: url)
    }

    func saveSticker(name: String, from url: URL) async -> Bool {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let format = StickerImageFormat.detect(data)
            let base = (name as NSString).deletingPathExtension
            let stickerName = base.isEmpty ? "Sticker" : base
            let fileName = "sticker-\(Int(Date().timeIntervalSince1970 * 1000)).\(format.fileExtension)"
            return await uploadSticker(
                name: stickerName,
                data: data,
                fileName: fileName,
                mimeType: format.mimeType
            ) != nil
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Sends a recorded voice note as an audio attachment.
    func sendVoiceNote(
        data: Data,
        in channel: CoreChannel,
        parentMessageId: String? = nil,
        replyTo quotedMessage: CoreMessage? = nil
    ) async {
        let fileName = "nota-de-voz-\(Int(Date().timeIntervalSince1970)).m4a"
        let attachment = CorePendingAttachment(data: data, fileName: fileName, mimeType: "audio/m4a")
        await send(
            "Nota de voz",
            attachments: [attachment],
            in: channel,
            parentMessageId: parentMessageId,
            replyTo: quotedMessage
        )
    }

    /// Downloads a remote image/GIF/sticker and sends it as an attachment so it
    /// renders inline (instead of posting a bare URL like the web does).
    func sendRemoteMedia(urlString: String, fileName: String, in channel: CoreChannel, parentMessageId: String? = nil) async {
        guard let url = URL(string: urlString) else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let headerMime = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Type")?
                .split(separator: ";").first.map(String.init)
            let mime = headerMime ?? Self.mimeType(forFileName: fileName)
            let attachment = CorePendingAttachment(data: data, fileName: fileName, mimeType: mime)
            await send("", attachments: [attachment], in: channel, parentMessageId: parentMessageId)
        } catch {
            lastError = error.localizedDescription
        }
    }

    static func mimeType(forFileName name: String) -> String {
        let lower = name.lowercased()
        if lower.hasSuffix(".gif") { return "image/gif" }
        if lower.hasSuffix(".png") { return "image/png" }
        if lower.hasSuffix(".webp") { return "image/webp" }
        if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") { return "image/jpeg" }
        if lower.hasSuffix(".m4a") { return "audio/m4a" }
        return "application/octet-stream"
    }
}

// MARK: - Tool menu

enum ComposerTool: String, CaseIterable, Identifiable {
    case command, file, photo, audio, poll, emoji, gif, sticker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .command: return "Comandos"
        case .file: return "Archivo"
        case .photo: return "Foto"
        case .audio: return "Audio"
        case .poll: return "Encuesta"
        case .emoji: return "Emoji"
        case .gif: return "GIF"
        case .sticker: return "Sticker"
        }
    }

    var systemImage: String {
        switch self {
        case .command: return "command"
        case .file: return "paperclip"
        case .photo: return "photo"
        case .audio: return "mic"
        case .poll: return "chart.bar"
        case .emoji: return "face.smiling"
        case .gif: return "rectangle.stack.badge.play"
        case .sticker: return "face.smiling.inverse"
        }
    }

    var tint: Color {
        switch self {
        case .command: return .blue
        case .file: return .gray
        case .photo: return .green
        case .audio: return .red
        case .poll: return .orange
        case .emoji: return .yellow
        case .gif: return .purple
        case .sticker: return .pink
        }
    }
}

struct ComposerToolsTray: View {
    var tools: [ComposerTool] = ComposerTool.allCases
    let onSelect: (ComposerTool) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(tools) { tool in
                Button {
                    onSelect(tool)
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(tool.tint.opacity(0.15))
                                .frame(width: 46, height: 46)
                            Image(systemName: tool.systemImage)
                                .font(.system(size: 19, weight: .medium))
                                .foregroundStyle(tool.tint)
                        }
                        Text(tool.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(Color.white)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Slash command palette

struct CommandPalettePanel: View {
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(coreSlashCommands) { item in
                    Button {
                        onSelect(item.command)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Text(item.command)
                                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 96, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(item.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 14)
                }
            }
        }
        .frame(maxHeight: 240)
        .background(Color.white)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Poll composer

struct PollComposerPanel: View {
    let onSubmit: (String, [String]) -> Void
    @State private var question = ""
    @State private var optionsText = "Sí\nNo"

    private var options: [String] {
        optionsText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var canSend: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && options.count >= 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nueva encuesta")
                .font(.subheadline.weight(.semibold))

            TextField("¿Qué opción prefiere el equipo?", text: $question)
                .textFieldStyle(.roundedBorder)

            Text("Opciones, una por línea")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Opciones", text: $optionsText, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button {
                    onSubmit(question, options)
                } label: {
                    Label("Enviar encuesta", systemImage: "chart.bar")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(canSend ? Color(red: 0.0, green: 0.48, blue: 0.35) : Color.gray.opacity(0.4))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(14)
        .background(Color.white)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - GIF picker

struct GifPickerPanel: View {
    let apiKey: String
    let onSelect: (GiphyGif) -> Void

    @State private var query = ""
    @State private var results: [GiphyGif] = []
    @State private var isLoading = false
    @State private var didLoad = false
    @State private var errorText: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Buscar GIFs en GIPHY", text: $query)
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                    .onSubmit { Task { await load() } }
                if !query.isEmpty {
                    Button { query = ""; Task { await load() } } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(red: 0.95, green: 0.96, blue: 0.96))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView {
                if isLoading {
                    ProgressView().padding(.top, 24)
                } else {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(results) { gif in
                            Button { onSelect(gif) } label: {
                                AsyncImage(url: URL(string: gif.previewURL)) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image.resizable().scaledToFill()
                                    default:
                                        Rectangle().fill(Color.gray.opacity(0.12))
                                    }
                                }
                                .frame(height: 90)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(12)
        .background(Color.white)
        .overlay(alignment: .top) { Divider() }
        .task {
            guard !didLoad else { return }
            didLoad = true
            await load()
        }
    }

    private func load() async {
        guard !apiKey.isEmpty else {
            errorText = "Configura la API key de GIPHY para buscar GIFs."
            return
        }
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            results = try await GiphyClient.search(query: query, apiKey: apiKey)
            if results.isEmpty { errorText = "Sin resultados." }
        } catch {
            errorText = "No se pudo buscar en GIPHY."
        }
    }
}

// MARK: - Sticker picker

struct StickerPickerPanel: View {
    @ObservedObject var store: CoreChannelsStore
    let onSelect: (CoreSticker) -> Void

    @State private var stickers: [CoreSticker] = []
    @State private var search = ""
    @State private var isLoading = false
    @State private var didLoad = false
    @State private var uploadItem: PhotosPickerItem?
    @State private var showPhotosPicker = false
    @State private var showFileImporter = false
    @State private var isUploading = false
    @State private var importHint: String?
    @State private var scope: StickerScope = .global

    enum StickerScope: String, CaseIterable {
        case global = "Globales"
        case mine = "Míos"
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    private var filtered: [CoreSticker] {
        var base = stickers
        if scope == .mine {
            base = base.filter { $0.createdBy == store.configuration.userId }
        }
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return base }
        return base.filter { $0.name.lowercased().contains(term) }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Buscar stickers", text: $search)
                    .textFieldStyle(.plain)
                Spacer(minLength: 4)
                if isUploading {
                    ProgressView()
                        .controlSize(.small)
                }
                Menu {
                    Button {
                        showPhotosPicker = true
                    } label: {
                        Label("Desde Fotos", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        Task { await pasteFromClipboard() }
                    } label: {
                        Label("Pegar sticker copiado", systemImage: "doc.on.clipboard")
                    }
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Importar archivo (.webp)", systemImage: "folder")
                    }
                } label: {
                    Label("Subir", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                }
                .disabled(isUploading)
            }
            .padding(8)
            .background(Color(red: 0.95, green: 0.96, blue: 0.96))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let importHint {
                Text(importHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Picker("Colección", selection: $scope) {
                ForEach(StickerScope.allCases, id: \.self) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)

            ScrollView {
                if isLoading {
                    ProgressView().padding(.top, 24)
                } else if filtered.isEmpty {
                    Text(scope == .mine
                         ? "Aún no tienes stickers propios. Sube uno o guarda los que te envíen."
                         : "No hay stickers todavía.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 24)
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(filtered) { sticker in
                            Button { onSelect(sticker) } label: {
                                AsyncImage(url: URL(string: sticker.imageURL)) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image.resizable().scaledToFit()
                                    default:
                                        Rectangle().fill(Color.gray.opacity(0.12))
                                    }
                                }
                                .frame(height: 64)
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxHeight: 200)
        }
        .padding(12)
        .background(Color.white)
        .overlay(alignment: .top) { Divider() }
        .task {
            guard !didLoad else { return }
            didLoad = true
            await reload()
        }
        .onChange(of: uploadItem) { _, item in
            guard let item else { return }
            Task { await upload(item) }
        }
        .photosPicker(isPresented: $showPhotosPicker, selection: $uploadItem, matching: .images)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            Task { await importFiles(result) }
        }
    }

    private func reload() async {
        isLoading = true
        stickers = await store.loadStickers()
        isLoading = false
    }

    private func upload(_ item: PhotosPickerItem) async {
        isUploading = true
        defer { isUploading = false; uploadItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        await uploadData(data, name: "Sticker")
    }

    /// Sube datos de imagen detectando su formato real (WebP de WhatsApp,
    /// PNG, GIF o JPEG) para conservar transparencia y animación.
    private func uploadData(_ data: Data, name: String) async {
        let format = StickerImageFormat.detect(data)
        let suffix = UUID().uuidString.prefix(6)
        let fileName = "sticker-\(Int(Date().timeIntervalSince1970 * 1000))-\(suffix).\(format.fileExtension)"
        if let created = await store.uploadSticker(name: name, data: data, fileName: fileName, mimeType: format.mimeType) {
            stickers.insert(created, at: 0)
            importHint = nil
        } else {
            importHint = "No se pudo subir el sticker. Intenta de nuevo."
        }
    }

    /// Importa un sticker copiado en WhatsApp (mantener presionado → Copiar).
    private func pasteFromClipboard() async {
        isUploading = true
        defer { isUploading = false }

        let pasteboard = UIPasteboard.general
        var data: Data?
        for type in [UTType.webP, .png, .gif, .jpeg] {
            if let found = pasteboard.data(forPasteboardType: type.identifier) {
                data = found
                break
            }
        }
        if data == nil, let image = pasteboard.image {
            data = image.pngData()
        }
        guard let data else {
            importHint = "Copia primero un sticker en WhatsApp (mantén presionado → Copiar) y vuelve a intentar."
            return
        }
        await uploadData(data, name: "Sticker WhatsApp")
    }

    /// Importa archivos .webp/.png exportados de WhatsApp desde Archivos.
    private func importFiles(_ result: Result<[URL], Error>) async {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        isUploading = true
        defer { isUploading = false }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            await uploadData(data, name: name.isEmpty ? "Sticker" : name)
        }
    }
}

// MARK: - Voice note bar

struct VoiceNoteBar: View {
    @ObservedObject var recorder: VoiceNoteRecorder
    let onSend: () -> Void
    let onCancel: () -> Void

    private var timeText: String {
        let total = Int(recorder.elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onCancel) {
                Image(systemName: "trash")
                    .font(.system(size: 18))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)

            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .opacity(recorder.isRecording ? 1 : 0.3)

            Text(recorder.isRecording ? "Grabando… \(timeText)" : "Nota de voz \(timeText)")
                .font(.subheadline)
                .foregroundStyle(.primary)

            Spacer()

            Button(action: onSend) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color(red: 0.08, green: 0.65, blue: 0.42))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Audio message player

@MainActor
final class AudioNotePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var current: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var rate: Float = 1.0

    /// Mientras el usuario arrastra la barra, el timer no pisa el progreso.
    var isScrubbing = false

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var loadedURL: URL?

    var rateLabel: String {
        if rate >= 2.0 { return "2×" }
        if rate >= 1.5 { return "1.5×" }
        return "1×"
    }

    func cycleRate() {
        let next: Float = rate >= 2.0 ? 1.0 : (rate >= 1.5 ? 2.0 : 1.5)
        rate = next
        player?.rate = next
    }

    func seek(to fraction: Double) {
        guard let player, player.duration > 0 else { return }
        let clamped = min(max(fraction, 0), 1)
        player.currentTime = player.duration * clamped
        current = player.currentTime
        progress = clamped
    }

    func toggle(url: URL) {
        if isPlaying {
            pause()
            return
        }
        if player != nil, loadedURL == url {
            play()
            return
        }
        Task {
            await load(url: url)
            play()
        }
    }

    private func load(url: URL) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.enableRate = true
            player.rate = rate
            player.prepareToPlay()
            self.player = player
            self.duration = player.duration
            self.loadedURL = url
        } catch {
            self.player = nil
        }
    }

    private func play() {
        guard let player else { return }
        player.rate = rate
        player.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func stop() {
        player?.stop()
        isPlaying = false
        stopTimer()
        player = nil
        loadedURL = nil
        progress = 0
        current = 0
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player, !self.isScrubbing else { return }
                self.current = player.currentTime
                self.progress = player.duration > 0 ? player.currentTime / player.duration : 0
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.progress = 0
            self.current = 0
            self.stopTimer()
        }
    }
}

struct AudioMessageView: View {
    let url: URL
    var tint: Color = Color(red: 0.08, green: 0.55, blue: 0.40)
    @StateObject private var player = AudioNotePlayer()

    private func format(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var label: String {
        if player.duration > 0 {
            return "\(format(player.current)) / \(format(player.duration))"
        }
        return "Nota de voz"
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                player.toggle(url: url)
            } label: {
                if player.isLoading {
                    ProgressView().frame(width: 34, height: 34)
                } else {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(tint)
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Slider(
                    value: Binding(
                        get: { min(max(player.progress, 0), 1) },
                        set: { player.progress = $0 }
                    ),
                    in: 0...1
                ) { editing in
                    player.isScrubbing = editing
                    if !editing {
                        player.seek(to: player.progress)
                    }
                }
                .tint(tint)
                .disabled(player.duration <= 0)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 150)

            Button {
                player.cycleRate()
            } label: {
                Text(player.rateLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 24)
                    .background(tint.opacity(0.12))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Velocidad de reproducción")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(red: 0.95, green: 0.96, blue: 0.96))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onDisappear { player.stop() }
    }
}

// MARK: - Poll voting

struct PollVotingView: View {
    let poll: CorePoll
    let onVote: (String) -> Void

    private func percentage(_ option: CorePollOption) -> Int {
        let total = poll.totalVotes
        guard total > 0 else { return 0 }
        return Int((Double(option.votesCount) / Double(total) * 100).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(poll.question, systemImage: "chart.bar.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            ForEach(poll.options) { option in
                Button {
                    onVote(option.id)
                } label: {
                    ZStack(alignment: .leading) {
                        GeometryReader { geometry in
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(option.votedByMe ? Color.accentColor.opacity(0.22) : Color.gray.opacity(0.12))
                                .frame(width: max(8, geometry.size.width * CGFloat(percentage(option)) / 100))
                        }
                        HStack(spacing: 8) {
                            Image(systemName: option.votedByMe ? "checkmark.circle.fill" : "circle")
                                .font(.caption)
                                .foregroundStyle(option.votedByMe ? Color.accentColor : .secondary)
                            Text(option.label)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 6)
                            Text("\(percentage(option))%")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                    }
                    .frame(height: 34)
                }
                .buttonStyle(.plain)
            }

            Text(poll.totalVotes == 1 ? "1 voto" : "\(poll.totalVotes) votos")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        }
    }
}
