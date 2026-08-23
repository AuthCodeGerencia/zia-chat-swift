import ImageIO
import SwiftUI
import UIKit

// MARK: - Loader

/// Cargador de imágenes remotas con caché en memoria (NSCache), caché de disco
/// (URLCache propio), deduplicación de descargas en vuelo y *downsampling*
/// fuera del hilo principal.
///
/// Sustituye a `AsyncImage` en listas: `AsyncImage` no comparte caché entre
/// filas (cada fila reciclada vuelve a pedir la imagen) y decodifica la foto a
/// resolución completa aunque se pinte en un avatar de 30 pt.
/// `NSCache` es thread-safe pero no `Sendable`; este envoltorio permite leerla
/// de forma síncrona desde el hilo principal sin pasar por el actor.
nonisolated final class ImageMemoryCache<Key: AnyObject, Value: AnyObject>: @unchecked Sendable {
    private let cache = NSCache<Key, Value>()

    init(totalCostLimit: Int, countLimit: Int) {
        cache.totalCostLimit = totalCostLimit
        cache.countLimit = countLimit
    }

    func object(forKey key: Key) -> Value? {
        cache.object(forKey: key)
    }

    func setObject(_ object: Value, forKey key: Key, cost: Int) {
        cache.setObject(object, forKey: key, cost: cost)
    }
}

actor RemoteImageLoader {
    static let shared = RemoteImageLoader()

    nonisolated private let memoryCache = ImageMemoryCache<NSString, UIImage>(
        totalCostLimit: 96 * 1024 * 1024,
        countLimit: 600
    )

    /// Bytes crudos de GIF/stickers animados (se animan desde los datos, no
    /// desde un `UIImage` decodificado).
    nonisolated private let dataCache = ImageMemoryCache<NSURL, NSData>(
        totalCostLimit: 48 * 1024 * 1024,
        countLimit: 200
    )

    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var dataInFlight: [URL: Task<Data?, Never>] = [:]

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        // Política del protocolo: los avatares se reescriben en la misma URL,
        // así que hay que respetar max-age; la caché en memoria ya evita
        // repetir descargas dentro de la sesión.
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.urlCache = URLCache(
            memoryCapacity: 16 * 1024 * 1024,
            diskCapacity: 256 * 1024 * 1024,
            directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("zia-remote-images", isDirectory: true)
        )
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    /// Lectura síncrona de la caché en memoria (para evitar el parpadeo del
    /// placeholder cuando una fila se recrea al hacer scroll).
    nonisolated func cachedImage(for url: URL, targetSize: CGSize?, scale: CGFloat) -> UIImage? {
        memoryCache.object(forKey: Self.cacheKey(url, targetSize: targetSize, scale: scale))
    }

    func image(for url: URL, targetSize: CGSize?, scale: CGFloat) async -> UIImage? {
        let key = Self.cacheKey(url, targetSize: targetSize, scale: scale)
        let flightKey = key as String
        if let cached = memoryCache.object(forKey: key) {
            return cached
        }
        if let running = inFlight[flightKey] {
            return await running.value
        }

        let session = self.session
        let task = Task<UIImage?, Never>(priority: .userInitiated) {
            guard let (data, response) = try? await session.data(from: url) else { return nil }
            // Las URLs file:// (adjuntos pendientes) responden con un URLResponse plano.
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            return Self.downsampledImage(from: data, targetSize: targetSize, scale: scale)
        }
        inFlight[flightKey] = task
        let image = await task.value
        inFlight[flightKey] = nil

        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            memoryCache.setObject(image, forKey: key, cost: cost)
        }
        return image
    }

    /// Precalienta la caché (p. ej. al recibir un mensaje con foto) para que
    /// la burbuja aparezca ya decodificada al hacer scroll.
    func prefetch(_ url: URL, targetSize: CGSize?, scale: CGFloat) async {
        _ = await image(for: url, targetSize: targetSize, scale: scale)
    }

    nonisolated func cachedData(for url: URL) -> Data? {
        dataCache.object(forKey: url as NSURL) as Data?
    }

    /// Descarga (o sirve de caché) los bytes de una imagen animada.
    func data(for url: URL) async -> Data? {
        if let cached = cachedData(for: url) {
            return cached
        }
        if let running = dataInFlight[url] {
            return await running.value
        }

        let session = self.session
        let task = Task<Data?, Never>(priority: .userInitiated) {
            if url.isFileURL {
                return try? Data(contentsOf: url)
            }
            guard let (data, response) = try? await session.data(from: url) else { return nil }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            return data
        }
        dataInFlight[url] = task
        let data = await task.value
        dataInFlight[url] = nil

        if let data {
            dataCache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
        }
        return data
    }

    nonisolated private static func cacheKey(_ url: URL, targetSize: CGSize?, scale: CGFloat) -> NSString {
        guard let targetSize else { return url.absoluteString as NSString }
        let side = Int(max(targetSize.width, targetSize.height) * scale)
        return "\(url.absoluteString)#\(side)" as NSString
    }

    /// Decodifica con `ImageIO` al tamaño de destino: mucha menos memoria y CPU
    /// que `UIImage(data:)` + `resizable()` para fotos grandes.
    nonisolated static func downsampledImage(from data: Data, targetSize: CGSize?, scale: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return UIImage(data: data)
        }

        guard let targetSize, targetSize.width > 0, targetSize.height > 0 else {
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options) else {
                return UIImage(data: data)
            }
            return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
        }

        let maxPixel = max(targetSize.width, targetSize.height) * scale
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel.rounded(.up)),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }
}

// MARK: - View

/// Imagen remota con caché. Úsala en lugar de `AsyncImage` dentro de listas.
///
/// ```swift
/// RemoteImage(url: user.avatarURL, targetSize: CGSize(width: 30, height: 30)) { image in
///     image.resizable().scaledToFill()
/// } placeholder: {
///     Circle().fill(.gray)
/// }
/// ```
struct RemoteImage<Content: View, Placeholder: View>: View {
    let url: URL?
    /// Tamaño en puntos al que se decodifica la imagen (downsampling). `nil`
    /// decodifica a tamaño completo: úsalo solo para visores a pantalla completa.
    var targetSize: CGSize?
    var transition: AnyTransition = .opacity
    let content: (Image) -> Content
    let placeholder: () -> Placeholder
    /// Vista cuando la descarga falla (404, URL firmada caducada, sin red).
    /// `nil` mantiene el placeholder.
    let failure: (() -> AnyView)?

    @Environment(\.displayScale) private var displayScale
    @State private var loaded: UIImage?
    @State private var loadedURL: URL?
    @State private var failedURL: URL?

    init(
        url: URL?,
        targetSize: CGSize? = nil,
        transition: AnyTransition = .opacity,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.targetSize = targetSize
        self.transition = transition
        self.content = content
        self.placeholder = placeholder
        self.failure = nil
    }

    init<Failure: View>(
        url: URL?,
        targetSize: CGSize? = nil,
        transition: AnyTransition = .opacity,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder failure: @escaping () -> Failure
    ) {
        self.url = url
        self.targetSize = targetSize
        self.transition = transition
        self.content = content
        self.placeholder = placeholder
        self.failure = { AnyView(failure()) }
    }

    private var resolvedImage: UIImage? {
        guard let url else { return nil }
        if loadedURL == url, let loaded { return loaded }
        return RemoteImageLoader.shared.cachedImage(for: url, targetSize: targetSize, scale: displayScale)
    }

    var body: some View {
        ZStack {
            if let image = resolvedImage {
                content(Image(uiImage: image))
                    .transition(transition)
            } else if let url, failedURL == url, let failure {
                failure()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else {
                loaded = nil
                loadedURL = nil
                failedURL = nil
                return
            }
            if RemoteImageLoader.shared.cachedImage(for: url, targetSize: targetSize, scale: displayScale) != nil {
                return
            }
            let image = await RemoteImageLoader.shared.image(for: url, targetSize: targetSize, scale: displayScale)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                loaded = image
                loadedURL = url
                failedURL = image == nil ? url : nil
            }
        }
    }
}
