import SwiftUI

/// Contenido del chip "WhatsApp" en el index de chats. Son filas de la misma
/// `List` de `ChannelListView`, por eso cada bloque es un `Section`/fila y no
/// una pantalla aparte. Espejo de `ChatPanel.tsx` de authcode-app.
struct WhatsAppInboxContent: View {
    @ObservedObject var store: WhatsAppStore
    let onOpen: (WhatsAppChat) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        sessionBannerRow
        searchRow
        filterRow
        listRows
    }

    // MARK: - Sesión de WAHA

    @ViewBuilder
    private var sessionBannerRow: some View {
        if let session = store.session, !session.isWorking {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: session.needsQR ? "qrcode" : "icloud.slash")
                    .font(.subheadline.weight(.semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.needsQR ? "WhatsApp espera un código QR" : "Sesión de WhatsApp: \(session.status ?? "desconocida")")
                        .font(.subheadline.weight(.semibold))
                    Text(session.needsQR
                         ? "Escanéalo desde el panel de WAHA para volver a recibir mensajes."
                         : "No se enviarán ni recibirán mensajes hasta que se reconecte.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(session.needsQR ? Color.orange.opacity(0.15) : Color.red.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(ZenitBrand.surface)
        }
    }

    // MARK: - Buscador y filtros

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Buscar chat de WhatsApp", text: $store.searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !store.searchText.isEmpty {
                Button {
                    store.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Limpiar búsqueda")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(ZenitBrand.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .listRowSeparator(.hidden)
        .listRowBackground(ZenitBrand.surface)
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(WhatsAppFilter.allCases) { filter in
                    let isSelected = store.filter == filter
                    Button {
                        withAnimation(reduceMotion ? nil : .snappy) { store.filter = filter }
                    } label: {
                        Text(filter.title)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(isSelected ? ZenitBrand.ink : ZenitBrand.surfaceMuted)
                            .foregroundStyle(isSelected ? ZenitBrand.cream : .primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(ZenitBrand.surface)
    }

    // MARK: - Lista

    @ViewBuilder
    private var listRows: some View {
        if let error = store.chatsError {
            ContentUnavailableView {
                Label("No se pudo cargar WhatsApp", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Reintentar") { store.retryChats() }
                    .buttonStyle(.borderedProminent)
                    .tint(ZenitBrand.accentFill)
            }
            .listRowSeparator(.hidden)
            .listRowBackground(ZenitBrand.surface)
        } else if !store.hasLoadedChats {
            HStack {
                Spacer()
                ProgressView("Cargando chats…")
                Spacer()
            }
            .padding(.top, 32)
            .listRowSeparator(.hidden)
            .listRowBackground(ZenitBrand.surface)
        } else if store.chats.isEmpty {
            ContentUnavailableView(
                "Sin conversaciones",
                systemImage: "bubble.left.and.bubble.right",
                description: Text(store.searchText.isEmpty ? "No hay chats en este filtro." : "Nada coincide con la búsqueda.")
            )
            .listRowSeparator(.hidden)
            .listRowBackground(ZenitBrand.surface)
        } else {
            Section {
                ForEach(store.chats) { chat in
                    Button {
                        onOpen(chat)
                    } label: {
                        WhatsAppChatRow(chat: chat)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(ZenitBrand.surface)
                    .onAppear {
                        if chat.id == store.chats.last?.id {
                            store.loadMoreChats()
                        }
                    }
                }
                if !store.chatsIsDone {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(ZenitBrand.surface)
                }
            }
        }
    }
}

struct WhatsAppChatRow: View {
    let chat: WhatsAppChat

    private var isUnread: Bool { chat.unreadCount > 0 && !chat.isMuted }

    private var previewText: String {
        let preview = chat.lastMessagePreview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !preview.isEmpty else { return "Sin mensajes" }
        return chat.lastMessageFromMe == true ? "Tú: \(preview)" : preview
    }

    var body: some View {
        HStack(spacing: 11) {
            WhatsAppAvatar(name: chat.nombreVisible, url: chat.pictureURL, isGroup: chat.isGroup, size: 44)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(chat.nombreVisible)
                        .font(.body.weight(isUnread ? .bold : .regular))
                        .lineLimit(1)
                    if chat.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Silenciado")
                    }
                    if chat.estado != .abierto {
                        Text(chat.estado.title)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(ZenitBrand.surfaceMuted)
                            .clipShape(Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(previewText)
                    .font(.subheadline)
                    .foregroundStyle(isUnread ? .primary : .secondary)
                    .lineLimit(1)
                if chat.unidadNegocio != nil || chat.clienteEtiqueta != nil {
                    HStack(spacing: 5) {
                        if let unit = chat.unidadNegocio {
                            Circle().fill(Color.green).frame(width: 7, height: 7)
                            Text(unit)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        if let company = chat.clienteEtiqueta {
                            Text(company)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(ZenitBrand.accentFill)
                                .clipShape(Capsule())
                                .lineLimit(1)
                        }
                    }
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 4) {
                Text(WhatsAppFormat.listTime(chat.lastMessageDate))
                    .font(.caption2)
                    .foregroundStyle(isUnread ? ZenitBrand.accent : .secondary)
                if chat.unreadCount > 0 {
                    CountBadge(text: CoreFormat.badgeCount(chat.unreadCount), color: chat.isMuted ? .gray : ZenitBrand.accentFill)
                } else if let agent = chat.agente {
                    Text(CoreFormat.initials(agent.name))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Asignado a \(agent.name)")
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(isUnread ? ZenitBrand.accentFill.opacity(0.10) : Color.clear)
        .overlay(alignment: .leading) {
            if isUnread {
                RoundedRectangle(cornerRadius: 2)
                    .fill(ZenitBrand.accentFill)
                    .frame(width: 4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isUnread ? "\(chat.unreadCount) sin leer" : "")
    }
}

/// Avatar de WhatsApp: foto del contacto o iniciales; los grupos sin foto
/// muestran el icono de grupo.
struct WhatsAppAvatar: View {
    let name: String
    let url: URL?
    var isGroup = false
    var size: CGFloat = 40

    var body: some View {
        RemoteImage(url: url, targetSize: CGSize(width: size, height: size)) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            fallback
        } failure: {
            fallback
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var fallback: some View {
        ZStack {
            Circle().fill(ZenitBrand.ink)
            if isGroup {
                Image(systemName: "person.2.fill")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(ZenitBrand.cream)
            } else {
                Text(CoreFormat.initials(name))
                    .font(.system(size: size * 0.34, weight: .bold))
                    .foregroundStyle(ZenitBrand.cream)
            }
        }
    }
}
