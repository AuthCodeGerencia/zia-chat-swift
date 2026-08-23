import ImageIO
import SwiftUI
import UIKit

/// Origen de una imagen animada (GIF/APNG/WebP): URL remota o `file://`, o
/// bytes ya en memoria (adjunto pendiente).
enum AnimatedImageSource: Equatable {
    case url(URL)
    case data(Data)

    /// Identidad barata para no reiniciar la animación en cada `updateUIView`.
    var identity: String {
        switch self {
        case .url(let url):
            return "url:" + url.absoluteString
        case .data(let data):
            return "data:\(data.count):" + data.prefix(32).map { String($0, radix: 16) }.joined()
        }
    }
}

/// `UIImageView` animado con ImageIO (`CGAnimateImageDataWithBlock`), en lugar
/// de un `WKWebView` por burbuja: sin proceso web, sin descarga duplicada y la
/// animación se detiene al desmontar la vista. Si los bytes solo contienen un
/// fotograma (stickers PNG/WebP estáticos) se decodifica una miniatura a
/// `targetSize` fuera del hilo principal; así la decisión se toma por
/// contenido y no por la extensión de la URL (Convex storage no la tiene).
struct AnimatedImageView: UIViewRepresentable {
    let source: AnimatedImageSource
    var contentMode: UIView.ContentMode = .scaleAspectFill
    /// Tamaño en puntos al que se decodifican las imágenes estáticas.
    var targetSize: CGSize?

    @Environment(\.displayScale) private var displayScale

    init(url: URL, contentMode: UIView.ContentMode = .scaleAspectFill, targetSize: CGSize? = nil) {
        self.source = .url(url)
        self.contentMode = contentMode
        self.targetSize = targetSize
    }

    init(data: Data, contentMode: UIView.ContentMode = .scaleAspectFill, targetSize: CGSize? = nil) {
        self.source = .data(data)
        self.contentMode = contentMode
        self.targetSize = targetSize
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = contentMode
        view.clipsToBounds = true
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        view.contentMode = contentMode
        context.coordinator.load(source, into: view, targetSize: targetSize, scale: displayScale)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize? {
        let intrinsic = uiView.image?.size ?? .zero
        return CGSize(width: proposal.width ?? intrinsic.width, height: proposal.height ?? intrinsic.height)
    }

    static func dismantleUIView(_ view: UIImageView, coordinator: Coordinator) {
        coordinator.stop()
    }

    /// Resultado de inspeccionar los bytes fuera del hilo principal.
    private nonisolated enum Decoded: Sendable {
        case animated
        case still(UIImage?)

        static func inspect(_ data: Data, targetSize: CGSize?, scale: CGFloat) -> Decoded {
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            if let source = CGImageSourceCreateWithData(data as CFData, options),
               CGImageSourceGetCount(source) > 1 {
                return .animated
            }
            return .still(RemoteImageLoader.downsampledImage(from: data, targetSize: targetSize, scale: scale))
        }
    }

    @MainActor
    final class Coordinator {
        private var identity: String?
        private var loadTask: Task<Void, Never>?
        /// Cada animación captura su generación; al cambiar, el bloque de
        /// ImageIO pide parar y la animación anterior se libera.
        private var generation = 0

        func load(_ source: AnimatedImageSource, into view: UIImageView, targetSize: CGSize?, scale: CGFloat) {
            guard identity != source.identity else { return }
            identity = source.identity
            stop()
            view.image = nil

            let expected = generation
            let cachedData: Data?
            switch source {
            case .data(let data):
                cachedData = data
            case .url(let url):
                cachedData = RemoteImageLoader.shared.cachedData(for: url)
            }

            loadTask = Task { [weak self, weak view] in
                let data: Data
                if let cachedData {
                    data = cachedData
                } else if case .url(let url) = source, let fetched = await RemoteImageLoader.shared.data(for: url) {
                    data = fetched
                } else {
                    return
                }
                let decoded = await Task.detached(priority: .userInitiated) {
                    Decoded.inspect(data, targetSize: targetSize, scale: scale)
                }.value
                guard !Task.isCancelled, let self, let view, self.generation == expected else { return }
                switch decoded {
                case .animated:
                    self.animate(data, in: view)
                case .still(let image):
                    view.image = image
                }
            }
        }

        func stop() {
            loadTask?.cancel()
            loadTask = nil
            generation += 1
        }

        private func animate(_ data: Data, in view: UIImageView) {
            generation += 1
            let expected = generation
            let status = CGAnimateImageDataWithBlock(data as CFData, nil) { [weak self, weak view] _, frame, stop in
                guard let self, let view, self.generation == expected else {
                    stop.pointee = true
                    return
                }
                view.image = UIImage(cgImage: frame)
            }
            if status != noErr {
                view.image = UIImage(data: data)
            }
        }
    }
}
