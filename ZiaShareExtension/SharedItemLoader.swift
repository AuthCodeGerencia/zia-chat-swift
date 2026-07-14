import Foundation
import UniformTypeIdentifiers
import UIKit

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

        if let attachment = await loadFileRepresentation(provider, typeIdentifier: typeIdentifier) {
            return attachment
        }

        // Varias apps (especialmente Fotos y WhatsApp) anuncian una imagen o
        // video, pero no entregan una URL temporal. En esos casos iOS sí puede
        // entregar los bytes o el objeto directamente.
        if let data = await loadDataRepresentation(provider, typeIdentifier: typeIdentifier) {
            return makeAttachment(data: data, provider: provider, typeIdentifier: typeIdentifier)
        }

        return await loadItemRepresentation(provider, typeIdentifier: typeIdentifier)
    }

    private static func loadFileRepresentation(
        _ provider: NSItemProvider,
        typeIdentifier: String
    ) async -> CorePendingAttachment? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }

                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }

                guard let data = try? Data(contentsOf: url) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: makeAttachment(
                    data: data,
                    provider: provider,
                    typeIdentifier: typeIdentifier,
                    sourceURL: url
                ))
            }
        }
    }

    private static func loadDataRepresentation(
        _ provider: NSItemProvider,
        typeIdentifier: String
    ) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private static func loadItemRepresentation(
        _ provider: NSItemProvider,
        typeIdentifier: String
    ) async -> CorePendingAttachment? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { value, _ in
                if let data = value as? Data {
                    continuation.resume(returning: makeAttachment(
                        data: data,
                        provider: provider,
                        typeIdentifier: typeIdentifier
                    ))
                } else if let image = value as? UIImage,
                          let data = image.pngData() {
                    continuation.resume(returning: CorePendingAttachment(
                        data: data,
                        fileName: fileName(provider: provider, type: .png),
                        mimeType: UTType.png.preferredMIMEType ?? "image/png"
                    ))
                } else if let url = value as? URL,
                          let data = try? Data(contentsOf: url) {
                    continuation.resume(returning: makeAttachment(
                        data: data,
                        provider: provider,
                        typeIdentifier: typeIdentifier,
                        sourceURL: url
                    ))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func makeAttachment(
        data: Data,
        provider: NSItemProvider,
        typeIdentifier: String,
        sourceURL: URL? = nil
    ) -> CorePendingAttachment {
        let type = sourceURL.flatMap { UTType(filenameExtension: $0.pathExtension) }
            ?? UTType(typeIdentifier)
            ?? .data
        return CorePendingAttachment(
            data: data,
            fileName: sourceURL?.lastPathComponent ?? fileName(provider: provider, type: type),
            mimeType: type.preferredMIMEType ?? "application/octet-stream"
        )
    }

    private static func fileName(provider: NSItemProvider, type: UTType) -> String {
        let suggested = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let suggested, !suggested.isEmpty {
            if (suggested as NSString).pathExtension.isEmpty,
               let fileExtension = type.preferredFilenameExtension {
                return "\(suggested).\(fileExtension)"
            }
            return suggested
        }
        return "Compartido.\(type.preferredFilenameExtension ?? "bin")"
    }
}
