import Foundation
import UniformTypeIdentifiers
import UIKit
import ImageIO

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
    /// Límite por archivo. Los archivos viven en disco (App Group), así que el
    /// tope real de memoria lo marca `maxTotalBytes`.
    static let maxAttachmentBytes = 45 * 1024 * 1024
    /// Presupuesto total de la petición para no superar la memoria de la
    /// extensión (~120 MB) al subir varios adjuntos.
    static let maxTotalBytes = 60 * 1024 * 1024
    /// Lado máximo (px) al que se reducen las imágenes compartidas.
    static let maxImageDimension: CGFloat = 2048

    static func load(from items: [NSExtensionItem]) async -> SharedPayload {
        var payload = SharedPayload()
        var texts: [String] = []
        var totalBytes = 0

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
                    if attachment.sizeBytes > maxAttachmentBytes
                        || totalBytes + attachment.sizeBytes > maxTotalBytes {
                        payload.oversizedFileNames.append(attachment.fileName)
                        PendingUploadStorage.remove([attachment])
                    } else {
                        totalBytes += attachment.sizeBytes
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

                // La URL solo es válida dentro de este bloque: se copia al
                // contenedor compartido sin cargar el archivo en memoria.
                continuation.resume(returning: makeFileAttachment(
                    sourceURL: url,
                    provider: provider,
                    typeIdentifier: typeIdentifier
                ))
            }
        }
    }

    /// Solo las fotos opacas se recodifican a JPEG; PNG/WebP/GIF conservan sus
    /// bytes y extensión para no perder transparencia (stickers de WhatsApp).
    private nonisolated static func isOpaquePhoto(_ type: UTType) -> Bool {
        type.conforms(to: .jpeg) || type.conforms(to: .heic)
            || type.conforms(to: .heif) || type.conforms(to: .tiff)
    }

    private nonisolated static func hasAlpha(_ image: UIImage) -> Bool {
        guard let alphaInfo = image.cgImage?.alphaInfo else { return false }
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            return true
        }
    }

    private nonisolated static func makeFileAttachment(
        sourceURL: URL,
        provider: NSItemProvider,
        typeIdentifier: String
    ) -> CorePendingAttachment? {
        let type = UTType(filenameExtension: sourceURL.pathExtension)
            ?? UTType(typeIdentifier)
            ?? .data
        let fileName = sourceURL.lastPathComponent.isEmpty
            ? self.fileName(provider: provider, type: type)
            : sourceURL.lastPathComponent

        if isOpaquePhoto(type), let jpeg = downsampledJPEG(at: sourceURL) {
            return CorePendingAttachment(
                data: jpeg,
                fileName: ((fileName as NSString).deletingPathExtension) + ".jpg",
                mimeType: "image/jpeg"
            )
        }

        guard let copy = try? PendingUploadStorage.importFile(at: sourceURL, fileName: fileName) else {
            return nil
        }
        return CorePendingAttachment(
            fileURL: copy,
            fileName: fileName,
            mimeType: type.preferredMIMEType ?? "application/octet-stream"
        )
    }

    /// Decodifica la imagen reducida a `maxImageDimension` con ImageIO (sin
    /// cargar el bitmap completo) y la recodifica como JPEG.
    private nonisolated static func downsampledJPEG(at url: URL) -> Data? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImageDimension,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85)
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
                          let (data, type) = downsampledImageData(image) {
                    continuation.resume(returning: CorePendingAttachment(
                        data: data,
                        fileName: fileName(provider: provider, type: type),
                        mimeType: type.preferredMIMEType ?? "image/jpeg"
                    ))
                } else if let url = value as? URL, url.isFileURL {
                    continuation.resume(returning: makeFileAttachment(
                        sourceURL: url,
                        provider: provider,
                        typeIdentifier: typeIdentifier
                    ))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Reduce la imagen a `maxImageDimension`; las imágenes con canal alfa se
    /// codifican como PNG para conservar la transparencia.
    private nonisolated static func downsampledImageData(_ image: UIImage) -> (Data, UTType)? {
        let largest = max(image.size.width, image.size.height) * image.scale
        var working = image
        if largest > maxImageDimension {
            let factor = maxImageDimension / largest
            let target = CGSize(
                width: (image.size.width * factor).rounded(),
                height: (image.size.height * factor).rounded()
            )
            guard let thumbnail = image.preparingThumbnail(of: target) else { return nil }
            working = thumbnail
        }
        if hasAlpha(image) {
            return working.pngData().map { ($0, .png) }
        }
        return working.jpegData(compressionQuality: 0.85).map { ($0, .jpeg) }
    }

    private nonisolated static func makeAttachment(
        data: Data,
        provider: NSItemProvider,
        typeIdentifier: String
    ) -> CorePendingAttachment {
        let type = UTType(typeIdentifier) ?? .data
        if isOpaquePhoto(type), let image = UIImage(data: data),
           let (downsampled, outputType) = downsampledImageData(image) {
            return CorePendingAttachment(
                data: downsampled,
                fileName: fileName(provider: provider, type: outputType),
                mimeType: outputType.preferredMIMEType ?? "image/jpeg"
            )
        }
        return CorePendingAttachment(
            data: data,
            fileName: fileName(provider: provider, type: type),
            mimeType: type.preferredMIMEType ?? "application/octet-stream"
        )
    }

    private nonisolated static func fileName(provider: NSItemProvider, type: UTType) -> String {
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
