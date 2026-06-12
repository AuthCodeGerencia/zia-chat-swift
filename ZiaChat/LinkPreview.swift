import SwiftUI
import LinkPresentation

// MARK: - URL detection

extension String {
    /// First http(s) URL found in the text (supports bare "www." links).
    var firstDetectedURL: URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(startIndex..., in: self)
        let matches = detector.matches(in: self, range: range)
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
    private static var failed: Set<URL> = []
    private static var inFlight: [URL: Task<LPLinkMetadata?, Never>] = [:]

    static func metadata(for url: URL) async -> LPLinkMetadata? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if failed.contains(url) { return nil }

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
            .background(Color(red: 0.95, green: 0.96, blue: 0.96))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
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

        guard let provider = metadata.imageProvider else { return }
        image = await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
    }
}
