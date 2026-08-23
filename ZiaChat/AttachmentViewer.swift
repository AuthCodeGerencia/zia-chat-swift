import QuickLook
import SwiftUI

/// Visor modal a pantalla completa para adjuntos del chat.
/// Imágenes (con zoom), videos (reproducibles), PDFs y documentos se muestran
/// con QuickLook tras descargar el archivo firmado a Caches (se reutiliza en
/// aperturas posteriores).
struct AttachmentViewerView: View {
    @Environment(\.dismiss) private var dismiss
    let attachment: CoreAttachment

    @State private var localURL: URL?
    @State private var loadError: String?
    @State private var progress: Double?

    var body: some View {
        NavigationStack {
            Group {
                if let localURL {
                    QuickLookPreview(url: localURL)
                        .ignoresSafeArea(edges: .bottom)
                } else if let loadError {
                    ContentUnavailableView(
                        "No se pudo abrir el archivo",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                } else if let progress {
                    ProgressView(value: progress) {
                        Text("Cargando…")
                    }
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 40)
                } else {
                    ProgressView("Cargando…")
                }
            }
            .navigationTitle(attachment.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let localURL {
                        ShareLink(item: localURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .task { await download() }
        }
    }

    private func download() async {
        guard let remote = attachment.resolvedURL else {
            loadError = "El adjunto no tiene una URL disponible."
            return
        }
        let safeName = attachment.fileName.isEmpty ? "archivo" : attachment.fileName
        let fileURL = AttachmentCacheStorage.directory.appendingPathComponent("\(attachment.id)-\(safeName)")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            localURL = fileURL
            return
        }
        let task = Task.detached(priority: .userInitiated) {
            try await AttachmentDownloader.download(from: remote, to: fileURL) { fraction in
                Task { @MainActor in progress = fraction }
            }
        }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            localURL = fileURL
        } catch let error where error is CancellationError || (error as? URLError)?.code == .cancelled {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }
}

/// Carpeta en Caches con los adjuntos ya descargados por el visor.
nonisolated enum AttachmentCacheStorage {
    static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("zia-attachments", isDirectory: true)

    /// Borra adjuntos que no se han vuelto a abrir en `age` (por defecto 7 días)
    /// para que la carpeta no crezca sin límite.
    static func purgeStale(olderThan age: TimeInterval = 7 * 24 * 60 * 60) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys)
        ) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for file in files {
            let modified = (try? file.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast
            if modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

/// Descarga en streaming a un archivo `.part` (sin cargar el adjunto entero
/// en memoria) y lo mueve al destino al terminar, informando del progreso.
private nonisolated enum AttachmentDownloader {
    private static let chunkSize = 256 * 1024

    static func download(
        from remote: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let (bytes, response) = try await URLSession.shared.bytes(from: remote)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let expected = response.expectedContentLength

        let partURL = destination.appendingPathExtension("part")
        try? fileManager.removeItem(at: partURL)
        guard fileManager.createFile(atPath: partURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: partURL)
        var succeeded = false
        defer {
            try? handle.close()
            if !succeeded { try? fileManager.removeItem(at: partURL) }
        }

        var buffer = Data()
        buffer.reserveCapacity(chunkSize)
        var received: Int64 = 0
        var lastReported = 0.0
        for try await byte in bytes {
            buffer.append(byte)
            guard buffer.count >= chunkSize else { continue }
            try Task.checkCancellation()
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
            if expected > 0 {
                let fraction = min(1, Double(received) / Double(expected))
                if fraction - lastReported >= 0.01 {
                    lastReported = fraction
                    progress(fraction)
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        try handle.close()
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: partURL, to: destination)
        succeeded = true
    }
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            controller.reloadData()
        }
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
