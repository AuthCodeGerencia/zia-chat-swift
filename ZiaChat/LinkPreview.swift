import SwiftUI
import LinkPresentation

// MARK: - URL detection

enum LinkDetection {
    /// Un NSDataDetector cuesta milisegundos en crearse; se comparte entre
    /// burbujas y texto enriquecido.
    static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static let domainSuffixRegex = try! NSRegularExpression(pattern: #"\.[A-Za-z]{2,}"#)

    /// Filtro barato para que el texto sin enlaces nunca pase por el detector.
    /// Acepta esquemas, "www." y dominios pelados ("zenit.com"); el detector
    /// sigue siendo quien decide si hay un enlace real.
    static func mayContainLink(_ text: String) -> Bool {
        if text.range(of: "http", options: .caseInsensitive) != nil
            || text.range(of: "www.", options: .caseInsensitive) != nil {
            return true
        }
        guard text.contains(".") else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return domainSuffixRegex.firstMatch(in: text, range: range) != nil
    }
}

extension String {
    /// First http(s) URL found in the text (supports bare "www." links).
    var firstDetectedURL: URL? {
        guard LinkDetection.mayContainLink(self) else { return nil }
        let range = NSRange(startIndex..., in: self)
        let matches = LinkDetection.detector.matches(in: self, range: range)
        for match in matches {
            guard let raw = match.url else { continue }
            if raw.scheme == nil, raw.absoluteString.hasPrefix("www.") {
                return URL(string: "https://\(raw.absoluteString)")
            }
            if raw.scheme == "http" || raw.scheme == "https" {
                return raw
            }
        }
        return nil
    }
}

// MARK: - Metadata cache

/// Caches fetched link metadata so scrolling doesn't re-fetch pages, and
/// remembers failures to avoid retry loops.
@MainActor
enum LinkMetadataStore {
    private static let cache = NSCache<NSURL, LPLinkMetadata>()
    /// Miniatura (≤ 720×360 px, el tamaño de la tarjeta a 3x) del og:image;
    /// el `NSItemProvider` de LPLinkMetadata decodifica la imagen completa en
    /// cada carga, así que solo se hace una vez por URL.
    private static let imageCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 24 * 1024 * 1024
        cache.countLimit = 200
        return cache
    }()
    private static var failed: Set<URL> = []
    private static var inFlight: [URL: Task<LPLinkMetadata?, Never>] = [:]

    private static let thumbnailPixelSize = CGSize(width: 720, height: 360)

    static func cachedMetadata(for url: URL) -> LPLinkMetadata? {
        cache.object(forKey: url as NSURL)
    }

    static func cachedImage(for url: URL) -> UIImage? {
        imageCache.object(forKey: url as NSURL)
    }

    static func image(for url: URL, metadata: LPLinkMetadata) async -> UIImage? {
        if let cached = cachedImage(for: url) { return cached }
        guard let provider = metadata.imageProvider else { return nil }
        let loaded: UIImage? = await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
        guard let loaded else { return nil }
        let image = await loaded.byPreparingThumbnail(ofSize: coverSize(for: loaded)) ?? loaded
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        imageCache.setObject(image, forKey: url as NSURL, cost: cost)
        return image
    }

    /// Tamaño mínimo que cubre la tarjeta (`scaledToFill`) sin superar el original.
    private static func coverSize(for image: UIImage) -> CGSize {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelWidth > 0, pixelHeight > 0 else { return thumbnailPixelSize }
        let factor = min(1, max(thumbnailPixelSize.width / pixelWidth, thumbnailPixelSize.height / pixelHeight))
        return CGSize(width: (pixelWidth * factor).rounded(), height: (pixelHeight * factor).rounded())
    }

    static func metadata(for url: URL) async -> LPLinkMetadata? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if failed.contains(url) || ZiaDemoMode.isEnabled { return nil }

        if let task = inFlight[url] {
            return await task.value
        }

        let task = Task<LPLinkMetadata?, Never> {
            let provider = LPMetadataProvider()
            provider.timeout = 10
            do {
                let metadata = try await provider.startFetchingMetadata(for: url)
                return metadata
            } catch {
                return nil
            }
        }
        inFlight[url] = task
        let metadata = await task.value
        inFlight[url] = nil

        if let metadata {
            cache.setObject(metadata, forKey: url as NSURL)
        } else {
            failed.insert(url)
        }
        return metadata
    }
}

// MARK: - Preview card

/// Rich preview card for a URL found inside a message: image, title and
/// domain. Tapping opens the link. Falls back to a compact domain row when
/// the page metadata can't be loaded.
struct LinkPreviewCard: View {
    let url: URL
    var width: CGFloat = 240

    @State private var title: String?
    @State private var image: UIImage?
    @State private var didLoad = false

    init(url: URL, width: CGFloat = 240) {
        self.url = url
        self.width = width
        // Sembrar desde la caché evita el parpadeo "Cargando…" + pop-in de la
        // imagen cada vez que la burbuja vuelve a entrar en pantalla.
        let cached = LinkMetadataStore.cachedMetadata(for: url)
        _title = State(initialValue: cached?.title)
        _image = State(initialValue: LinkMetadataStore.cachedImage(for: url))
        _didLoad = State(initialValue: cached != nil)
    }

    private var host: String {
        url.host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
    }

    var body: some View {
        Link(destination: url) {
            VStack(alignment: .leading, spacing: 0) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width, height: 120)
                        .clipped()
                }

                VStack(alignment: .leading, spacing: 3) {
                    if let title, !title.isEmpty {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    } else if !didLoad {
                        Text("Cargando vista previa…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.caption2)
                        Text(host)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(width: width, alignment: .leading)
            }
            .background(ZenitBrand.surfaceMuted)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(ZenitBrand.hairline, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .task(id: url) {
            await loadMetadata()
        }
    }

    private func loadMetadata() async {
        defer { didLoad = true }
        guard let metadata = await LinkMetadataStore.metadata(for: url) else { return }
        title = metadata.title
        if image == nil {
            image = await LinkMetadataStore.image(for: url, metadata: metadata)
        }
    }
}
