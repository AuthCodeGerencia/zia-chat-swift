import SwiftUI
import Combine
import PencilKit
import AVKit
import AVFoundation
import CoreTransferable

// MARK: - Models

/// Calidad de envío, igual que WhatsApp: estándar (comprimida) o HD.
nonisolated enum MediaSendQuality: String, Sendable {
    case standard
    case hd
}

/// Video elegido en la galería, transferido como archivo (no se carga el
/// contenido completo en memoria).
nonisolated struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mp4" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("video-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

/// Resultado Sendable de la exportación; se convierte a CorePendingAttachment
/// en el MainActor.
nonisolated struct ExportedMedia: Sendable {
    let data: Data
    let fileName: String
    let mimeType: String
}

/// Elemento seleccionado desde la galería pendiente de edición antes de enviar.
struct MediaEditorItem: Identifiable {
    let id = UUID()
    /// Imagen de trabajo (con crop/dibujo ya aplicados). `nil` si es video.
    var image: UIImage?
    /// Estado de edición de video. `nil` si es imagen.
    let video: VideoEditState?
    var quality: MediaSendQuality = .standard
    let originalFileName: String
    let originalMimeType: String

    var isVideo: Bool { video != nil }

    init(image: UIImage, fileName: String, mimeType: String) {
        self.image = image
        self.video = nil
        self.originalFileName = fileName
        self.originalMimeType = mimeType
    }

    init(videoURL: URL, fileName: String, mimeType: String) {
        self.image = nil
        self.video = VideoEditState(url: videoURL)
        self.originalFileName = fileName
        self.originalMimeType = mimeType
    }
}

// MARK: - Video edit state

/// Mantiene el reproductor, la duración, los thumbnails de la línea de tiempo
/// y el rango de recorte (trim) de un video.
@MainActor
final class VideoEditState: ObservableObject {
    let url: URL
    let player: AVPlayer

    @Published var duration: Double = 0
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    @Published var thumbnails: [UIImage] = []
    @Published var isPlaying = false
    @Published var isReady = false

    private var timeObserver: Any?
    private var loadTask: Task<Void, Never>?
    private var isTornDown = false

    init(url: URL) {
        self.url = url
        self.player = AVPlayer(url: url)
        loadTask = Task { [weak self] in
            await self?.load()
        }
    }

    private func load() async {
        let asset = AVURLAsset(url: url)
        let seconds = try? await asset.load(.duration).seconds
        guard !isTornDown else { return }
        if let seconds, seconds.isFinite, seconds > 0 {
            duration = seconds
            trimEnd = seconds
        }
        isReady = duration > 0
        installObserver()
        await generateThumbnails(asset: asset)
    }

    private func installObserver() {
        guard timeObserver == nil, !isTornDown else { return }
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                if time.seconds >= self.trimEnd - 0.05 {
                    self.player.pause()
                    self.isPlaying = false
                    self.seek(to: self.trimStart)
                }
            }
        }
    }

    private func generateThumbnails(asset: AVURLAsset) async {
        guard duration > 0 else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 140, height: 140)
        let count = 8
        var result: [UIImage] = []
        for index in 0..<count {
            guard !Task.isCancelled, !isTornDown else { return }
            let seconds = duration * (Double(index) + 0.5) / Double(count)
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let cgImage = try? await generator.image(at: time).image {
                result.append(UIImage(cgImage: cgImage))
            }
        }
        guard !isTornDown else { return }
        thumbnails = result
    }

    func seek(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            let current = player.currentTime().seconds
            if current < trimStart || current >= trimEnd - 0.05 {
                seek(to: trimStart)
            }
            player.play()
            isPlaying = true
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func teardown() {
        isTornDown = true
        loadTask?.cancel()
        loadTask = nil
        pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player.replaceCurrentItem(with: nil)
        try? FileManager.default.removeItem(at: url)
    }

    var trimmedDuration: Double { max(0, trimEnd - trimStart) }

    var isTrimmed: Bool {
        guard duration > 0 else { return false }
        return trimStart > 0.1 || trimEnd < duration - 0.1
    }
}

// MARK: - Editor principal

/// Editor de medios estilo WhatsApp: recortar, dibujar, caption, calidad HD o
/// comprimida para imágenes; preview, trim y caption para videos.
struct MediaEditorView: View {
    let onCancel: () -> Void
    let onSend: ([CorePendingAttachment], String) -> Void
    /// Guarda la imagen actual (ya editada) como sticker. Devuelve `true` si
    /// se subió correctamente. `nil` oculta el botón de sticker.
    let onSaveSticker: ((Data) async -> Bool)?

    @State private var items: [MediaEditorItem]
    @State private var selectedIndex = 0
    @State private var caption = ""
    @State private var editingMode: EditingMode = .none
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var stickerSaveState: StickerSaveState = .idle
    @FocusState private var captionFocused: Bool

    private enum EditingMode {
        case none, crop, draw
    }

    private enum StickerSaveState: Equatable {
        case idle, saving, saved, failed
    }

    init(
        items: [MediaEditorItem],
        onCancel: @escaping () -> Void,
        onSend: @escaping ([CorePendingAttachment], String) -> Void,
        onSaveSticker: ((Data) async -> Bool)? = nil
    ) {
        _items = State(initialValue: items)
        self.onCancel = onCancel
        self.onSend = onSend
        self.onSaveSticker = onSaveSticker
    }

    private var currentItem: MediaEditorItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch editingMode {
            case .crop:
                if let image = currentItem?.image {
                    ImageCropView(
                        image: image,
                        onCancel: { editingMode = .none },
                        onDone: { cropped in
                            items[selectedIndex].image = cropped
                            editingMode = .none
                        }
                    )
                }
            case .draw:
                if let image = currentItem?.image {
                    ImageDrawView(
                        image: image,
                        onCancel: { editingMode = .none },
                        onDone: { drawn in
                            items[selectedIndex].image = drawn
                            editingMode = .none
                        }
                    )
                }
            case .none:
                mainEditor
            }

            if isExporting {
                Color.black.opacity(0.6).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text("Preparando…")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                }
            }
        }
        .alert("No se pudo preparar el archivo", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("Entendido", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        .onDisappear {
            for item in items {
                item.video?.teardown()
            }
        }
    }

    private var mainEditor: some View {
        VStack(spacing: 0) {
            topBar
            mediaPager
            bottomArea
        }
    }

    // MARK: Barra superior

    private var topBar: some View {
        HStack(spacing: 18) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancelar")

            Spacer()

            if let item = currentItem {
                if !item.isVideo {
                    Button { editingMode = .crop } label: {
                        Image(systemName: "crop.rotate")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Recortar")

                    Button { editingMode = .draw } label: {
                        Image(systemName: "pencil.tip")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dibujar")

                    if onSaveSticker != nil {
                        stickerButton
                    }
                }

                qualityToggle(for: item)
            }
        }
        .padding(.horizontal, 8)
        // Margen extra bajo el notch/Dynamic Island para que las herramientas
        // (cerrar, recortar, dibujar, HD) no queden pegadas al borde.
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    /// Guarda la imagen actual como sticker en la colección de la empresa.
    private var stickerButton: some View {
        Button {
            saveCurrentAsSticker()
        } label: {
            Group {
                switch stickerSaveState {
                case .idle:
                    Image(systemName: "face.smiling")
                case .saving:
                    ProgressView().tint(.white).controlSize(.small)
                case .saved:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(red: 0.18, green: 0.85, blue: 0.55))
                case .failed:
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .disabled(stickerSaveState == .saving)
        .accessibilityLabel("Guardar como sticker")
    }

    private func saveCurrentAsSticker() {
        guard let onSaveSticker,
              let image = currentItem?.image,
              let data = image.pngData() else { return }
        stickerSaveState = .saving
        Task {
            let ok = await onSaveSticker(data)
            stickerSaveState = ok ? .saved : .failed
            try? await Task.sleep(for: .seconds(2))
            stickerSaveState = .idle
        }
    }

    private func qualityToggle(for item: MediaEditorItem) -> some View {
        Button {
            items[selectedIndex].quality = item.quality == .hd ? .standard : .hd
        } label: {
            Text("HD")
                .font(.caption.weight(.bold))
                .foregroundStyle(item.quality == .hd ? .black : .white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(item.quality == .hd ? Color.white : Color.white.opacity(0.18))
                )
                .overlay(
                    Capsule().stroke(Color.white.opacity(0.7), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.quality == .hd ? "Enviar en HD" : "Enviar comprimido")
    }

    // MARK: Contenido central

    private var mediaPager: some View {
        TabView(selection: $selectedIndex) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Group {
                    if let video = item.video {
                        VideoEditorPane(state: video)
                    } else if let image = item.image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(.horizontal, 4)
                    }
                }
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onChange(of: selectedIndex) { _, _ in
            for item in items {
                item.video?.pause()
            }
        }
        .onTapGesture { captionFocused = false }
    }

    // MARK: Zona inferior

    private var bottomArea: some View {
        VStack(spacing: 10) {
            if items.count > 1 {
                thumbnailStrip
            }
            captionBar
        }
        .padding(.bottom, 8)
    }

    private var thumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    ZStack(alignment: .topTrailing) {
                        EditorThumbContent(item: item)
                        .frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(
                                    index == selectedIndex ? Color(red: 0.08, green: 0.65, blue: 0.42) : Color.white.opacity(0.25),
                                    lineWidth: index == selectedIndex ? 2.5 : 1
                                )
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if item.isVideo {
                                Image(systemName: "video.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white)
                                    .padding(3)
                            }
                        }
                        .onTapGesture { selectedIndex = index }

                        if index == selectedIndex {
                            Button {
                                removeItem(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 6, y: -6)
                            .accessibilityLabel("Quitar")
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
        }
    }

    private var captionBar: some View {
        HStack(spacing: 10) {
            TextField(
                "",
                text: $caption,
                prompt: Text("Añade un comentario…").foregroundStyle(Color.white.opacity(0.55)),
                axis: .vertical
            )
            .lineLimit(1...4)
            .focused($captionFocused)
            .foregroundStyle(.white)
            .tint(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            Button(action: sendAll) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color(red: 0.08, green: 0.65, blue: 0.42))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(items.isEmpty || isExporting)
            .accessibilityLabel("Enviar")
        }
        .padding(.horizontal, 12)
    }

    private func removeItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        items[index].video?.teardown()
        items.remove(at: index)
        if items.isEmpty {
            onCancel()
        } else if selectedIndex >= items.count {
            selectedIndex = items.count - 1
        }
    }

    private func sendAll() {
        captionFocused = false
        for item in items { item.video?.pause() }
        isExporting = true
        let snapshot = items
        let text = caption
        Task {
            var attachments: [CorePendingAttachment] = []
            for item in snapshot {
                do {
                    let exported: ExportedMedia
                    if let video = item.video {
                        exported = try await MediaExporter.exportVideo(
                            url: video.url,
                            trimStart: video.trimStart,
                            trimEnd: video.trimEnd,
                            duration: video.duration,
                            quality: item.quality,
                            originalFileName: item.originalFileName,
                            originalMimeType: item.originalMimeType
                        )
                    } else if let image = item.image {
                        exported = try await MediaExporter.exportImage(image, quality: item.quality)
                    } else {
                        throw MediaExportError.invalidItem
                    }
                    guard exported.data.count <= 15 * 1_024 * 1_024 else {
                        throw MediaExportError.tooLarge
                    }
                    attachments.append(
                        CorePendingAttachment(
                            data: exported.data,
                            fileName: exported.fileName,
                            mimeType: exported.mimeType
                        )
                    )
                } catch let error as MediaExportError {
                    isExporting = false
                    exportError = error.message
                    return
                } catch {
                    isExporting = false
                    exportError = error.localizedDescription
                    return
                }
            }
            isExporting = false
            onSend(attachments, text)
        }
    }
}

// MARK: - Miniatura de la tira inferior

/// Observa el estado del video para refrescar la miniatura cuando los
/// thumbnails terminan de generarse de forma asíncrona.
private struct EditorThumbContent: View {
    let item: MediaEditorItem

    var body: some View {
        if let image = item.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else if let video = item.video {
            VideoThumb(state: video)
        } else {
            Rectangle().fill(Color.white.opacity(0.15))
        }
    }

    private struct VideoThumb: View {
        @ObservedObject var state: VideoEditState

        var body: some View {
            if let thumb = state.thumbnails.first {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Color.white.opacity(0.15))
            }
        }
    }
}

// MARK: - Video pane

private struct VideoEditorPane: View {
    @ObservedObject var state: VideoEditState

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                PlayerLayerView(player: state.player)

                Button {
                    state.togglePlay()
                } label: {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .opacity(state.isPlaying ? 0.35 : 1)
                .accessibilityLabel(state.isPlaying ? "Pausar" : "Reproducir")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if state.isReady {
                VStack(spacing: 6) {
                    VideoTrimBar(state: state)
                        .frame(height: 52)

                    HStack {
                        Text(format(state.trimStart))
                        Spacer()
                        Label(format(state.trimmedDuration), systemImage: "scissors")
                            .labelStyle(.titleAndIcon)
                        Spacer()
                        Text(format(state.trimEnd))
                    }
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

/// Capa AVPlayerLayer sin controles del sistema, para preview limpio.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: LayerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

// MARK: - Trim bar

private struct VideoTrimBar: View {
    @ObservedObject var state: VideoEditState

    private let handleWidth: CGFloat = 16
    private let minimumGap: Double = 1.0

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let duration = max(state.duration, 0.01)
            let startX = CGFloat(state.trimStart / duration) * width
            let endX = CGFloat(state.trimEnd / duration) * width

            ZStack(alignment: .leading) {
                // Tira de thumbnails
                HStack(spacing: 0) {
                    if state.thumbnails.isEmpty {
                        Rectangle().fill(Color.white.opacity(0.12))
                    } else {
                        ForEach(Array(state.thumbnails.enumerated()), id: \.offset) { _, thumb in
                            Image(uiImage: thumb)
                                .resizable()
                                .scaledToFill()
                                .frame(width: width / CGFloat(max(state.thumbnails.count, 1)), height: 48)
                                .clipped()
                        }
                    }
                }
                .frame(width: width, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                // Sombreado fuera de la selección
                Rectangle()
                    .fill(Color.black.opacity(0.65))
                    .frame(width: max(0, startX), height: 48)
                Rectangle()
                    .fill(Color.black.opacity(0.65))
                    .frame(width: max(0, width - endX), height: 48)
                    .offset(x: endX)

                // Borde de la selección
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.white, lineWidth: 2.5)
                    .frame(width: max(handleWidth, endX - startX), height: 48)
                    .offset(x: startX)

                trimHandle(systemImage: "chevron.compact.left")
                    .position(x: startX + handleWidth / 2 - 4, y: 24)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let gap = min(minimumGap, duration)
                                let seconds = Double(value.location.x / width) * duration
                                let clamped = min(max(seconds, 0), max(state.trimEnd - gap, 0))
                                state.trimStart = clamped
                                state.pause()
                                state.seek(to: clamped)
                            }
                    )

                trimHandle(systemImage: "chevron.compact.right")
                    .position(x: endX - handleWidth / 2 + 4, y: 24)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let gap = min(minimumGap, duration)
                                let seconds = Double(value.location.x / width) * duration
                                let clamped = max(min(seconds, duration), min(state.trimStart + gap, duration))
                                state.trimEnd = clamped
                                state.pause()
                                state.seek(to: clamped)
                            }
                    )
            }
            .frame(height: 48)
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    private func trimHandle(systemImage: String) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.white)
            .frame(width: handleWidth, height: 48)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black.opacity(0.7))
            }
            .contentShape(Rectangle().inset(by: -12))
    }
}

// MARK: - Crop

private struct ImageCropView: View {
    let onCancel: () -> Void
    let onDone: (UIImage) -> Void

    @State private var workingImage: UIImage
    @State private var imageFrame: CGRect = .zero
    @State private var cropRect: CGRect = .zero
    @State private var dragStartRect: CGRect?
    @State private var squareAspect = false

    init(image: UIImage, onCancel: @escaping () -> Void, onDone: @escaping (UIImage) -> Void) {
        _workingImage = State(initialValue: image)
        self.onCancel = onCancel
        self.onDone = onDone
    }

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancelar", action: onCancel)
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    rotateImage()
                } label: {
                    Image(systemName: "rotate.right")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rotar 90 grados")

                Button {
                    toggleSquare()
                } label: {
                    Image(systemName: squareAspect ? "square.fill" : "square.dashed")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.leading, 14)
                .accessibilityLabel("Relación 1:1")

                Spacer()
                Button("Listo") { applyCrop() }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color(red: 0.18, green: 0.85, blue: 0.55))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .padding(.top, 8)

            GeometryReader { geometry in
                ZStack {
                    Image(uiImage: workingImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)

                    // Sombreado fuera del recorte
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: geometry.size))
                        path.addRect(cropRect)
                    }
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                    cropOverlay
                }
                .onAppear { recalculate(in: geometry.size) }
                .onChange(of: geometry.size) { _, newSize in recalculate(in: newSize) }
                .onChange(of: workingImage) { _, _ in recalculate(in: geometry.size) }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private var cropOverlay: some View {
        // Rejilla + borde
        Path { path in
            path.addRect(cropRect)
            let thirdW = cropRect.width / 3
            let thirdH = cropRect.height / 3
            for index in 1...2 {
                let x = cropRect.minX + thirdW * CGFloat(index)
                path.move(to: CGPoint(x: x, y: cropRect.minY))
                path.addLine(to: CGPoint(x: x, y: cropRect.maxY))
                let y = cropRect.minY + thirdH * CGFloat(index)
                path.move(to: CGPoint(x: cropRect.minX, y: y))
                path.addLine(to: CGPoint(x: cropRect.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.9), lineWidth: 1)
        .allowsHitTesting(false)

        // Zona interior arrastrable
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: max(cropRect.width - 44, 0), height: max(cropRect.height - 44, 0))
            .position(x: cropRect.midX, y: cropRect.midY)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStartRect == nil { dragStartRect = cropRect }
                        guard let start = dragStartRect else { return }
                        var rect = start
                        rect.origin.x = clamp(start.origin.x + value.translation.width, imageFrame.minX, imageFrame.maxX - rect.width)
                        rect.origin.y = clamp(start.origin.y + value.translation.height, imageFrame.minY, imageFrame.maxY - rect.height)
                        cropRect = rect
                    }
                    .onEnded { _ in dragStartRect = nil }
            )

        // Esquinas
        ForEach(Array(Corner.allCases.enumerated()), id: \.offset) { _, corner in
            cornerHandle(corner)
        }
    }

    private func cornerHandle(_ corner: Corner) -> some View {
        let point: CGPoint
        switch corner {
        case .topLeft: point = CGPoint(x: cropRect.minX, y: cropRect.minY)
        case .topRight: point = CGPoint(x: cropRect.maxX, y: cropRect.minY)
        case .bottomLeft: point = CGPoint(x: cropRect.minX, y: cropRect.maxY)
        case .bottomRight: point = CGPoint(x: cropRect.maxX, y: cropRect.maxY)
        }

        return Circle()
            .fill(Color.white)
            .frame(width: 22, height: 22)
            .shadow(radius: 2)
            .contentShape(Circle().inset(by: -14))
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStartRect == nil { dragStartRect = cropRect }
                        updateRect(corner: corner, translation: value.translation)
                    }
                    .onEnded { _ in dragStartRect = nil }
            )
    }

    private func updateRect(corner: Corner, translation: CGSize) {
        guard let start = dragStartRect else { return }
        let minSide: CGFloat = 70
        var rect = start

        switch corner {
        case .topLeft:
            let newX = clamp(start.minX + translation.width, imageFrame.minX, start.maxX - minSide)
            let newY = clamp(start.minY + translation.height, imageFrame.minY, start.maxY - minSide)
            rect = CGRect(x: newX, y: newY, width: start.maxX - newX, height: start.maxY - newY)
        case .topRight:
            let newMaxX = clamp(start.maxX + translation.width, start.minX + minSide, imageFrame.maxX)
            let newY = clamp(start.minY + translation.height, imageFrame.minY, start.maxY - minSide)
            rect = CGRect(x: start.minX, y: newY, width: newMaxX - start.minX, height: start.maxY - newY)
        case .bottomLeft:
            let newX = clamp(start.minX + translation.width, imageFrame.minX, start.maxX - minSide)
            let newMaxY = clamp(start.maxY + translation.height, start.minY + minSide, imageFrame.maxY)
            rect = CGRect(x: newX, y: start.minY, width: start.maxX - newX, height: newMaxY - start.minY)
        case .bottomRight:
            let newMaxX = clamp(start.maxX + translation.width, start.minX + minSide, imageFrame.maxX)
            let newMaxY = clamp(start.maxY + translation.height, start.minY + minSide, imageFrame.maxY)
            rect = CGRect(x: start.minX, y: start.minY, width: newMaxX - start.minX, height: newMaxY - start.minY)
        }

        if squareAspect {
            let side = min(rect.width, rect.height)
            switch corner {
            case .topLeft:
                rect = CGRect(x: start.maxX - side, y: start.maxY - side, width: side, height: side)
            case .topRight:
                rect = CGRect(x: start.minX, y: start.maxY - side, width: side, height: side)
            case .bottomLeft:
                rect = CGRect(x: start.maxX - side, y: start.minY, width: side, height: side)
            case .bottomRight:
                rect = CGRect(x: start.minX, y: start.minY, width: side, height: side)
            }
        }

        cropRect = rect
    }

    private func toggleSquare() {
        squareAspect.toggle()
        guard squareAspect else { return }
        let side = min(cropRect.width, cropRect.height)
        cropRect = CGRect(
            x: cropRect.midX - side / 2,
            y: cropRect.midY - side / 2,
            width: side,
            height: side
        )
    }

    private func rotateImage() {
        workingImage = workingImage.zia_rotated90Clockwise()
    }

    private func recalculate(in containerSize: CGSize) {
        guard containerSize.width > 0, containerSize.height > 0,
              workingImage.size.width > 0, workingImage.size.height > 0 else { return }
        let scale = min(
            containerSize.width / workingImage.size.width,
            containerSize.height / workingImage.size.height
        )
        let width = workingImage.size.width * scale
        let height = workingImage.size.height * scale
        imageFrame = CGRect(
            x: (containerSize.width - width) / 2,
            y: (containerSize.height - height) / 2,
            width: width,
            height: height
        )
        cropRect = imageFrame
        if squareAspect {
            let side = min(width, height)
            cropRect = CGRect(
                x: imageFrame.midX - side / 2,
                y: imageFrame.midY - side / 2,
                width: side,
                height: side
            )
        }
    }

    private func applyCrop() {
        guard imageFrame.width > 0, imageFrame.height > 0 else {
            onDone(workingImage)
            return
        }
        let normalized = workingImage.zia_normalizedUp()
        guard let cgImage = normalized.cgImage else {
            onDone(workingImage)
            return
        }
        let scale = normalized.size.width / imageFrame.width
        var pixelRect = CGRect(
            x: (cropRect.minX - imageFrame.minX) * scale,
            y: (cropRect.minY - imageFrame.minY) * scale,
            width: cropRect.width * scale,
            height: cropRect.height * scale
        ).integral
        pixelRect = pixelRect.intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard !pixelRect.isEmpty, let cropped = cgImage.cropping(to: pixelRect) else {
            onDone(workingImage)
            return
        }
        onDone(UIImage(cgImage: cropped))
    }
}

// MARK: - Draw

private struct ImageDrawView: View {
    let image: UIImage
    let onCancel: () -> Void
    let onDone: (UIImage) -> Void

    @State private var canvasView = PKCanvasView()
    @State private var selectedColor: Color = .red
    @State private var lineWidth: CGFloat = 7
    @State private var canvasFrame: CGRect = .zero

    private let palette: [Color] = [.white, .black, .red, .orange, .yellow, .green, .blue, .purple]

    private var currentTool: PKInkingTool {
        PKInkingTool(.pen, color: UIColor(selectedColor), width: lineWidth)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancelar", action: onCancel)
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    canvasView.undoManager?.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Deshacer")
                Spacer()
                Button("Listo") { flatten() }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color(red: 0.18, green: 0.85, blue: 0.55))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .padding(.top, 8)

            GeometryReader { geometry in
                let fitted = fittedFrame(in: geometry.size)
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)

                    PencilCanvasRepresentable(canvasView: canvasView, tool: currentTool)
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)
                        .onAppear { canvasFrame = fitted }
                        .onChange(of: geometry.size) { _, newSize in
                            canvasFrame = fittedFrame(in: newSize)
                        }
                }
            }

            // Paleta de colores y grosor
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    ForEach(Array(palette.enumerated()), id: \.offset) { _, color in
                        Circle()
                            .fill(color)
                            .frame(width: 26, height: 26)
                            .overlay {
                                Circle().stroke(
                                    Color.white,
                                    lineWidth: color == selectedColor ? 3 : 1
                                )
                            }
                            .onTapGesture { selectedColor = color }
                    }
                }
                HStack(spacing: 12) {
                    Image(systemName: "scribble")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                    Slider(value: $lineWidth, in: 2...24)
                        .tint(.white)
                        .frame(maxWidth: 220)
                    Circle()
                        .fill(selectedColor)
                        .frame(width: min(max(lineWidth, 4), 24), height: min(max(lineWidth, 4), 24))
                }
            }
            .padding(.vertical, 14)
        }
    }

    private func fittedFrame(in containerSize: CGSize) -> CGRect {
        guard containerSize.width > 0, containerSize.height > 0,
              image.size.width > 0, image.size.height > 0 else { return .zero }
        let scale = min(containerSize.width / image.size.width, containerSize.height / image.size.height)
        let width = image.size.width * scale
        let height = image.size.height * scale
        return CGRect(
            x: (containerSize.width - width) / 2,
            y: (containerSize.height - height) / 2,
            width: width,
            height: height
        )
    }

    private func flatten() {
        guard canvasFrame.width > 0, !canvasView.drawing.bounds.isEmpty else {
            onDone(image)
            return
        }
        let base = image.zia_normalizedUp()
        let renderScale = base.size.width / canvasFrame.width
        let drawingImage = canvasView.drawing.image(
            from: CGRect(origin: .zero, size: canvasFrame.size),
            scale: renderScale
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let result = UIGraphicsImageRenderer(size: base.size, format: format).image { _ in
            base.draw(in: CGRect(origin: .zero, size: base.size))
            drawingImage.draw(in: CGRect(origin: .zero, size: base.size))
        }
        onDone(result)
    }
}

private struct PencilCanvasRepresentable: UIViewRepresentable {
    let canvasView: PKCanvasView
    let tool: PKInkingTool

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.drawingPolicy = .anyInput
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.tool = tool
        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        uiView.tool = tool
    }
}

// MARK: - Export

nonisolated enum MediaExportError: Error, Sendable {
    case tooLarge
    case exportFailed
    case invalidItem

    var message: String {
        switch self {
        case .tooLarge:
            return "El archivo supera los 15 MB después de procesarlo. Prueba la calidad comprimida o recorta el video."
        case .exportFailed:
            return "No se pudo procesar el video. Intenta de nuevo."
        case .invalidItem:
            return "El archivo seleccionado no es válido."
        }
    }
}

/// Exportación fuera del MainActor para no congelar la UI durante el
/// redimensionado/JPEG de imágenes o la transcodificación de video.
nonisolated enum MediaExporter {

    // MARK: Imagen

    static func exportImage(_ image: UIImage, quality: MediaSendQuality) async throws -> ExportedMedia {
        let maxDimension: CGFloat = quality == .hd ? 4096 : 1600
        let jpegQuality: CGFloat = quality == .hd ? 0.92 : 0.7

        var working = image.zia_normalizedUp()
        let largest = max(working.size.width, working.size.height)
        if largest > maxDimension {
            let factor = maxDimension / largest
            working = working.zia_resized(to: CGSize(
                width: (working.size.width * factor).rounded(),
                height: (working.size.height * factor).rounded()
            ))
        }
        guard let data = working.jpegData(compressionQuality: jpegQuality) else {
            throw MediaExportError.invalidItem
        }
        let suffix = quality == .hd ? "hd" : "std"
        return ExportedMedia(
            data: data,
            fileName: "imagen-\(Int(Date().timeIntervalSince1970))-\(suffix).jpg",
            mimeType: "image/jpeg"
        )
    }

    // MARK: Video

    static func exportVideo(
        url: URL,
        trimStart: Double,
        trimEnd: Double,
        duration: Double,
        quality: MediaSendQuality,
        originalFileName: String,
        originalMimeType: String
    ) async throws -> ExportedMedia {
        let isTrimmed = duration > 0 && (trimStart > 0.1 || trimEnd < duration - 0.1)
        let limit = 15 * 1_024 * 1_024
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0

        // Sin recorte, en HD y dentro del límite: enviar el original tal cual
        // (evita recomprimir). Si supera el límite, se recodifica abajo.
        if !isTrimmed, quality == .hd, fileSize > 0, fileSize <= limit {
            let data = try Data(contentsOf: url)
            return ExportedMedia(data: data, fileName: originalFileName, mimeType: originalMimeType)
        }

        let asset = AVURLAsset(url: url)
        let preset = quality == .hd
            ? AVAssetExportPresetHighestQuality
            : AVAssetExportPreset1280x720
        let start = CMTime(seconds: max(trimStart, 0), preferredTimescale: 600)
        let end = CMTime(seconds: max(min(trimEnd, duration), trimStart), preferredTimescale: 600)
        let range = CMTimeRange(start: start, end: end)

        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MediaExportError.exportFailed
        }
        session.timeRange = range

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-export-\(UUID().uuidString).mp4")

        do {
            try await session.export(to: outputURL, as: .mp4)
        } catch {
            // Algunos códecs no admiten contenedor MP4: reintentar como .mov.
            let movURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("video-export-\(UUID().uuidString).mov")
            guard let retrySession = AVAssetExportSession(asset: asset, presetName: preset) else {
                throw MediaExportError.exportFailed
            }
            retrySession.timeRange = range
            do {
                try await retrySession.export(to: movURL, as: .mov)
                let data = try Data(contentsOf: movURL)
                try? FileManager.default.removeItem(at: movURL)
                return ExportedMedia(
                    data: data,
                    fileName: "video-\(Int(Date().timeIntervalSince1970)).mov",
                    mimeType: "video/quicktime"
                )
            } catch {
                throw MediaExportError.exportFailed
            }
        }

        let data = try Data(contentsOf: outputURL)
        try? FileManager.default.removeItem(at: outputURL)
        return ExportedMedia(
            data: data,
            fileName: "video-\(Int(Date().timeIntervalSince1970)).mp4",
            mimeType: "video/mp4"
        )
    }
}

// MARK: - UIImage helpers

extension UIImage {
    /// Re-renderiza la imagen con orientación .up y escala 1 (tamaño en píxeles),
    /// para que los recortes con CGImage sean consistentes.
    nonisolated func zia_normalizedUp() -> UIImage {
        let pixelSize = CGSize(width: size.width * scale, height: size.height * scale)
        guard pixelSize.width > 0, pixelSize.height > 0 else { return self }
        if imageOrientation == .up, scale == 1 { return self }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: pixelSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: pixelSize))
        }
    }

    /// Rota la imagen 90° en sentido horario.
    nonisolated func zia_rotated90Clockwise() -> UIImage {
        let pixelWidth = size.width * scale
        let pixelHeight = size.height * scale
        let newSize = CGSize(width: pixelHeight, height: pixelWidth)
        guard newSize.width > 0, newSize.height > 0 else { return self }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { context in
            let cgContext = context.cgContext
            cgContext.translateBy(x: newSize.width, y: 0)
            cgContext.rotate(by: .pi / 2)
            draw(in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        }
    }

    /// Redimensiona a un tamaño objetivo en píxeles.
    nonisolated func zia_resized(to target: CGSize) -> UIImage {
        guard target.width > 0, target.height > 0 else { return self }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
    min(max(value, lower), max(lower, upper))
}
