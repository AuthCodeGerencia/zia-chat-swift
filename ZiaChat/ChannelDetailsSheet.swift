import SwiftUI

/// Detalles del canal al tocar el título (miembros, anclados, silenciar,
/// configuración), como la cabecera de Slack.
struct ChannelDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CoreChannelsStore
    let channel: CoreChannel
    let onJumpToMessage: (String) -> Void

    @State private var showSettings = false

    private var conversationId: String { channel.conversationId ?? "" }
    private var members: [CoreUserLite] { store.members(for: channel) }
    private var pins: [CoreMessagePin] { store.messagePins[conversationId] ?? [] }
    private var isUnread: Bool { channel.unreadCount > 0 || channel.mentionCount > 0 }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        ChannelLogoView(channel: channel, size: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(channel.displayName)
                                .font(.title3.weight(.semibold))
                            Text(channel.subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    if let description = channel.description, !description.isEmpty, !channel.isDirectMessage {
                        Text(description)
                            .font(.subheadline)
                    }
                }

                Section("Notificaciones") {
                    Toggle(isOn: Binding(
                        get: { store.isMuted(channel.id) },
                        set: { _ in store.toggleMuted(channel.id) }
                    )) {
                        Label("Silenciar", systemImage: "bell.slash")
                    }
                    Toggle(isOn: Binding(
                        get: { store.favoriteChannelIds.contains(channel.id) },
                        set: { _ in store.toggleFavorite(channel.id) }
                    )) {
                        Label("Fijar en favoritos", systemImage: "pin")
                    }
                    if isUnread {
                        Button {
                            Task { await store.markChannelAsRead(channel) }
                        } label: {
                            Label("Marcar como leído", systemImage: "checkmark.circle")
                        }
                    }
                }

                Section(pins.isEmpty ? "Mensajes anclados" : "Mensajes anclados (\(pins.count))") {
                    if pins.isEmpty {
                        Text("Sin mensajes anclados")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(pins) { pin in
                            Button {
                                onJumpToMessage(pin.messageId)
                                dismiss()
                            } label: {
                                pinRow(pin)
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }

                Section(members.isEmpty ? "Miembros" : "Miembros (\(members.count))") {
                    if members.isEmpty {
                        Text("Todavía no se han cargado los miembros")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(members) { member in
                            HStack(spacing: 12) {
                                AvatarView(name: member.displayName, avatarURL: member.avatarURL, size: 34)
                                Text(member.displayName)
                                    .lineLimit(1)
                                if member.id == store.configuration.userId {
                                    Text("(tú)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if !channel.isDirectMessage {
                    Section {
                        Button {
                            showSettings = true
                        } label: {
                            Label("Configurar canal", systemImage: "gearshape")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ZenitBrand.cream)
            .navigationTitle("Detalles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
            .sheet(isPresented: $showSettings) {
                ChannelSettingsView(store: store, editing: channel)
            }
            .task(id: channel.id) {
                await store.loadMessagePins(for: channel)
            }
        }
    }

    private func pinRow(_ pin: CoreMessagePin) -> some View {
        let pinned = store.messages[conversationId]?.first(where: { $0.id == pin.messageId })
        return HStack(spacing: 10) {
            Image(systemName: "pin.fill")
                .foregroundStyle(ZenitBrand.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(pinned?.authorName ?? "Mensaje anclado")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(pinned?.content.isEmpty == false ? pinned?.content ?? "" : "Toca para ver el mensaje")
                    .font(.subheadline)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }
}
