import Foundation
import UniformTypeIdentifiers

/// Contenido recibido desde otra app (WhatsApp, Fotos, Archivos, Safari...).
struct SharedPayload {
    var text: String = ""
    var attachments: [CorePendingAttachment] = []
    /// Archivos descartados por superar el límite de tamaño.
    var oversizedFileNames: [String] = []
}

/// Convierte los NSItemProvider del extension context en texto + adjuntos
/// listos para enviarse con ConvexCoreClient.
enum SharedItemLoader {
    /// Límite por archivo para no exceder la memoria de la extensión (~120 MB).
    static let maxAttachmentBytes = 45 * 1024 * 1024

    static func load(from items: [NSExtensionItem]) async -> SharedPayload {
        var payload = SharedPayload()
        var texts: [String] = []

        for item in items {
            for provider in item.attachments ?? [] {
                if isPlainText(provider) {
                    if let text = await loadText(provider), !text.isEmpty {
                        texts.append(text)
                    }
                } else if isWebURL(provider) {
                    if let url = await loadURL(provider) {
                        texts.append(url.absoluteString)
                    } else if let text = await loadText(provider), !text.isEmpty {
                        texts.append(text)
                    }
                } else if let attachment = await loadFile(provider) {
                    if attachment.sizeBytes > maxAttachmentBytes {
                        payload.oversizedFileNames.append(attachment.fileName)
                    } else {
                        payload.attachments.append(attachment)
                    }
                } else if let text = await loadText(provider), !text.isEmpty {
                    texts.append(text)
                }
            }
        }

        payload.text = texts.joined(separator: "\n\n")
        return payload
    }

    // MARK: - Clasificación

    private static func isPlainText(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) &&
        !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) &&
        !provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) &&
        !provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) &&
        !provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier)
    }

    private static func isWebURL(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) &&
        !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) &&
        !provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) &&
        !provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
    }

    // MARK: - Carga

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { value, _ in
                if let text = value as? String {
                    continuation.resume(returning: text)
                } else if let data = value as? Data {
                    continuation.resume(returning: String(data: data, encoding: .utf8))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { value, _ in
                continuation.resume(returning: value as? URL)
            }
        }
    }

    private static func loadFile(_ provider: NSItemProvider) async -> CorePendingAttachment? {
        let preferred: [UTType] = [.image, .movie, .audio, .pdf, .fileURL, .data]
        let registered = provider.registeredTypeIdentifiers
        let typeIdentifier = registered.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return preferred.contains { type.conforms(to: $0) }
        } ?? registered.first

        guard let typeIdentifier else { return nil }

        return await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                // El archivo temporal se borra al salir del handler:
                // hay que leer los datos aquí mismo.
                guard let url, let data = try? Data(contentsOf: url) else {
                    continuation.resume(returning: nil)
                    return
                }

                let fileName = url.lastPathComponent
                let mimeType =
                    UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ??
                    UTType(typeIdentifier)?.preferredMIMEType ??
                    "application/octet-stream"

                continuation.resume(
                    returning: CorePendingAttachment(data: data, fileName: fileName, mimeType: mimeType)
                )
            }
        }
    }
}
