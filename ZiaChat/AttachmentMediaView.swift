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

    func makeUIView(context: Context) -> WKWebView {
        makeWebView()
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
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
