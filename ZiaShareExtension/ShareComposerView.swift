import Foundation
import SwiftUI
import UIKit

/// UI de la Share Extension: muestra lo compartido, deja elegir el canal de
/// Zia Chat y lo envía reutilizando SupabaseCoreClient (misma lógica que la app).
struct ShareComposerView: View {
    let extensionItems: [NSExtensionItem]
    var onFinish: () -> Void
    var onCancel: () -> Void

    private enum Phase: Equatable {
        case loading
        case needsLogin
        case ready
        case sending
        case sent
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var configuration = CoreAppConfiguration()
    @State private var channels: [CoreChannel] = []
    @State private var selectedChannelId: String?
    @State private var searchText = ""
    @State private var messageText = ""
    @State private var attachments: [CorePendingAttachment] = []
    @State private var oversizedNames: [String] = []
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Enviar a Zia")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancelar", action: onCancel)
                            .disabled(phase == .sending)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if phase == .sending {
                            ProgressView()
                        } else {
                            Button("Enviar") {
                                Task { await send() }
                            }
                            .fontWeight(.semibold)
                            .disabled(!canSend)
                        }
                    }
                }
        }
        .tint(ZenitBrand.accent)
        .task { await bootstrap() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Preparando contenido…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .needsLogin:
            statusView(
                symbol: "person.crop.circle.badge.exclamationmark",
                title: "Inicia sesión en Zia Chat",
                message: "Abre la app Zia Chat e inicia sesión para poder compartir contenido a tus canales."
            )

        case .failed(let message):
            statusView(
                symbol: "exclamationmark.triangle",
                title: "No se pudo cargar",
                message: message
            )

        case .sent:
            statusView(
                symbol: "checkmark.circle.fill",
                title: "Enviado",
                message: "Tu contenido se envió al canal.",
                tint: ZenitBrand.teal
            )

        case .ready, .sending:
            composer
        }
    }

    private var composer: some View {
        List {
            if !attachments.isEmpty || !oversizedNames.isEmpty {
                Section("Adjuntos") {
                    ForEach(attachments) { attachment in
                        HStack(spacing: 10) {
                            Image(systemName: symbolName(for: attachment))
                                .foregroundStyle(ZenitBrand.teal)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(attachment.fileName)
                                    .lineLimit(1)
                                Text(byteText(attachment.sizeBytes))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !oversizedNames.isEmpty {
                        Label(
                            "Se omitieron por tamaño: \(oversizedNames.joined(separator: ", "))",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
            }

            Section("Mensaje") {
                TextField("Escribe un mensaje…", text: $messageText, axis: .vertical)
                    .lineLimit(1...6)
            }

            Section("Enviar al canal") {
                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if filteredChannels.isEmpty {
                    Text(searchText.isEmpty ? "No hay canales disponibles." : "Sin resultados para “\(searchText)”.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredChannels) { channel in
                        Button {
                            selectedChannelId = channel.id
                        } label: {
                            HStack(spacing: 10) {
                                ShareChannelIcon(channel: channel, size: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(channel.displayName)
                                        .foregroundStyle(.primary)
                                    Text(channel.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if selectedChannelId == channel.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(ZenitBrand.teal)
                                }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Buscar canal")
        .disabled(phase == .sending)
    }

    private func statusView(
        symbol: String,
        title: String,
        message: String,
        tint: Color = .secondary
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 44))
                .foregroundStyle(tint)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Cerrar", action: onCancel)
                .buttonStyle(.bordered)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Datos

    private var filteredChannels: [CoreChannel] {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return channels }
        return channels.filter { $0.displayName.lowercased().contains(term) }
    }

    private var canSend: Bool {
        guard phase == .ready, selectedChannelId != nil else { return false }
        let hasText = !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || !attachments.isEmpty
    }

    private func bootstrap() async {
        let payload = await SharedItemLoader.load(from: extensionItems)
        messageText = payload.text
        attachments = payload.attachments
        oversizedNames = payload.oversizedFileNames

        var config = CoreConfigurationStore.load()
        guard config.isUsable else {
            phase = .needsLogin
            return
        }

        // Refresca el token si está por vencer (la extensión puede abrirse
        // mucho después del último uso de la app).
        if config.accessTokenExpires() {
            if let service = try? CoreAuthService(configuration: config),
               let refreshed = try? await service.refreshSession() {
                config = refreshed
                CoreConfigurationStore.save(config)
            }
        }
        configuration = config

        do {
            let client = try SupabaseCoreClient(configuration: config)
            // El RPC rápido (core_list_zia_channels) no trae metadata, así que
            // se perderían los iconos de canal. Usa el listado enriquecido y
            // cae al rápido solo si este falla.
            var loaded = (try? await client.listChannels()) ?? []
            if loaded.isEmpty {
                loaded = try await client.listChannelsFast()
            }
            channels = loaded
                .filter { !$0.isArchived && !$0.isVoice && $0.conversationId != nil }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func send() async {
        guard let channel = channels.first(where: { $0.id == selectedChannelId }),
              let conversationId = channel.conversationId else { return }

        phase = .sending
        errorText = nil
        do {
            let client = try SupabaseCoreClient(configuration: configuration)
            _ = try await client.sendMessage(
                empresaId: channel.empresaId,
                conversationId: conversationId,
                channelId: channel.id,
                parentMessageId: nil,
                content: messageText.trimmingCharacters(in: .whitespacesAndNewlines),
                attachments: attachments
            )
            phase = .sent
            try? await Task.sleep(for: .milliseconds(700))
            onFinish()
        } catch {
            phase = .ready
            errorText = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func symbolName(for attachment: CorePendingAttachment) -> String {
        if attachment.mimeType.hasPrefix("image/") { return "photo" }
        if attachment.mimeType.hasPrefix("video/") { return "video" }
        if attachment.mimeType.hasPrefix("audio/") { return "waveform" }
        if attachment.mimeType.contains("pdf") { return "doc.richtext" }
        return "paperclip"
    }

    private func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Icono de canal con la misma lógica que ChannelLogoView de la app:
/// soporta `metadata.iconImage` como data:URL base64 (subido desde la web)
/// o URL remota, con fallback al símbolo SF + tinte del canal.
private struct ShareChannelIcon: View {
    let channel: CoreChannel
    let size: CGFloat

    private enum IconSource {
        case data(UIImage)
        case remote(URL)

        init?(rawValue: String?) {
            guard let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return nil
            }

            if raw.hasPrefix("data:") {
                guard let commaIndex = raw.firstIndex(of: ","),
                      let imageData = Data(base64Encoded: String(raw[raw.index(after: commaIndex)...])),
                      let image = UIImage(data: imageData) else {
                    return nil
                }
                self = .data(image)
                return
            }

            guard let url = URL(string: raw), url.scheme != nil else { return nil }
            self = .remote(url)
        }
    }

    private var iconSource: IconSource? {
        IconSource(rawValue: channel.metadata?.iconImage)
    }

    var body: some View {
        Group {
            switch iconSource {
            case .data(let image)?:
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            case .remote(let url)?:
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        fallback
                    }
                }
            case nil:
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: min(10, size * 0.24), style: .continuous))
    }

    private var fallback: some View {
        ZStack {
            RoundedRectangle(cornerRadius: min(10, size * 0.24), style: .continuous)
                .fill(channel.tint.gradient)
            Image(systemName: channel.symbolName)
                .foregroundStyle(.white)
                .font(.system(size: max(13, size * 0.4), weight: .semibold))
        }
    }
}
