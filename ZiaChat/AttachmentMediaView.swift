import SwiftUI
import WebKit

struct AttachmentMediaView: View {
    let url: URL
    let isGIF: Bool

    var body: some View {
        if isGIF {
            AnimatedGIFView(url: url)
        } else {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    ContentUnavailableView("Image unavailable", systemImage: "photo")
                default:
                    ProgressView()
                }
            }
        }
    }
}

struct PendingAttachmentPreview: View {
    let attachment: CorePendingAttachment

    var body: some View {
        if attachment.isGIF {
            AnimatedGIFDataView(data: attachment.data)
        } else if let image = UIImage(data: attachment.data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: "photo")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.12))
        }
    }
}

private struct AnimatedGIFView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        makeWebView()
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.load(url: url, into: webView)
    }

    final class Coordinator {
        var loadedURL: URL?
        private var loadTask: Task<Void, Never>?

        func load(url: URL, into webView: WKWebView) {
            loadedURL = url
            loadTask?.cancel()
            loadTask = Task {
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    guard !Task.isCancelled, loadedURL == url else { return }
                    let mimeType = animatedImageMIMEType(
                        data: data,
                        responseMIMEType: response.mimeType
                    )
                    webView.load(
                        data,
                        mimeType: mimeType,
                        characterEncodingName: "utf-8",
                        baseURL: url.deletingLastPathComponent()
                    )
                } catch {
                    guard loadedURL == url else { return }
                    webView.loadHTMLString(
                        "<html><body style='background:transparent'></body></html>",
                        baseURL: nil
                    )
                }
            }
        }

        deinit {
            loadTask?.cancel()
        }
    }
}

private struct AnimatedGIFDataView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> WKWebView {
        makeWebView()
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.load(
            data,
            mimeType: "image/gif",
            characterEncodingName: "utf-8",
            baseURL: URL(fileURLWithPath: NSTemporaryDirectory())
        )
    }
}

private func makeWebView() -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.isOpaque = false
    webView.backgroundColor = .clear
    webView.scrollView.backgroundColor = .clear
    webView.scrollView.isScrollEnabled = false
    webView.scrollView.contentInsetAdjustmentBehavior = .never
    return webView
}

private func animatedImageMIMEType(data: Data, responseMIMEType: String?) -> String {
    let bytes = [UInt8](data.prefix(12))
    if bytes.count >= 6,
       String(bytes: bytes.prefix(6), encoding: .ascii)?.hasPrefix("GIF") == true {
        return "image/gif"
    }
    if bytes.count >= 12,
       String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
       String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP" {
        return "image/webp"
    }
    if bytes.count >= 8, bytes[0...7] == [137, 80, 78, 71, 13, 10, 26, 10] {
        return "image/png"
    }
    return responseMIMEType ?? "application/octet-stream"
}
