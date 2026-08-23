import SwiftUI

struct AttachmentMediaView: View {
    let url: URL
    let isGIF: Bool

    var body: some View {
        if isGIF {
            AnimatedImageView(url: url)
        } else {
            RemoteImage(url: url, targetSize: CGSize(width: 220, height: 180)) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                ProgressView()
            } failure: {
                ContentUnavailableView("Imagen no disponible", systemImage: "photo")
            }
        }
    }
}

struct PendingAttachmentPreview: View {
    let attachment: CorePendingAttachment

    @Environment(\.displayScale) private var displayScale
    @State private var thumb: UIImage?
    @State private var didDecode = false

    private nonisolated static let tileSize = CGSize(width: 74, height: 74)

    var body: some View {
        Group {
            if attachment.isFileBacked, let url = attachment.fileURL {
                if attachment.mimeType.hasPrefix("image/") {
                    // Los GIF muestran su primer fotograma: la miniatura del
                    // compositor no necesita animarse.
                    RemoteImage(url: url, targetSize: Self.tileSize) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        ProgressView()
                    }
                } else {
                    Image(systemName: attachment.mimeType.hasPrefix("video/") ? "video" : "doc")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.secondary.opacity(0.12))
                }
            } else if let thumb {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFill()
            } else if didDecode {
                Image(systemName: "photo")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.12))
            } else {
                ProgressView()
            }
        }
        .task(id: attachment.id) {
            guard !attachment.isFileBacked else { return }
            let data = attachment.data
            let scale = displayScale
            let decoded = await Task.detached(priority: .userInitiated) {
                RemoteImageLoader.downsampledImage(from: data, targetSize: Self.tileSize, scale: scale)
            }.value
            guard !Task.isCancelled else { return }
            thumb = decoded
            didDecode = true
        }
    }
}
