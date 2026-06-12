import QuickLook
import SwiftUI

/// Visor modal a pantalla completa para adjuntos del chat.
/// Imágenes (con zoom), videos (reproducibles), PDFs y documentos se muestran
/// con QuickLook tras descargar el archivo firmado a un temporal local.
struct AttachmentViewerView: View {
    @Environment(\.dismiss) private var dismiss
    let attachment: CoreAttachment

    @State private var localURL: URL?
    @State private var loadError: String?

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
        do {
            let (data, _) = try await URLSession.shared.data(from: remote)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("zia-attachments", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let safeName = attachment.fileName.isEmpty ? "archivo" : attachment.fileName
            let fileURL = directory.appendingPathComponent("\(attachment.id)-\(safeName)")
            try data.write(to: fileURL, options: .atomic)
            localURL = fileURL
        } catch {
            loadError = error.localizedDescription
        }
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
