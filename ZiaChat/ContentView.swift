import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = CoreChannelsStore()
    @StateObject private var voiceStore = CoreVoiceRoomStore()
    @StateObject private var pushService = PushNotificationService.shared
    @State private var showingSettings = false
    @State private var showingNewChannel = false
    @State private var navigationPath: [CoreChannel.ID] = []
    @State private var pushNavigationTask: Task<Void, Never>?
    @State private var foregroundRefreshTask: Task<Void, Never>?

    var body: some View {
        Group {
            if store.configuration.isUsable {
                NavigationStack(path: $navigationPath) {
                    ChannelListView(
                        store: store,
                        voiceStore: voiceStore,
                        showingSettings: $showingSettings,
                        showingNewChannel: $showingNewChannel,
                        navigationPath: $navigationPath
                    )
                    .navigationDestination(for: CoreChannel.ID.self) { channelId in
                        if let channel = store.channel(with: channelId) {
                            if channel.isVoice {
                                VoiceChannelView(
                                    store: store,
                                    voiceStore: voiceStore,
                                    channel: channel
                                )
                            } else {
                                ChatDetailView(
                                    store: store,
                                    voiceStore: voiceStore,
                                    channel: channel,
                                    navigationPath: $navigationPath
                                )
                            }
                        } else {
                            MissingChannelView()
                        }
                    }
                }
            } else {
                LoginView(store: store, showingSettings: $showingSettings)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(store: store)
        }
        .sheet(isPresented: $showingNewChannel) {
            ChannelSettingsView(store: store)
        }
        .onChange(of: store.configuration.isUsable) { _, isUsable in
            if !isUsable {
                navigationPath.removeAll()
                Task {
                    await voiceStore.leave()
                    await pushService.updateBadgeCount(0)
                }
            } else {
                Task {
                    await pushService.requestAuthorizationAndRegister()
                    await pushService.registerCurrentToken(configuration: store.configuration)
                    await syncAppBadge()
                    schedulePendingPushNavigation()
                }
            }
        }
        .onChange(of: pushService.deviceToken) { _, token in
            guard token != nil else { return }
            Task { await pushService.registerCurrentToken(configuration: store.configuration) }
        }
        .onChange(of: pushService.pendingDestination) { _, destination in
            guard destination != nil else { return }
            schedulePendingPushNavigation()
        }
        .onChange(of: pushService.foregroundEvent) { _, event in
            guard event != nil, scenePhase == .active else { return }
            foregroundRefreshTask?.cancel()
            foregroundRefreshTask = Task {
                guard store.configuration.isUsable, scenePhase == .active else { return }
                _ = try? await store.ensureFreshSession()
                guard !Task.isCancelled, scenePhase == .active else { return }
                await store.refresh()
                guard !Task.isCancelled, scenePhase == .active else { return }
                await syncAppBadge()
            }
        }
        .onChange(of: store.channels) { _, _ in
            schedulePendingPushNavigation()
            Task { await syncAppBadge() }
        }
        .onChange(of: store.directMessages) { _, _ in
            Task { await syncAppBadge() }
        }
        .onChange(of: store.configuration.accessToken) { _, _ in
            Task { await pushService.registerCurrentToken(configuration: store.configuration) }
        }
        .onChange(of: scenePhase) { _, phase in
            store.setSceneActive(phase == .active)
            if phase != .active {
                foregroundRefreshTask?.cancel()
                foregroundRefreshTask = nil
            }
            guard phase == .active else { return }
            Task {
                guard store.configuration.isUsable else {
                    await pushService.updateBadgeCount(0)
                    return
                }
                _ = try? await store.ensureFreshSession()
                await store.refresh()
                await store.reconnectRealtimeIfNeeded()
                await syncAppBadge()
                schedulePendingPushNavigation()
            }
        }
        .task {
            guard store.configuration.isUsable else {
                await pushService.updateBadgeCount(0)
                return
            }
            _ = try? await store.ensureFreshSession()
            await store.refresh()
            await pushService.requestAuthorizationAndRegister()
            await pushService.registerCurrentToken(configuration: store.configuration)
            await syncAppBadge()
            schedulePendingPushNavigation()
        }
        .preferredColorScheme(.light)
    }

    private func syncAppBadge() async {
        let unreadCount = store.textChannels.reduce(0) { $0 + $1.unreadCount }
            + store.directMessages.reduce(0) { $0 + $1.unreadCount }
        await pushService.updateBadgeCount(unreadCount)
    }

    private func schedulePendingPushNavigation() {
        guard scenePhase == .active,
              pushService.pendingDestination != nil,
              pushNavigationTask == nil else {
            return
        }
        pushNavigationTask = Task {
            // Let SwiftUI finish restoring the NavigationStack after a notification launch.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, scenePhase == .active else {
                pushNavigationTask = nil
                return
            }
            await openPendingPushDestination()
            pushNavigationTask = nil
        }
    }

    private func openPendingPushDestination() async {
        guard let destination = pushService.pendingDestination,
              store.configuration.isUsable else {
            return
        }

        var latestError: Error?
        for attempt in 0..<3 {
            guard !Task.isCancelled,
                  pushService.pendingDestination == destination else {
                return
            }

            do {
                if let channel = try await store.channelForNotification(
                    channelId: destination.channelId,
                    conversationId: destination.conversationId
                ) {
                    store.selectedChannelId = channel.id
                    navigationPath = [channel.id]
                    pushService.consume(destination)
                    pushService.lastError = nil
                    return
                }
            } catch {
                latestError = error
            }

            if attempt < 2 {
                try? await Task.sleep(for: .milliseconds(450 * (attempt + 1)))
            }
        }

        pushService.lastError = latestError?.localizedDescription
            ?? "The chat from this notification is not available for this account."
    }
}

private struct LoginView: View {
    @ObservedObject var store: CoreChannelsStore
    @Binding var showingSettings: Bool
    @State private var email = ""
    @State private var password = ""
    @FocusState private var focusedField: LoginField?

    private enum LoginField {
        case email
        case password
    }

    private var canLogin: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !password.isEmpty &&
        !store.isLoggingIn
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(zenitHex: 0x071A24),
                        Color(zenitHex: 0x0B5362),
                        Color(zenitHex: 0x13B7AA)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 280, height: 280)
                    .offset(x: 150, y: -250)

                Circle()
                    .fill(ZenitBrand.khaki.opacity(0.18))
                    .frame(width: 220, height: 220)
                    .offset(x: -150, y: 310)

                ScrollView {
                    VStack(spacing: 24) {
                        VStack(spacing: 14) {
                            ZiaLoginLogo()

                            Text("Zia Chat")
                                .font(ZenitFont.font(size: 34, weight: .bold))
                                .foregroundStyle(.white)

                            Text("Tu equipo, tus conversaciones y todo lo importante en un solo lugar.")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.78))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 310)
                        }

                        VStack(alignment: .leading, spacing: 18) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Bienvenido")
                                    .font(ZenitFont.font(size: 24, weight: .bold))
                                    .foregroundStyle(ZenitBrand.ink)
                                Text("Ingresa con tu cuenta de Azank")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            loginField(title: "Correo electrónico", systemImage: "envelope.fill") {
                                TextField("nombre@empresa.com", text: $email)
                                    .textInputAutocapitalization(.never)
                                    .keyboardType(.emailAddress)
                                    .textContentType(.username)
                                    .submitLabel(.next)
                                    .focused($focusedField, equals: .email)
                                    .onSubmit { focusedField = .password }
                            }

                            loginField(title: "Contraseña", systemImage: "lock.fill") {
                                SecureField("Tu contraseña", text: $password)
                                    .textContentType(.password)
                                    .submitLabel(.go)
                                    .focused($focusedField, equals: .password)
                                    .onSubmit { signIn() }
                            }

                            Button(action: signIn) {
                                HStack(spacing: 10) {
                                    if store.isLoggingIn {
                                        ProgressView()
                                            .tint(.white)
                                    }
                                    Text(store.isLoggingIn ? "Ingresando..." : "Entrar a Zia")
                                        .font(.headline)
                                    if !store.isLoggingIn {
                                        Image(systemName: "arrow.right")
                                            .font(.subheadline.weight(.bold))
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white)
                            .background(canLogin ? ZenitBrand.accent : Color.gray.opacity(0.45))
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                            .disabled(!canLogin)

                            if let error = store.lastError {
                                Label(error, systemImage: "exclamationmark.circle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(Color.red.opacity(0.85))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            Text("Usa las mismas credenciales con las que accedes a Azank.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .padding(24)
                        .background(Color.white.opacity(0.97))
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .shadow(color: Color.black.opacity(0.18), radius: 24, y: 14)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 34)
                    .padding(.bottom, 30)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .frame(width: 38, height: 38)
                            .background(Color.white.opacity(0.14))
                            .clipShape(Circle())
                    }
                    .foregroundStyle(.white)
                    .accessibilityLabel("Configuración")
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    private func signIn() {
        guard canLogin else { return }
        focusedField = nil
        Task { await store.login(email: email, password: password) }
    }

    private func loginField<Field: View>(
        title: String,
        systemImage: String,
        @ViewBuilder field: () -> Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ZenitBrand.olive)

            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(ZenitBrand.accent)
                    .frame(width: 20)
                field()
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(Color(zenitHex: 0xF2F6F6))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.black.opacity(0.07), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct ZiaLoginLogo: View {
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .fill(Color.white.opacity(0.94))
                .frame(width: 108, height: 94)

            Text("Z")
                .font(.system(size: 58, weight: .black, design: .rounded))
                .foregroundStyle(Color(zenitHex: 0x07364B))
                .frame(width: 108, height: 94)

            LoginLogoTail()
                .fill(Color.white.opacity(0.94))
                .frame(width: 28, height: 24)
                .rotationEffect(.degrees(-18))
                .offset(x: 12, y: 11)
        }
        .padding(13)
        .background(
            LinearGradient(
                colors: [Color(zenitHex: 0x16A8E0), Color(zenitHex: 0x1BD6A8)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .stroke(Color.white.opacity(0.24), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.22), radius: 18, y: 10)
    }
}

private struct LoginLogoTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Filtros del index de canales (chips estilo WhatsApp).
enum ChannelListFilter: CaseIterable {
    case todos
    case directos
    case hilos
    case favoritos
    case noLeidos
    case voz

    var title: String {
        switch self {
        case .todos: return "Todos"
        case .directos: return "Directos"
        case .hilos: return "Hilos"
        case .favoritos: return "Favoritos"
        case .noLeidos: return "No leídos"
        case .voz: return "Voz"
        }
    }

    var systemImage: String? {
        switch self {
        case .todos: return nil
        case .directos: return "person.2.fill"
        case .hilos: return "bubble.left.and.bubble.right.fill"
        case .favoritos: return "star.fill"
        case .noLeidos: return "circle.badge.fill"
        case .voz: return "speaker.wave.2.fill"
        }
    }
}

private enum ChannelListItem: Identifiable {
    case channel(CoreChannel)
    case direct(CoreDirectMessage)

    var id: String {
        switch self {
        case let .channel(channel): channel.id
        case let .direct(message): message.id
        }
    }
}

/// Un thread mostrado en el filtro "Hilos" del index, junto con su canal.
struct ChannelThreadItem: Identifiable {
    let channel: CoreChannel
    let summary: CoreThreadSummary

    var id: String { summary.id }
}

private struct ChannelListView: View {
    @ObservedObject var store: CoreChannelsStore
    @ObservedObject var voiceStore: CoreVoiceRoomStore
    @Binding var showingSettings: Bool
    @Binding var showingNewChannel: Bool
    @Binding var navigationPath: [CoreChannel.ID]
    @State private var searchText = ""
    @State private var channelToEdit: CoreChannel?
    @State private var channelFilter: ChannelListFilter = .todos
    @State private var showNewDM = false
    @State private var selectedThreadItem: ChannelThreadItem?
    @ObservedObject private var threadReads = ThreadReadTracker.shared

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        List {
            if !store.configuration.isUsable {
                ConfigurationBanner {
                    showingSettings = true
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            if isSearching {
                channelSearchContent
            } else {
                filterChipsRow
                defaultChannelContent
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.white)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .listSectionSpacing(0)
        .overlay {
            if store.isLoading && store.channels.isEmpty && store.directMessages.isEmpty {
                ProgressView("Loading channels")
            } else if store.channels.isEmpty && store.directMessages.isEmpty && store.configuration.isUsable {
                ContentUnavailableView(
                    "No hay chats",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Crea un canal o inicia un mensaje directo.")
                )
            }
        }
        .refreshable {
            await store.refresh()
            if channelFilter == .hilos {
                await store.loadAllChannelThreads(force: true)
            }
        }
        .task(id: store.textChannels.count) {
            // Precarga los threads para que el chip "Hilos" muestre su badge
            // de nuevos mensajes sin tener que entrar al filtro.
            guard !store.textChannels.isEmpty else { return }
            await store.loadAllChannelThreads()
        }
        .sheet(item: $selectedThreadItem) { item in
            ThreadView(store: store, channel: item.channel, root: item.summary.root)
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Buscar palabras clave en canales"
        )
        .onChange(of: searchText) { _, newValue in
            store.updateChannelSearch(newValue)
        }
        .sheet(item: $channelToEdit) { channel in
            ChannelSettingsView(store: store, editing: channel)
        }
        .sheet(isPresented: $showNewDM) {
            NewDirectMessageView(store: store) { channel in
                showNewDM = false
                store.selectedChannelId = channel.id
                navigationPath = [channel.id]
            }
        }
        .navigationTitle("ZiaChat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.white, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNewChannel = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .disabled(!store.configuration.isUsable)
                .accessibilityLabel("New channel")
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if let channel = voiceStore.connectedChannel {
                    ConnectedVoiceBar(
                        voiceStore: voiceStore,
                        channel: channel,
                        onOpen: {
                            store.selectedChannelId = channel.id
                            navigationPath = [channel.id]
                        }
                    )
                }

                ChannelBottomBar(
                    onSettings: { showingSettings = true },
                    onSignOut: {
                        let configuration = store.configuration
                        Task {
                            await PushNotificationService.shared.unregisterCurrentUser(
                                configuration: configuration
                            )
                            store.signOut()
                        }
                    }
                )
            }
        }
    }

    private var filterChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ChannelListFilter.allCases, id: \.self) { filter in
                    filterChip(filter)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.white)
    }

    private func filterChip(_ filter: ChannelListFilter) -> some View {
        let isSelected = channelFilter == filter
        let chipBackground: Color = isSelected ? ZenitBrand.accent : Color(.systemGray6)
        let chipForeground: Color = isSelected ? .white : .primary
        return Button {
            withAnimation(.snappy) { channelFilter = filter }
            if filter == .hilos {
                Task { await store.loadAllChannelThreads() }
            }
        } label: {
            HStack(spacing: 4) {
                if let icon = filter.systemImage {
                    Image(systemName: icon)
                        .font(.caption2)
                }
                Text(filter.title)
                    .font(.caption.weight(.semibold))
                if filter == .noLeidos, totalUnreadCount > 0 {
                    Text(CoreFormat.badgeCount(totalUnreadCount))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isSelected ? ZenitBrand.accent : Color.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(isSelected ? Color.white : ZenitBrand.accent)
                        .clipShape(Capsule())
                }
                if filter == .hilos, unreadThreadItems.count > 0 {
                    Text(CoreFormat.badgeCount(unreadThreadItems.count))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isSelected ? ZenitBrand.accent : Color.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(isSelected ? Color.white : ZenitBrand.accent)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(chipBackground)
            .foregroundStyle(chipForeground)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var totalUnreadCount: Int {
        store.textChannels.reduce(0) { $0 + $1.unreadCount }
            + store.directMessages.reduce(0) { $0 + $1.unreadCount }
    }

    private var favoriteItems: [ChannelListItem] {
        sortedItems(
            store.channels
                .filter { store.favoriteChannelIds.contains($0.id) }
                .map(ChannelListItem.channel)
        )
    }

    @ViewBuilder
    private var defaultChannelContent: some View {
        switch channelFilter {
        case .todos:
            allChannelsContent
        case .directos:
            directMessagesContent
        case .hilos:
            threadsContent
        case .favoritos:
            favoritesContent
        case .noLeidos:
            unreadContent
        case .voz:
            voiceContent
        }
    }

    // MARK: - Filtro Hilos

    /// Todos los threads de los canales de texto, ordenados por actividad.
    private var allThreadItems: [ChannelThreadItem] {
        store.textChannels
            .flatMap { channel -> [ChannelThreadItem] in
                guard let conversationId = channel.conversationId else { return [] }
                return (store.channelThreads[conversationId] ?? []).map {
                    ChannelThreadItem(channel: channel, summary: $0)
                }
            }
            .sorted { $0.summary.lastReplyAt > $1.summary.lastReplyAt }
    }

    /// Threads con respuestas nuevas (de otros) desde la última vez que se abrieron.
    private var unreadThreadItems: [ChannelThreadItem] {
        allThreadItems.filter {
            threadReads.isUnread($0.summary, currentUserId: store.configuration.userId)
        }
    }

    private var readThreadItems: [ChannelThreadItem] {
        allThreadItems.filter {
            !threadReads.isUnread($0.summary, currentUserId: store.configuration.userId)
        }
    }

    @ViewBuilder
    private var threadsContent: some View {
        if store.isLoadingAllThreads && allThreadItems.isEmpty {
            HStack {
                Spacer()
                ProgressView("Cargando hilos…")
                Spacer()
            }
            .padding(.top, 32)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.white)
        } else if allThreadItems.isEmpty {
            ContentUnavailableView(
                "Sin hilos",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Todavía no hay conversaciones en threads en tus canales.")
            )
            .listRowSeparator(.hidden)
        } else {
            if !unreadThreadItems.isEmpty {
                Section {
                    ForEach(unreadThreadItems) { item in
                        indexThreadRow(item, isUnread: true)
                    }
                } header: {
                    Label("Nuevos mensajes", systemImage: "circle.badge.fill")
                }
            }

            if !readThreadItems.isEmpty {
                Section {
                    ForEach(readThreadItems) { item in
                        indexThreadRow(item, isUnread: false)
                    }
                } header: {
                    if !unreadThreadItems.isEmpty {
                        Label("Todos", systemImage: "bubble.left.and.bubble.right")
                    }
                }
            }
        }
    }

    private func indexThreadRow(_ item: ChannelThreadItem, isUnread: Bool) -> some View {
        IndexThreadRow(item: item, isUnread: isUnread)
            .contentShape(Rectangle())
            .onTapGesture { selectedThreadItem = item }
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            .listRowBackground(Color.white)
    }

    @ViewBuilder
    private var directMessagesContent: some View {
        Section {
            Button {
                showNewDM = true
            } label: {
                Label("Nuevo mensaje directo", systemImage: "square.and.pencil")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ZenitBrand.accent)
            }
            .listRowBackground(Color.white)
        }

        if store.directMessages.isEmpty {
            ContentUnavailableView(
                "Sin mensajes directos",
                systemImage: "person.2",
                description: Text("Inicia una conversación 1:1 con alguien de tu empresa.")
            )
            .listRowSeparator(.hidden)
        } else {
            Section {
                ForEach(sortedDirectMessages) { dm in
                    DirectMessageRow(dm: dm, currentUserId: store.configuration.userId)
                        .contentShape(Rectangle())
                        .onTapGesture { openDM(dm) }
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        .listRowBackground(Color.white)
                }
            }
        }
    }

    private func openDM(_ dm: CoreDirectMessage) {
        store.selectedChannelId = dm.id
        navigationPath = [dm.id]
    }

    @ViewBuilder
    private var allChannelsContent: some View {
        Section {
            ForEach(allChatItems) { item in
                chatRow(item)
            }
        }
    }

    @ViewBuilder
    private var favoritesContent: some View {
        if favoriteItems.isEmpty {
            ContentUnavailableView(
                "Sin favoritos",
                systemImage: "star",
                description: Text("Mantén presionado un canal (o deslízalo a la derecha) y elige Fijar para verlo aquí.")
            )
            .listRowSeparator(.hidden)
        } else {
            Section {
                ForEach(favoriteItems) { item in
                    chatRow(item)
                }
            }
        }
    }

    @ViewBuilder
    private var unreadContent: some View {
        if unreadItems.isEmpty {
            ContentUnavailableView(
                "Todo leído",
                systemImage: "checkmark.circle",
                description: Text("No tienes mensajes pendientes.")
            )
            .listRowSeparator(.hidden)
        } else {
            Section {
                ForEach(unreadItems) { item in
                    chatRow(item)
                }
            }
        }
    }

    @ViewBuilder
    private var voiceContent: some View {
        if store.voiceChannels.isEmpty {
            ContentUnavailableView(
                "Sin canales de voz",
                systemImage: "speaker.wave.2",
                description: Text("Crea un canal de voz desde el botón de nuevo canal.")
            )
            .listRowSeparator(.hidden)
        } else {
            Section {
                ForEach(store.voiceChannels) { channel in
                    ChannelNavigationRow(store: store, channel: channel, navigationPath: $navigationPath, onEdit: { channelToEdit = $0 })
                }
            }
        }
    }

    private var allChatItems: [ChannelListItem] {
        sortedItems(
            store.channels.map(ChannelListItem.channel)
                + store.directMessages.map(ChannelListItem.direct)
        )
    }

    private var sortedDirectMessages: [CoreDirectMessage] {
        store.directMessages.sorted {
            if $0.lastMessageAt != $1.lastMessageAt {
                return ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast)
            }
            return $0.peer.displayName.localizedCaseInsensitiveCompare($1.peer.displayName) == .orderedAscending
        }
    }

    private var unreadItems: [ChannelListItem] {
        allChatItems.filter { item in
            switch item {
            case let .channel(channel):
                channel.unreadCount > 0 || channel.mentionCount > 0
            case let .direct(message):
                message.unreadCount > 0 || message.mentionCount > 0
            }
        }
    }

    private func sortedItems(_ items: [ChannelListItem]) -> [ChannelListItem] {
        items.sorted { first, second in
            let firstDate = lastMessageDate(for: first)
            let secondDate = lastMessageDate(for: second)
            if firstDate != secondDate {
                return (firstDate ?? .distantPast) > (secondDate ?? .distantPast)
            }
            return displayName(for: first).localizedCaseInsensitiveCompare(displayName(for: second)) == .orderedAscending
        }
    }

    private func lastMessageDate(for item: ChannelListItem) -> Date? {
        switch item {
        case let .channel(channel):
            return channel.conversationId.flatMap { store.channelPreviews[$0]?.createdAt }
                ?? channel.updatedAt
                ?? channel.createdAt
        case let .direct(message):
            return message.lastMessageAt
        }
    }

    private func displayName(for item: ChannelListItem) -> String {
        switch item {
        case let .channel(channel): channel.displayName
        case let .direct(message): message.peer.displayName
        }
    }

    @ViewBuilder
    private func chatRow(_ item: ChannelListItem) -> some View {
        switch item {
        case let .channel(channel):
            ChannelNavigationRow(
                store: store,
                channel: channel,
                navigationPath: $navigationPath,
                onEdit: { channelToEdit = $0 }
            )
        case let .direct(message):
            DirectMessageRow(dm: message, currentUserId: store.configuration.userId)
                .contentShape(Rectangle())
                .onTapGesture { openDM(message) }
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                .listRowBackground(Color.white)
        }
    }

    @ViewBuilder
    private var channelSearchContent: some View {
        if store.isSearchingChannels {
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Buscando incidencias…")
                        .foregroundStyle(.secondary)
                }
            }
        } else if store.channelSearchResults.isEmpty {
            Section {
                ContentUnavailableView(
                    "Sin resultados",
                    systemImage: "magnifyingglass",
                    description: Text("No hay incidencias de \"\(searchText)\" en tus canales.")
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        } else {
            Section {
                ForEach(store.channelSearchResults) { hit in
                    ChannelSearchResultRow(hit: hit) {
                        store.selectedChannelId = hit.channel.id
                        navigationPath = [hit.channel.id]
                        searchText = ""
                        store.clearChannelSearch()
                    }
                }
            } header: {
                Label("\(store.channelSearchResults.count) canales con incidencias", systemImage: "text.magnifyingglass")
            }
        }
    }
}

private struct ChannelBottomBar: View {
    let onSettings: () -> Void
    let onSignOut: () -> Void

    var body: some View {
        HStack {
            VStack(spacing: 3) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 20, weight: .semibold))
                Text("Chats")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity)

            Menu {
                Button(action: onSettings) {
                    Label("Settings", systemImage: "gearshape")
                }
                Button(role: .destructive, action: onSignOut) {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 21, weight: .semibold))
                    Text("Perfil")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 49)
        .padding(.horizontal, 28)
        .background(Color.white)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

private struct DirectMessageRow: View {
    let dm: CoreDirectMessage
    let currentUserId: String

    private var previewText: String {
        guard let content = dm.lastMessageContent, !content.isEmpty else {
            return "Inicia la conversación"
        }
        let firstName = dm.peer.displayName.split(whereSeparator: \.isWhitespace).first.map(String.init)
            ?? dm.peer.displayName
        let prefix = dm.lastMessageUserId == currentUserId ? "Tú: " : "\(firstName): "
        return prefix + content
    }

    var body: some View {
        HStack(spacing: 11) {
            AvatarView(name: dm.peer.displayName, avatarURL: dm.peer.avatarURL, size: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(dm.peer.displayName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(previewText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 4) {
                if let lastAt = dm.lastMessageAt {
                    Text(CoreFormat.conversationTime(lastAt))
                        .font(.caption2)
                        .foregroundStyle(dm.unreadCount > 0 ? ZenitBrand.accent : .secondary)
                }
                if dm.unreadCount > 0 {
                    CountBadge(
                        text: CoreFormat.badgeCount(dm.unreadCount),
                        color: dm.mentionCount > 0 ? .red : ZenitBrand.accent
                    )
                }
            }
        }
        .accessibilityAddTraits(.isButton)
    }
}

private struct NewDirectMessageView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CoreChannelsStore
    let onOpen: (CoreChannel) -> Void

    @State private var search = ""
    @State private var startingUserId: String?

    private var people: [CoreUserLite] {
        let candidates = store.mentionableUsers.filter { $0.id != store.configuration.userId }
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return candidates }
        return candidates.filter { $0.displayName.lowercased().contains(trimmed) }
    }

    var body: some View {
        NavigationStack {
            List(people) { person in
                Button {
                    startDM(with: person)
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(name: person.displayName, avatarURL: person.avatarURL)
                        Text(person.displayName)
                            .foregroundStyle(.primary)
                        Spacer()
                        if startingUserId == person.id {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(startingUserId != nil)
            }
            .searchable(text: $search, prompt: "Buscar personas")
            .navigationTitle("Nuevo mensaje directo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .task {
                await store.loadMentionableUsersIfNeeded()
            }
            .overlay {
                if store.mentionableUsers.isEmpty {
                    ContentUnavailableView(
                        "Sin personas",
                        systemImage: "person.2",
                        description: Text("No se pudieron cargar los usuarios de la empresa.")
                    )
                }
            }
        }
    }

    private func startDM(with person: CoreUserLite) {
        startingUserId = person.id
        Task {
            if let channel = await store.startDirectMessage(with: person) {
                onOpen(channel)
            }
            startingUserId = nil
        }
    }
}

private struct ChannelSearchResultRow: View {
    let hit: CoreChannelSearchHit
    let onOpen: () -> Void

    private var incidenceLabel: String {
        hit.incidenceCount == 1 ? "1 incidencia" : "\(hit.incidenceCount) incidencias"
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                ChannelLogoView(channel: hit.channel, size: 42)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(hit.channel.displayName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if hit.channel.visibility == .private {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let preview = hit.previewSnippet, !preview.isEmpty {
                        Text(preview)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                Text(incidenceLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

private struct ChannelNavigationRow: View {
    @ObservedObject var store: CoreChannelsStore
    let channel: CoreChannel
    @Binding var navigationPath: [CoreChannel.ID]
    var onEdit: ((CoreChannel) -> Void)? = nil

    var body: some View {
        ChannelRowView(
            channel: channel,
            preview: channel.conversationId.flatMap { store.channelPreviews[$0] },
            currentUserId: store.configuration.userId,
            isFavorite: store.favoriteChannelIds.contains(channel.id),
            isMuted: store.isMuted(channel.id)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedChannelId = channel.id
            navigationPath = [channel.id]
        }
        .accessibilityAddTraits(.isButton)
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .listRowBackground(Color.white)
        .contextMenu {
            if let onEdit {
                Button {
                    onEdit(channel)
                } label: {
                    Label("Configurar canal", systemImage: "gearshape")
                }
            }
            Button {
                store.toggleFavorite(channel.id)
            } label: {
                Label(
                    store.favoriteChannelIds.contains(channel.id) ? "Quitar pin" : "Fijar",
                    systemImage: store.favoriteChannelIds.contains(channel.id) ? "pin.slash.fill" : "pin.fill"
                )
            }
            if channel.unreadCount > 0 || channel.mentionCount > 0 {
                Button {
                    Task { await store.markChannelAsRead(channel) }
                } label: {
                    Label("Marcar como leído", systemImage: "checkmark.circle")
                }
            }
            Button {
                store.toggleMuted(channel.id)
            } label: {
                Label(
                    store.isMuted(channel.id) ? "Activar notificaciones" : "Silenciar",
                    systemImage: store.isMuted(channel.id) ? "bell" : "bell.slash"
                )
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                store.toggleFavorite(channel.id)
            } label: {
                Label(
                    store.favoriteChannelIds.contains(channel.id) ? "Unpin" : "Pin",
                    systemImage: store.favoriteChannelIds.contains(channel.id) ? "pin.slash.fill" : "pin.fill"
                )
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let onEdit {
                Button {
                    onEdit(channel)
                } label: {
                    Label("Configurar", systemImage: "gearshape.fill")
                }
                .tint(ZenitBrand.olive)
            }
        }
    }
}

private struct ChannelRowView: View {
    let channel: CoreChannel
    let preview: CoreMessage?
    let currentUserId: String
    let isFavorite: Bool
    var isMuted: Bool = false

    var body: some View {
        HStack(spacing: 11) {
            ChannelLogoView(channel: channel, size: 40)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(channel.displayName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)

                    if channel.visibility == .private {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Silenciado")
                    }
                }

                ChannelPreviewText(
                    preview: preview,
                    fallback: channel.subtitle,
                    currentUserId: currentUserId
                )
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 4) {
                if let preview {
                    Text(CoreFormat.conversationTime(preview.createdAt))
                        .font(.caption2)
                        .foregroundStyle(channel.unreadCount > 0 ? Color.green : .secondary)
                }

                HStack(spacing: 6) {
                    if isFavorite {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Pinned")
                    }

                    if channel.mentionCount > 0 {
                        CountBadge(text: "@\(CoreFormat.badgeCount(channel.mentionCount))", color: .red)
                    } else if channel.unreadCount > 0 {
                        CountBadge(text: CoreFormat.badgeCount(channel.unreadCount), color: .green)
                    }
                }

                if channel.visibleAsSuperAdmin {
                    Text("admin")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

private struct ChannelPreviewText: View {
    let preview: CoreMessage?
    let fallback: String
    let currentUserId: String

    private var authorPrefix: String {
        guard let preview else { return "" }
        if preview.userId == currentUserId {
            return "Tú: "
        }
        let displayName = preview.author?.displayName ?? "Usuario"
        let name = displayName.split(whereSeparator: \.isWhitespace).first.map(String.init)
            ?? displayName
        return "\(name): "
    }

    var body: some View {
        if let preview {
            HStack(spacing: 5) {
                Text(authorPrefix)
                    .fontWeight(.semibold)
                if preview.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let attachment = preview.attachments?.first {
                    Image(systemName: attachment.isGIF ? "sparkles.rectangle.stack" : attachment.systemImage)
                        .font(.caption)
                    Text(attachment.isGIF ? "GIF" : attachment.isImage ? "Photo" : attachment.fileName)
                } else {
                    Text(
                        preview.metadata?.isCommandCard == true
                            ? "/\(preview.metadata?.command ?? "comando")"
                            : preview.content
                    )
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else {
            Text(fallback)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct ChatDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CoreChannelsStore
    @ObservedObject var voiceStore: CoreVoiceRoomStore
    let channel: CoreChannel
    @Binding var navigationPath: [CoreChannel.ID]
    @State private var showVoicePanel = false
    @State private var draft = ""
    @State private var replyTarget: CoreMessage?
    @State private var editTarget: CoreMessage?
    @StateObject private var typingService = CoreTypingService()
    @State private var showChannelSearch = false
    @State private var channelSearchText = ""
    @State private var channelSearchHits: [CoreMessage] = []
    @State private var isSearchingInChannel = false
    @State private var didSearchInChannel = false
    @State private var highlightedMessageId: String?
    @State private var pendingJumpId: String?
    @State private var pendingAttachments: [CorePendingAttachment] = []
    @State private var selectedMessage: CoreMessage?
    @State private var threadRoot: CoreMessage?
    @State private var messageToForward: CoreMessage?
    @State private var messageInfoTarget: CoreMessage?
    @State private var showThreadsOverview = false
    @ObservedObject private var threadReads = ThreadReadTracker.shared
    @FocusState private var isComposerFocused: Bool
    private let bottomID = "chat-bottom-anchor"

    var messages: [CoreMessage] {
        store.messages[channel.conversationId ?? ""] ?? []
    }

    private var threadSummaries: [CoreThreadSummary] {
        store.channelThreads[channel.conversationId ?? ""] ?? []
    }

    private var unreadThreadCount: Int {
        threadSummaries.filter {
            threadReads.isUnread($0, currentUserId: store.configuration.userId)
        }.count
    }

    private func hasUnreadThread(_ messageId: String) -> Bool {
        guard let summary = threadSummaries.first(where: { $0.id == messageId }) else { return false }
        return threadReads.isUnread(summary, currentUserId: store.configuration.userId)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            if let latestPin {
                pinnedMessageBar(latestPin)
            }

            if showChannelSearch {
                channelSearchBar
            }

            if showVoicePanel {
                voicePanel
            }

            if unreadThreadCount > 0 {
                unreadThreadsBanner
            }

            if channel.conversationId == nil {
                missingConversationView
            } else {
                messagesArea
            }

            typingIndicatorBar
            composer
        }
        .toolbar(.hidden, for: .navigationBar)
        // La barra de navegación oculta desactiva el swipe-back nativo;
        // este helper lo vuelve a habilitar.
        .background(InteractivePopGestureEnabler())
        .background(ZenitBrand.cream)
        .overlay {
            if let selectedMessage {
                MessageActionOverlay(
                    message: selectedMessage,
                    isMine: selectedMessage.userId == store.configuration.userId,
                    isPinned: store.isPinned(selectedMessage),
                    onDismiss: { self.selectedMessage = nil },
                    onReply: {
                        replyTarget = selectedMessage
                        isComposerFocused = true
                        self.selectedMessage = nil
                    },
                    onEdit: {
                        editTarget = selectedMessage
                        replyTarget = nil
                        draft = selectedMessage.content
                        isComposerFocused = true
                        self.selectedMessage = nil
                    },
                    onDelete: {
                        let target = selectedMessage
                        self.selectedMessage = nil
                        Task { await store.deleteMessage(target) }
                    },
                    onForward: {
                        messageToForward = selectedMessage
                        self.selectedMessage = nil
                    },
                    onCopy: {
                        UIPasteboard.general.string = selectedMessage.content
                        self.selectedMessage = nil
                    },
                    onThread: {
                        threadRoot = selectedMessage
                        self.selectedMessage = nil
                    },
                    onTogglePin: {
                        let target = selectedMessage
                        self.selectedMessage = nil
                        Task { await store.togglePin(target) }
                    },
                    onInfo: {
                        messageInfoTarget = selectedMessage
                        self.selectedMessage = nil
                    },
                    onSaveSticker: selectedMessage.stickerReferences.isEmpty &&
                        selectedMessage.attachments?.first(where: { $0.isImage }) == nil ? nil : {
                        let sticker = selectedMessage.stickerReferences.first
                        let attachment = selectedMessage.attachments?.first(where: { $0.isImage })
                        self.selectedMessage = nil
                        if let sticker {
                            Task { _ = await store.saveSticker(name: sticker.name, from: sticker.url) }
                        } else if let attachment {
                            Task { _ = await store.saveStickerFromAttachment(attachment) }
                        }
                    },
                    onReact: { emoji in
                        self.selectedMessage = nil
                        Task { await store.react(to: selectedMessage, emoji: emoji) }
                    }
                )
                .transition(.opacity)
                .zIndex(20)
            }
        }
        .sheet(item: $threadRoot) { message in
            ThreadView(store: store, channel: channel, root: message)
        }
        .sheet(item: $messageToForward) { message in
            ForwardMessageView(store: store, message: message)
        }
        .sheet(item: $messageInfoTarget) { message in
            MessageReadsView(store: store, channel: channel, message: message)
        }
        .sheet(isPresented: $showThreadsOverview) {
            ChannelThreadsView(store: store, channel: channel)
        }
        .task(id: channel.conversationId) {
            guard let conversationId = channel.conversationId else { return }
            await store.loadConversationReads(for: channel)
            await typingService.connect(conversationId: conversationId, configuration: store.configuration)
        }
        .onChange(of: messages.count) { _, _ in
            // Al llegar/enviarse mensajes, refresca las marcas de lectura para
            // que las palomitas se actualicen.
            Task { await store.loadConversationReads(for: channel) }
        }
        .onDisappear {
            Task { await typingService.disconnect() }
        }
        .onChange(of: draft) { oldValue, newValue in
            guard newValue != oldValue else { return }
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                typingService.userStoppedTyping(configuration: store.configuration)
            } else {
                typingService.userIsTyping(configuration: store.configuration)
            }
        }
    }

    private var isConnectedToChannelVoice: Bool {
        voiceStore.connectedChannel?.id == channel.id && voiceStore.isConnected
    }

    // MARK: - Secciones del body (separadas para ayudar al type-checker)

    private var topBar: some View {
        ChatTopBar(
            channel: channel,
            unreadThreads: unreadThreadCount,
            voiceActive: isConnectedToChannelVoice,
            onBack: { dismiss() },
            onRefresh: { Task { await store.open(channel, force: true) } },
            onShowThreads: channel.conversationId == nil ? nil : { showThreadsOverview = true },
            // Los DMs no tienen fila en core_channels, así que no tienen sala de voz.
            onToggleVoice: channel.isDirectMessage ? nil : { withAnimation(.snappy) { showVoicePanel.toggle() } },
            onToggleSearch: {
                withAnimation(.snappy) {
                    showChannelSearch.toggle()
                    if !showChannelSearch { resetChannelSearch() }
                }
            }
        )
    }

    private var latestPin: CoreMessagePin? {
        store.messagePins[channel.conversationId ?? ""]?.first
    }

    private func pinnedMessageBar(_ pin: CoreMessagePin) -> some View {
        let pinnedMessage = messages.first(where: { $0.id == pin.messageId })
        let pinCount = store.messagePins[pin.conversationId]?.count ?? 1

        return Button {
            pendingJumpId = pin.messageId
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "pin.fill")
                    .foregroundStyle(ZenitBrand.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(pinCount == 1 ? "Mensaje anclado" : "\(pinCount) mensajes anclados")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ZenitBrand.accent)
                    Text(pinnedMessage?.content.isEmpty == false ? pinnedMessage?.content ?? "" : "Toca para ver el mensaje")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.white)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var voicePanel: some View {
        ChannelVoiceCard(
            voiceStore: voiceStore,
            channel: channel,
            onJoin: { Task { await joinChannelVoice() } }
        )
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var missingConversationView: some View {
        ContentUnavailableView(
            "No conversation",
            systemImage: "exclamationmark.bubble",
            description: Text("This channel does not have a Core conversation attached.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unreadThreadsBanner: some View {
        Button {
            showThreadsOverview = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(ZenitBrand.accent)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(unreadThreadCount == 1 ? "Hay respuestas nuevas en un thread" : "Hay respuestas nuevas en \(unreadThreadCount) threads")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Si no ves mensajes nuevos aquí, están dentro de hilos.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
                Text("Ver")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(ZenitBrand.accent)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.white)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var messagesArea: some View {
        ScrollViewReader { proxy in
            messagesScroll
                .onChange(of: messages.last?.id) { _, _ in
                    scrollToBottom(proxy: proxy, animated: true)
                }
                .onChange(of: pendingJumpId) { _, target in
                    guard let target else { return }
                    Task {
                        await jumpToMessage(target, proxy: proxy)
                    }
                }
                .task(id: channel.id) {
                    await store.open(channel)
                    await store.loadMessagePins(for: channel)
                    await store.loadPolls(for: channel)
                    await store.loadChannelThreads(for: channel)
                    scrollToBottom(proxy: proxy, animated: false)
                }
        }
    }

    private var messagesScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(height: 1)
                    .id(bottomID)

                if store.isLoadingMessages[channel.conversationId ?? ""] == true {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding()
                        .scaleEffect(y: -1)
                }

                ForEach(messages.reversed()) { message in
                    messageRow(message)
                }

                if store.isLoadingOlderMessages[channel.conversationId ?? ""] == true {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .scaleEffect(y: -1)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 260)
        }
        .scaleEffect(y: -1)
        .scrollDismissesKeyboard(.interactively)
        .contentShape(Rectangle())
        .onTapGesture {
            isComposerFocused = false
        }
        .overlay {
            if messages.isEmpty && store.isLoadingMessages[channel.conversationId ?? ""] != true {
                ContentUnavailableView(
                    "No messages yet",
                    systemImage: "bubble.left",
                    description: Text(store.lastError ?? "Start the conversation in this channel.")
                )
            }
        }
    }

    private func messageRow(_ message: CoreMessage) -> some View {
        let rowBackground: Color = message.id == highlightedMessageId ? ZenitBrand.tealSoft : Color.clear
        let showAuthorInfo: Bool
        if let index = messages.firstIndex(where: { $0.id == message.id }), index > messages.startIndex {
            showAuthorInfo = messages[messages.index(before: index)].userId != message.userId
        } else {
            showAuthorInfo = true
        }

        return MessageBubble(
            message: message,
            isMine: message.userId == store.configuration.userId,
            showAuthorInfo: showAuthorInfo,
            mentionableUsers: store.members(for: channel),
            currentUserName: store.configuration.displayName,
            poll: store.polls[message.id],
            hasUnreadThread: hasUnreadThread(message.id),
            isPinned: store.isPinned(message),
            receipt: message.userId == store.configuration.userId
                ? store.receipt(for: message, in: channel)
                : nil,
            onVote: { optionId in
                if let poll = store.polls[message.id] {
                    Task { await store.votePoll(poll, optionId: optionId) }
                }
            },
            onReply: {
                replyTarget = message
                isComposerFocused = true
            },
            onLongPress: { selectedMessage = message },
            onThread: { threadRoot = message },
            onMentionTap: { user in
                Task { await openDirectMessage(with: user) }
            },
            onReact: { emoji in
                Task { await store.react(to: message, emoji: emoji) }
            }
        )
        .padding(.horizontal, 6)
        .padding(.vertical, showAuthorInfo ? 6 : 1)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .id(message.id)
        .scaleEffect(y: -1)
        .onAppear {
            guard message.id == messages.first?.id else { return }
            Task { await store.loadOlderMessages(in: channel) }
        }
    }

    @ViewBuilder
    private var typingIndicatorBar: some View {
        if let typingLabel = typingService.typingLabel {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text(typingLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(Color.white)
            .transition(.opacity)
        }
    }

    private var composer: some View {
        ComposerView(
            store: store,
            channel: channel,
            draft: $draft,
            replyTarget: $replyTarget,
            editTarget: $editTarget,
            attachments: $pendingAttachments,
            mentionableUsers: store.members(for: channel),
            isSending: store.isSending,
            isFocused: $isComposerFocused,
            onSend: handleSend
        )
    }

    private func handleSend() {
        let text = draft
        let quoted = replyTarget
        let editing = editTarget
        let attachments = pendingAttachments
        draft = ""
        replyTarget = nil
        editTarget = nil
        pendingAttachments = []
        Task {
            if let editing {
                await store.editMessage(editing, newContent: text)
            } else {
                await store.send(
                    text,
                    attachments: attachments,
                    in: channel,
                    replyTo: quoted
                )
            }
        }
    }

    // MARK: - Búsqueda dentro del canal

    private var channelSearchBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Buscar en este canal", text: $channelSearchText)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit { performInChannelSearch() }
                if isSearchingInChannel {
                    ProgressView().controlSize(.small)
                }
                Button {
                    withAnimation(.snappy) {
                        showChannelSearch = false
                        resetChannelSearch()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Cerrar búsqueda")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if !channelSearchHits.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(channelSearchHits) { hit in
                            Button {
                                pendingJumpId = hit.id
                                withAnimation(.snappy) { showChannelSearch = false }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(hit.authorName)
                                            .font(.caption.weight(.semibold))
                                        Spacer()
                                        Text(CoreFormat.conversationTime(hit.createdAt))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(CoreChannelSearchHit.snippet(from: hit.content, keyword: channelSearchText))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 14)
                        }
                    }
                }
                .frame(maxHeight: 230)
            } else if didSearchInChannel, !isSearchingInChannel {
                Text("Sin resultados en este canal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
        }
        .background(Color.white)
        .overlay(alignment: .bottom) { Divider() }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func performInChannelSearch() {
        let keyword = channelSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        isSearchingInChannel = true
        didSearchInChannel = false
        Task {
            var hits = await store.searchMessages(in: channel, keyword: keyword)
            if hits.isEmpty {
                // Los DMs no tienen channel_id: busca en lo cargado localmente.
                hits = messages.filter { $0.content.localizedCaseInsensitiveContains(keyword) }.reversed()
            }
            channelSearchHits = hits
            isSearchingInChannel = false
            didSearchInChannel = true
        }
    }

    private func resetChannelSearch() {
        channelSearchText = ""
        channelSearchHits = []
        didSearchInChannel = false
        isSearchingInChannel = false
    }

    /// Carga páginas antiguas hasta encontrar el mensaje y salta a él resaltándolo.
    private func jumpToMessage(_ messageId: String, proxy: ScrollViewProxy) async {
        guard let conversationId = channel.conversationId else {
            pendingJumpId = nil
            return
        }
        var attempts = 0
        while !messages.contains(where: { $0.id == messageId }),
              store.hasOlderMessages[conversationId] != false,
              attempts < 20 {
            await store.loadOlderMessages(in: channel)
            attempts += 1
        }
        pendingJumpId = nil
        guard messages.contains(where: { $0.id == messageId }) else {
            store.lastError = "El mensaje es muy antiguo para cargarlo aquí."
            return
        }
        highlightedMessageId = messageId
        withAnimation(.snappy) {
            proxy.scrollTo(messageId, anchor: .center)
        }
        try? await Task.sleep(for: .seconds(2.5))
        if highlightedMessageId == messageId {
            withAnimation { highlightedMessageId = nil }
        }
    }

    private func joinChannelVoice() async {
        do {
            let configuration = try await store.ensureFreshSession()
            await voiceStore.join(channel: channel, configuration: configuration)
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func openDirectMessage(with user: CoreUserLite) async {
        guard user.id != store.configuration.userId,
              let directChannel = await store.startDirectMessage(with: user) else {
            return
        }
        store.selectedChannelId = directChannel.id
        navigationPath = [directChannel.id]
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        guard !messages.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if animated {
                withAnimation(.snappy) {
                    proxy.scrollTo(bottomID, anchor: .top)
                }
            } else {
                proxy.scrollTo(bottomID, anchor: .top)
            }
        }
    }
}

// Tarjeta "Voz del canal": réplica de la web (CoreWorkspace.tsx → "Voz del canal").
// Todo canal de texto tiene una sala de voz siempre disponible; el room lo deriva
// el backend con la misma fórmula que la web (core-voice-{empresaId}-{channelId}).
private struct ChannelVoiceCard: View {
    @ObservedObject var voiceStore: CoreVoiceRoomStore
    let channel: CoreChannel
    let onJoin: () -> Void

    private static let coreGreen = ZenitBrand.accent

    private var isConnectedHere: Bool {
        voiceStore.connectedChannel?.id == channel.id && voiceStore.isConnected
    }

    private var isJoining: Bool {
        voiceStore.connectionState == .requestingAccess || voiceStore.connectionState == .connecting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.subheadline)
                    .foregroundStyle(Self.coreGreen)
                    .frame(width: 36, height: 36)
                    .background(Color.white)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("Voz de #\(channel.displayName)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(isConnectedHere ? "Conectado ahora." : "Siempre disponible para este canal.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if isConnectedHere {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Dentro ahora")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ForEach(voiceStore.participants) { participant in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(participant.isSpeaking ? Color.green : Self.coreGreen)
                                .frame(width: 8, height: 8)
                            Text(participant.name)
                                .font(.caption)
                                .lineLimit(1)
                            if participant.isLocal {
                                Text("Tú")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if participant.isMuted {
                                Image(systemName: "mic.slash.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 8) {
                    Button {
                        Task { await voiceStore.toggleMute() }
                    } label: {
                        Label(
                            voiceStore.isMuted ? "Activar mic" : "Silenciar",
                            systemImage: voiceStore.isMuted ? "mic.slash.fill" : "mic.fill"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        voiceStore.toggleSpeaker()
                    } label: {
                        Label(
                            "Altavoz",
                            systemImage: voiceStore.isSpeakerEnabled ? "speaker.wave.2.fill" : "speaker.fill"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()

                    Button {
                        Task { await voiceStore.leave() }
                    } label: {
                        Image(systemName: "phone.down.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                }

                VoiceScreenShareDock(voiceStore: voiceStore)
            } else {
                if let other = voiceStore.connectedChannel, voiceStore.isConnected {
                    Text("Estás conectado a la voz de #\(other.displayName). Al entrar aquí saldrás de esa sala.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button(action: onJoin) {
                    HStack(spacing: 6) {
                        if isJoining {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "mic.fill")
                        }
                        Text(isJoining ? "Conectando…" : "Entrar y hablar")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Self.coreGreen)
                .disabled(isJoining)
            }

            if let error = voiceStore.lastError, !isConnectedHere, !isJoining {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(isConnectedHere ? ZenitBrand.tealSoft : Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(isConnectedHere ? Self.coreGreen.opacity(0.4) : Color(.systemGray4), lineWidth: 1)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

/// Reactiva el gesto interactivo de "deslizar desde el borde para regresar"
/// cuando la barra de navegación está oculta (UIKit lo desactiva por defecto).
private struct InteractivePopGestureEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        Controller()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            enablePopGesture()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            enablePopGesture()
        }

        private func enablePopGesture() {
            guard let gesture = navigationController?.interactivePopGestureRecognizer else { return }
            gesture.delegate = self
            gesture.isEnabled = true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}

private struct ChatTopBar: View {
    let channel: CoreChannel
    var unreadThreads: Int = 0
    var voiceActive: Bool = false
    let onBack: () -> Void
    let onRefresh: () -> Void
    var onShowThreads: (() -> Void)? = nil
    var onToggleVoice: (() -> Void)? = nil
    var onToggleSearch: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel("Back")

            ChannelLogoView(channel: channel, size: 32)

            Button {
                onShowThreads?()
            } label: {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(channel.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(
                            channel.isDirectMessage
                                ? "Mensaje directo"
                                : (channel.visibility == .private ? "Private channel" : "Channel")
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }

                    if onShowThreads != nil {
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)

                        if unreadThreads > 0 {
                            Text("\(unreadThreads)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(ZenitBrand.accent)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(onShowThreads == nil)
            .accessibilityLabel("Ver threads del canal")

            Spacer()

            if let onToggleSearch {
                Button(action: onToggleSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 34, height: 38)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .accessibilityLabel("Buscar en el canal")
            }

            if let onToggleVoice {
                Button(action: onToggleVoice) {
                    Image(systemName: voiceActive ? "speaker.wave.2.fill" : "speaker.wave.2")
                        .font(.system(size: 19, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .overlay(alignment: .topTrailing) {
                            if voiceActive {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 9, height: 9)
                                    .offset(x: -4, y: 6)
                            }
                        }
                }
                .buttonStyle(.plain)
                .foregroundStyle(voiceActive ? ZenitBrand.accent : .primary)
                .accessibilityLabel("Voz del canal")
            }

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel("Refresh messages")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct VoiceChannelView: View {
    @ObservedObject var store: CoreChannelsStore
    @ObservedObject var voiceStore: CoreVoiceRoomStore
    let channel: CoreChannel

    var body: some View {
        VStack(spacing: 0) {
            VoiceChannelHeader(channel: channel)

            Group {
                if voiceStore.connectedChannel?.id == channel.id, voiceStore.isConnected {
                    VStack(spacing: 0) {
                        VoiceScreenShareDock(voiceStore: voiceStore)
                            .padding(.horizontal)
                            .padding(.top, 10)
                        participantList
                    }
                } else if voiceStore.connectionState == .requestingAccess ||
                            voiceStore.connectionState == .connecting {
                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.large)
                        Text(voiceStore.connectionState == .requestingAccess
                             ? "Requesting microphone access"
                             : "Connecting to voice")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("Voice unavailable", systemImage: "waveform.slash")
                    } description: {
                        Text(voiceStore.lastError ?? "Join this channel to start talking.")
                    } actions: {
                        Button("Try Again") {
                            Task { await joinVoiceChannel() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

            if voiceStore.connectedChannel?.id == channel.id, voiceStore.isConnected {
                VoiceControls(voiceStore: voiceStore)
            }
        }
        .navigationTitle(channel.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: channel.id) {
            await joinVoiceChannel()
        }
    }

    private func joinVoiceChannel() async {
        do {
            let configuration = try await store.ensureFreshSession()
            await voiceStore.join(channel: channel, configuration: configuration)
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private var participantList: some View {
        List {
            Section {
                ForEach(voiceStore.participants) { participant in
                    VoiceParticipantRow(participant: participant)
                }
            } header: {
                Text("\(voiceStore.participants.count) connected")
            }
        }
        .listStyle(.plain)
        .overlay {
            if voiceStore.participants.isEmpty {
                ProgressView("Loading participants")
            }
        }
    }
}

// Réplica del dock de pantalla compartida de la web ("Pantalla de {nombre}"):
// visible solo cuando alguien comparte; tocar abre la vista completa.
private struct VoiceScreenShareDock: View {
    @ObservedObject var voiceStore: CoreVoiceRoomStore
    @State private var showFullScreen = false

    var body: some View {
        if voiceStore.isScreenSharing {
            VStack(spacing: 0) {
                HStack {
                    Text("Pantalla de \(voiceStore.screenShareOwnerName ?? "participante")")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(red: 0.11, green: 0.11, blue: 0.11))

                VoiceScreenShareView(voiceStore: voiceStore)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .onTapGesture { showFullScreen = true }
            .accessibilityLabel("Abrir pantalla compartida")
            .fullScreenCover(isPresented: $showFullScreen) {
                VoiceScreenShareFullScreenView(voiceStore: voiceStore)
            }
        }
    }
}

private struct VoiceScreenShareFullScreenView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var voiceStore: CoreVoiceRoomStore

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            VoiceScreenShareView(voiceStore: voiceStore)
                .ignoresSafeArea(edges: .bottom)

            HStack {
                Text("Pantalla de \(voiceStore.screenShareOwnerName ?? "participante")")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.9))
                }
                .accessibilityLabel("Cerrar")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .onChange(of: voiceStore.isScreenSharing) { _, sharing in
            if !sharing { dismiss() }
        }
    }
}

private struct VoiceChannelHeader: View {
    let channel: CoreChannel

    var body: some View {
        HStack(spacing: 10) {
            ChannelLogoView(channel: channel, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.displayName)
                    .font(.subheadline.weight(.semibold))
                Text("Voice channel")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.white)
    }
}

private struct VoiceParticipantRow: View {
    let participant: CoreVoiceParticipant

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.14))
                Text(initials)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.accentColor)
            }
            .overlay {
                Circle()
                    .stroke(participant.isSpeaking ? Color.green : Color.clear, lineWidth: 3)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(participant.name)
                        .font(.body.weight(.semibold))
                    if participant.isLocal {
                        Text("You")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(participant.isSpeaking ? "Speaking" : "Connected")
                    .font(.caption)
                    .foregroundStyle(participant.isSpeaking ? Color.green : .secondary)
            }

            Spacer()

            Image(systemName: participant.isMuted ? "mic.slash.fill" : "mic.fill")
                .foregroundStyle(participant.isMuted ? .secondary : Color.green)
                .frame(width: 28, height: 28)
                .accessibilityLabel(participant.isMuted ? "Muted" : "Microphone on")
        }
        .padding(.vertical, 4)
    }

    private var initials: String {
        let parts = participant.name.split(separator: " ").prefix(2)
        let value = parts.compactMap(\.first).map(String.init).joined()
        return value.isEmpty ? "?" : value.uppercased()
    }
}

private struct VoiceControls: View {
    @ObservedObject var voiceStore: CoreVoiceRoomStore

    var body: some View {
        HStack(spacing: 24) {
            VoiceControlButton(
                title: voiceStore.isMuted ? "Unmute" : "Mute",
                systemImage: voiceStore.isMuted ? "mic.slash.fill" : "mic.fill",
                isActive: voiceStore.isMuted
            ) {
                Task { await voiceStore.toggleMute() }
            }

            VoiceControlButton(
                title: "Speaker",
                systemImage: voiceStore.isSpeakerEnabled ? "speaker.wave.2.fill" : "speaker.fill",
                isActive: voiceStore.isSpeakerEnabled
            ) {
                voiceStore.toggleSpeaker()
            }

            VoiceControlButton(
                title: "Leave",
                systemImage: "phone.down.fill",
                color: .red,
                isActive: true
            ) {
                Task { await voiceStore.leave() }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.vertical, 14)
        .background(.bar)
    }
}

private struct VoiceControlButton: View {
    let title: String
    let systemImage: String
    var color: Color = .accentColor
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .frame(width: 48, height: 48)
                    .background(isActive ? color : Color(.tertiarySystemFill))
                    .foregroundStyle(isActive ? .white : .primary)
                    .clipShape(Circle())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            .frame(width: 68)
        }
        .buttonStyle(.plain)
    }
}

private struct ConnectedVoiceBar: View {
    @ObservedObject var voiceStore: CoreVoiceRoomStore
    let channel: CoreChannel
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    ChannelLogoView(channel: channel, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(channel.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                Task { await voiceStore.toggleMute() }
            } label: {
                Image(systemName: voiceStore.isMuted ? "mic.slash.fill" : "mic.fill")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(voiceStore.isMuted ? "Unmute" : "Mute")

            Button(role: .destructive) {
                Task { await voiceStore.leave() }
            } label: {
                Image(systemName: "phone.down.fill")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Leave voice channel")
        }
        .padding(.horizontal)
        .padding(.vertical, 9)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var statusText: String {
        switch voiceStore.connectionState {
        case .reconnecting:
            return "Reconnecting"
        case .connected:
            return "\(voiceStore.participants.count) connected"
        default:
            return "Voice channel"
        }
    }
}

private struct MessageStickerReference: Identifiable, Hashable {
    let name: String
    let url: URL

    var id: String { "\(name)|\(url.absoluteString)" }
}

private extension String {
    static let stickerReferenceRegex = try! NSRegularExpression(
        pattern: #"\[sticker:([^\]]+)\]\s+(https?://\S+)"#
    )

    var stickerReferences: [MessageStickerReference] {
        let fullRange = NSRange(startIndex..<endIndex, in: self)
        return Self.stickerReferenceRegex.matches(in: self, range: fullRange).compactMap { match in
            guard
                let nameRange = Range(match.range(at: 1), in: self),
                let urlRange = Range(match.range(at: 2), in: self),
                let url = URL(string: String(self[urlRange]))
            else {
                return nil
            }

            return MessageStickerReference(
                name: String(self[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines),
                url: url
            )
        }
    }

    var removingStickerReferences: String {
        let fullRange = NSRange(startIndex..<endIndex, in: self)
        return Self.stickerReferenceRegex
            .stringByReplacingMatches(in: self, range: fullRange, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension CoreMessage {
    var stickerReferences: [MessageStickerReference] {
        content.stickerReferences
    }
}

private struct StickerMessageView: View {
    let stickers: [MessageStickerReference]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(stickers) { sticker in
                AttachmentMediaView(url: sticker.url, isGIF: true)
                .frame(width: 170, height: 170)
                .contentShape(Rectangle())
                .accessibilityLabel("Sticker \(sticker.name)")
            }
        }
    }
}

private struct MessageBubble: View {
    let message: CoreMessage
    let isMine: Bool
    let showAuthorInfo: Bool
    let mentionableUsers: [CoreUserLite]
    let currentUserName: String
    var poll: CorePoll? = nil
    var hasUnreadThread: Bool = false
    var isPinned: Bool = false
    var receipt: MessageReceipt? = nil
    var onVote: (String) -> Void = { _ in }
    let onReply: () -> Void
    let onLongPress: () -> Void
    let onThread: () -> Void
    let onMentionTap: (CoreUserLite) -> Void
    let onReact: (String) -> Void

    private var isVoiceNoteOnly: Bool {
        message.content == "Nota de voz" && (message.attachments?.contains { $0.isAudio } ?? false)
    }

    private var textContent: String {
        message.content.removingStickerReferences
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isMine {
                Spacer(minLength: 52)
            } else {
                if showAuthorInfo {
                    AvatarView(name: message.authorName, avatarURL: message.author?.avatarURL)
                } else {
                    Color.clear
                        .frame(width: 30, height: 30)
                }
            }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 5) {
                if !isMine, showAuthorInfo {
                    Text(message.authorName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(authorColor)
                }

                if let quote = message.metadata?.replyTo {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Respondiendo a \(quote.displayAuthor)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ZenitBrand.accent)
                        Text(quote.preview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.75))
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(ZenitBrand.accent)
                            .frame(width: 3)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if let parent = message.parent {
                    Text("Replying to \(parent.authorName): \(parent.content)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.horizontal, 10)
                }

                if message.metadata?.isCommandCard == true {
                    CommandCardView(message: message)
                } else if !textContent.isEmpty, !isVoiceNoteOnly {
                    EmojiAwareText(
                        textContent,
                        font: .body,
                        color: .primary,
                        mentionableUsers: mentionableUsers,
                        currentUserName: currentUserName,
                        onMentionTap: onMentionTap
                    )
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isMine ? ZenitBrand.bubbleMine : Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        if !isMine {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.black.opacity(0.06), lineWidth: 1)
                        }
                    }
                    .shadow(color: .black.opacity(isMine ? 0.03 : 0.06), radius: 1, y: 1)
                }

                if !message.stickerReferences.isEmpty {
                    StickerMessageView(stickers: message.stickerReferences)
                }

                if !isVoiceNoteOnly, let linkURL = textContent.firstDetectedURL {
                    LinkPreviewCard(url: linkURL)
                }

                if let attachments = message.attachments, !attachments.isEmpty {
                    AttachmentStrip(attachments: attachments)
                }

                if let poll {
                    PollVotingView(poll: poll, onVote: onVote)
                }

                HStack(spacing: 6) {
                    if let reactions = message.reactions, !reactions.isEmpty {
                        ForEach(reactions.groupedByEmoji, id: \.emoji) { item in
                            HStack(spacing: 3) {
                                EmojiGlyph(item.emoji, size: 14)
                                Text(String(item.count))
                                    .font(.caption2.weight(.semibold))
                            }
                            .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.thinMaterial)
                                .clipShape(Capsule())
                        }
                    }

                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(ZenitBrand.accent)
                            .accessibilityLabel("Mensaje anclado")
                    }

                    Text(CoreFormat.relativeTime(message.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if message.editedAt != nil {
                        Text("(editado)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if isMine, let receipt {
                        ReceiptTicks(receipt: receipt)
                    }
                }

                if let replyCount = message.replyCount, replyCount > 0 {
                    Button(action: onThread) {
                        HStack(spacing: 5) {
                            Label(
                                "\(replyCount) \(replyCount == 1 ? "reply" : "replies")",
                                systemImage: "bubble.left.and.bubble.right"
                            )
                            .font(.caption.weight(.semibold))

                            if hasUnreadThread {
                                Circle()
                                    .fill(Color(red: 0.08, green: 0.65, blue: 0.42))
                                    .frame(width: 8, height: 8)
                                    .accessibilityLabel("Respuestas sin leer")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.35, perform: onLongPress)
            // Deslizar el mensaje hacia la derecha = responder (estilo WhatsApp).
            .simultaneousGesture(
                DragGesture(minimumDistance: 35)
                    .onEnded { value in
                        if value.translation.width > 60, abs(value.translation.height) < 40 {
                            onReply()
                        }
                    }
            )

            if !isMine {
                Spacer(minLength: 52)
            }
        }
    }

    private var authorColor: Color {
        let colors: [Color] = [
            Color(red: 0.07, green: 0.45, blue: 0.73),
            Color(red: 0.63, green: 0.20, blue: 0.58),
            Color(red: 0.84, green: 0.32, blue: 0.18),
            Color(red: 0.10, green: 0.55, blue: 0.38),
            Color(red: 0.72, green: 0.42, blue: 0.05)
        ]
        let value = message.userId.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return colors[value % colors.count]
    }
}

private struct CommandCardView: View {
    let message: CoreMessage

    private var metadata: CoreMessageMetadata? { message.metadata }
    private var payload: [String: CoreJSONValue] { metadata?.payload ?? [:] }
    private var command: String { metadata?.command ?? "comando" }
    private var isError: Bool { metadata?.status == "error" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("/\(command)", systemImage: command == "dado" ? "die.face.5.fill" : "sparkles")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(statusLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isError ? .red : ZenitBrand.accent)
            }

            Divider()

            if command == "dado", let result = payload["result"]?.numberValue {
                HStack(spacing: 14) {
                    Image(systemName: "die.face.\(Int(result)).fill")
                        .font(.system(size: 48))
                        .foregroundStyle(ZenitBrand.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sacaste \(Int(result))")
                            .font(.title3.weight(.bold))
                        if let xp = payload["xp"]?.numberValue {
                            Text("+\(Int(xp)) XP")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(ZenitBrand.accent)
                        }
                        if let flavor = payload["flavor"]?.stringValue {
                            Text(flavor).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if command == "xp" {
                xpContent
            } else if command == "poll" {
                pollContent
            } else {
                genericContent
            }
        }
        .padding(14)
        .frame(maxWidth: 320, alignment: .leading)
        .background(isError ? Color.red.opacity(0.08) : Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isError ? Color.red.opacity(0.35) : ZenitBrand.accent.opacity(0.2))
        }
    }

    private var statusLabel: String {
        switch metadata?.status {
        case "finished": return "Finalizado"
        case "error": return "Error"
        case "active": return "Activo"
        case "expired": return "Expirado"
        default: return "Comando"
        }
    }

    @ViewBuilder
    private var xpContent: some View {
        let user = payload["user"]?.objectValue
        VStack(alignment: .leading, spacing: 5) {
            Text(user?["full_name"]?.stringValue ?? "Usuario Core")
                .font(.headline)
            if let total = payload["totalXp"]?.numberValue {
                Text("\(Int(total)) XP")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(ZenitBrand.accent)
            }
            HStack {
                if let level = payload["level"]?.numberValue {
                    Text("Nivel \(Int(level))")
                }
                if let rank = payload["rank"]?.numberValue {
                    Text("Ranking #\(Int(rank))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var pollContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(payload["question"]?.stringValue ?? "Encuesta")
                .font(.headline)
            ForEach(Array((payload["options"]?.arrayValue ?? []).enumerated()), id: \.offset) { index, option in
                HStack {
                    Text("\(index + 1).")
                        .foregroundStyle(.secondary)
                    Text(option.stringValue ?? "Opción")
                }
                .font(.subheadline)
            }
        }
    }

    @ViewBuilder
    private var genericContent: some View {
        if let title = payload["title"]?.stringValue {
            Text(title)
                .font(.headline)
                .foregroundStyle(isError ? .red : .primary)
        } else if let task = payload["task"]?.stringValue {
            Text(task).font(.headline)
        } else {
            Text("Comando /\(command) creado")
                .font(.headline)
        }
        if let description = payload["description"]?.stringValue {
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// Detalle de lectura de un mensaje (similar a "Info" de WhatsApp/Meta):
/// quiénes ya lo leyeron (✓✓ azul) y a quiénes les falta (✓✓ gris).
private struct MessageReadsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CoreChannelsStore
    let channel: CoreChannel
    let message: CoreMessage

    private var readers: [CoreUserLite] {
        store.readers(of: message, in: channel)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var pending: [CoreUserLite] {
        let readerIds = Set(readers.map(\.id))
        return store.members(for: channel)
            .filter { $0.id != message.userId && !readerIds.contains($0.id) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var reads: [String: Date] {
        store.conversationReads[message.conversationId] ?? [:]
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    MessageContextPreview(message: message, isMine: message.userId == store.configuration.userId)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowBackground(Color.clear)
                }

                Section {
                    if readers.isEmpty {
                        Text("Aún nadie lo ha leído.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(readers) { member in
                            HStack(spacing: 10) {
                                AvatarView(name: member.displayName, avatarURL: member.avatarURL)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(member.displayName)
                                    if let readAt = reads[member.id] {
                                        Text("Visto \(CoreFormat.relativeTime(readAt))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                ReceiptTicks(receipt: .readByAll)
                            }
                        }
                    }
                } header: {
                    Label("Leído por", systemImage: "checkmark.circle.fill")
                }

                if !pending.isEmpty {
                    Section {
                        ForEach(pending) { member in
                            HStack(spacing: 10) {
                                AvatarView(name: member.displayName, avatarURL: member.avatarURL)
                                Text(member.displayName)
                                Spacer()
                                ReceiptTicks(receipt: .sent)
                            }
                        }
                    } header: {
                        Label("Pendientes", systemImage: "clock")
                    }
                }
            }
            .navigationTitle("Vistos por")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
            .task {
                await store.loadConversationReads(for: channel)
            }
            .refreshable {
                await store.loadConversationReads(for: channel)
            }
        }
    }
}

/// Palomitas de estado de un mensaje propio (estilo WhatsApp):
/// ✓ enviado · ✓✓ gris leído por algunos · ✓✓ azul leído por todos.
struct ReceiptTicks: View {
    let receipt: MessageReceipt

    private var color: Color {
        receipt == .readByAll ? Color(red: 0.20, green: 0.55, blue: 0.97) : .secondary
    }

    var body: some View {
        HStack(spacing: -5) {
            Image(systemName: "checkmark")
            if receipt != .sent {
                Image(systemName: "checkmark")
            }
        }
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(color)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        switch receipt {
        case .sent: return "Enviado"
        case .readBySome: return "Leído por algunos"
        case .readByAll: return "Leído por todos"
        }
    }
}

private struct MessageActionOverlay: View {
    let message: CoreMessage
    let isMine: Bool
    let isPinned: Bool
    let onDismiss: () -> Void
    let onReply: () -> Void
    var onEdit: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    let onForward: () -> Void
    let onCopy: () -> Void
    let onThread: () -> Void
    let onTogglePin: () -> Void
    var onInfo: (() -> Void)? = nil
    var onSaveSticker: (() -> Void)? = nil
    let onReact: (String) -> Void

    private let reactions = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    var body: some View {
        ZStack {
            Color.black.opacity(0.46)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(alignment: isMine ? .trailing : .leading, spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(reactions, id: \.self) { emoji in
                        Button {
                            onReact(emoji)
                        } label: {
                            EmojiGlyph(emoji, size: 28)
                                .frame(width: 40, height: 40)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.regularMaterial)
                .clipShape(Capsule())

                MessageContextPreview(message: message, isMine: isMine)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(spacing: 0) {
                    MessageActionRow(title: "Responder", systemImage: "arrowshape.turn.up.left", action: onReply)
                    Divider().padding(.leading, 16)
                    MessageActionRow(title: "Responder en thread", systemImage: "bubble.left.and.bubble.right", action: onThread)
                    Divider().padding(.leading, 16)
                    MessageActionRow(title: "Reenviar", systemImage: "arrowshape.turn.up.right", action: onForward)
                    Divider().padding(.leading, 16)
                    MessageActionRow(title: "Copiar", systemImage: "doc.on.doc", action: onCopy)
                    Divider().padding(.leading, 16)
                    MessageActionRow(
                        title: isPinned ? "Desanclar" : "Anclar",
                        systemImage: isPinned ? "pin.slash" : "pin",
                        action: onTogglePin
                    )
                    if let onInfo {
                        Divider().padding(.leading, 16)
                        MessageActionRow(title: "Vistos por", systemImage: "checkmark.circle", action: onInfo)
                    }
                    if let onSaveSticker {
                        Divider().padding(.leading, 16)
                        MessageActionRow(title: "Guardar sticker", systemImage: "square.and.arrow.down", action: onSaveSticker)
                    }
                    if isMine, let onEdit {
                        Divider().padding(.leading, 16)
                        MessageActionRow(title: "Editar", systemImage: "pencil", action: onEdit)
                    }
                    if isMine, let onDelete {
                        Divider().padding(.leading, 16)
                        MessageActionRow(title: "Eliminar", systemImage: "trash", tint: .red, action: onDelete)
                    }
                }
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .frame(maxWidth: 300, alignment: isMine ? .trailing : .leading)
            .padding(.horizontal, 24)
        }
        .animation(nil, value: message.id)
    }
}

private struct MessageActionRow: View {
    let title: String
    let systemImage: String
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: systemImage)
                    .font(.title3)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 16)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MessageContextPreview: View {
    let message: CoreMessage
    let isMine: Bool

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 6) {
            if !isMine {
                Text(message.authorName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if !message.content.isEmpty {
                EmojiAwareText(
                    message.content,
                    font: .body,
                    color: .primary
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(isMine ? Color(red: 0.85, green: 0.97, blue: 0.82) : Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            if let attachment = message.attachments?.first,
               attachment.isImage,
               let url = attachment.resolvedURL {
                AttachmentMediaView(url: url, isGIF: attachment.isGIF)
                    .frame(width: 220, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Text(CoreFormat.relativeTime(message.createdAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: 280, alignment: isMine ? .trailing : .leading)
        .background(Color(.systemBackground))
    }
}

private struct ForwardMessageView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CoreChannelsStore
    let message: CoreMessage

    var body: some View {
        NavigationStack {
            List(store.textChannels) { channel in
                Button {
                    Task {
                        await store.forward(message, to: channel)
                        if store.lastError == nil {
                            dismiss()
                        }
                    }
                } label: {
                    HStack(spacing: 12) {
                        ChannelLogoView(channel: channel, size: 38)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(channel.displayName)
                                .foregroundStyle(.primary)
                            Text(channel.descriptionText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .disabled(store.isSending)
            }
            .navigationTitle("Forward to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct ChannelLogoView: View {
    let channel: CoreChannel
    let size: CGFloat

    private var iconSource: ChannelIconSource? {
        ChannelIconSource(rawValue: channel.metadata?.iconImage)
    }

    @ViewBuilder
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

/// Resolves a channel `iconImage` string into a renderable source.
/// Supports both base64 `data:` URLs (PNGs uploaded from the web app) and
/// regular remote URLs. `AsyncImage` does not load `data:` URLs, so those are
/// decoded into a `UIImage` up front.
private enum ChannelIconSource {
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

private struct ThreadView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CoreChannelsStore
    let channel: CoreChannel
    let root: CoreMessage

    @State private var draft = ""
    @State private var attachments: [CorePendingAttachment] = []
    @State private var unusedReplyTarget: CoreMessage?
    @State private var unusedEditTarget: CoreMessage?
    @FocusState private var isFocused: Bool
    private let bottomID = "thread-bottom"

    private var replies: [CoreMessage] {
        store.threadReplies[root.id] ?? []
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ThreadMessageRow(
                                message: root,
                                isRoot: true,
                                mentionableUsers: store.members(for: channel),
                                currentUserName: store.configuration.displayName
                            )

                            if store.isLoadingThread[root.id] == true {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .padding()
                            } else if replies.isEmpty {
                                Text("Be the first to reply in this thread.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 28)
                            } else {
                                ForEach(replies) { reply in
                                    ThreadMessageRow(
                                        message: reply,
                                        isRoot: false,
                                        mentionableUsers: store.members(for: channel),
                                        currentUserName: store.configuration.displayName
                                    )
                                }
                            }

                            Color.clear.frame(height: 1).id(bottomID)
                        }
                        .padding()
                    }
                    .onChange(of: replies.last?.id) { _, _ in
                        withAnimation(.snappy) {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    }
                }

                ComposerView(
                    store: store,
                    channel: channel,
                    threadParentId: root.id,
                    draft: $draft,
                    replyTarget: $unusedReplyTarget,
                    editTarget: $unusedEditTarget,
                    attachments: $attachments,
                    mentionableUsers: store.members(for: channel),
                    isSending: store.isSending,
                    isFocused: $isFocused,
                    onSend: {
                        let text = draft
                        let pending = attachments
                        draft = ""
                        attachments = []
                        Task {
                            await store.sendThreadReply(
                                text,
                                attachments: pending,
                                to: root,
                                in: channel
                            )
                        }
                    }
                )
            }
            .navigationTitle("Thread")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: root.id) {
                await store.loadThread(for: root)
                markThreadRead()
            }
            .onChange(of: replies.last?.id) { _, _ in
                markThreadRead()
            }
        }
    }

    private func markThreadRead() {
        let lastReplyAt = replies.last?.createdAt ?? Date()
        ThreadReadTracker.shared.markRead(root.id, at: max(lastReplyAt, Date()))
    }
}

private struct ThreadMessageRow: View {
    let message: CoreMessage
    let isRoot: Bool
    let mentionableUsers: [CoreUserLite]
    let currentUserName: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(name: message.authorName, avatarURL: message.author?.avatarURL)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(message.authorName)
                        .font(.subheadline.weight(.semibold))
                    Text(CoreFormat.relativeTime(message.createdAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !message.content.isEmpty {
                    EmojiAwareText(
                        message.content,
                        font: .body,
                        color: .primary,
                        mentionableUsers: mentionableUsers,
                        currentUserName: currentUserName
                    )
                }

                if let linkURL = message.content.firstDetectedURL {
                    LinkPreviewCard(url: linkURL)
                }

                if let attachments = message.attachments, !attachments.isEmpty {
                    AttachmentStrip(attachments: attachments)
                }

                if isRoot {
                    Text("Thread")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }

            Spacer()
        }
        .padding(.bottom, isRoot ? 12 : 0)
        .overlay(alignment: .bottom) {
            if isRoot { Divider() }
        }
    }
}

private struct ChannelThreadsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CoreChannelsStore
    @ObservedObject private var threadReads = ThreadReadTracker.shared
    let channel: CoreChannel

    @State private var selectedThread: CoreMessage?

    private var summaries: [CoreThreadSummary] {
        store.channelThreads[channel.conversationId ?? ""] ?? []
    }

    private var isLoading: Bool {
        store.isLoadingChannelThreads[channel.conversationId ?? ""] == true
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && summaries.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if summaries.isEmpty {
                    ContentUnavailableView(
                        "Sin threads",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Todavía no hay conversaciones en threads en este canal.")
                    )
                } else {
                    List(summaries) { summary in
                        Button {
                            selectedThread = summary.root
                        } label: {
                            ThreadSummaryRow(
                                summary: summary,
                                isUnread: threadReads.isUnread(summary, currentUserId: store.configuration.userId)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Threads · \(channel.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
            .task {
                await store.loadChannelThreads(for: channel, force: true)
            }
            .refreshable {
                await store.loadChannelThreads(for: channel, force: true)
            }
            .sheet(item: $selectedThread) { root in
                ThreadView(store: store, channel: channel, root: root)
            }
        }
    }
}

/// Fila del filtro "Hilos" del index: título del thread arriba y, debajo,
/// el icono + nombre del canal al que pertenece.
private struct IndexThreadRow: View {
    let item: ChannelThreadItem
    let isUnread: Bool

    private static let unreadGreen = Color(red: 0.08, green: 0.65, blue: 0.42)

    private var title: String {
        let content = item.summary.root.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty { return content }
        if let attachment = item.summary.root.attachments?.first {
            if attachment.isAudio { return "🎤 Nota de voz" }
            if attachment.isGIF { return "GIF" }
            if attachment.isImage { return "📷 Foto" }
            return attachment.fileName
        }
        return "Mensaje"
    }

    private var replyText: String {
        item.summary.replyCount == 1 ? "1 respuesta" : "\(item.summary.replyCount) respuestas"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.subheadline.weight(isUnread ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    ChannelLogoView(channel: item.channel, size: 18)
                    Text(item.channel.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(replyText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                Text(CoreFormat.relativeTime(item.summary.lastReplyAt))
                    .font(.caption2)
                    .foregroundStyle(isUnread ? Self.unreadGreen : .secondary)
                if isUnread {
                    Text("Nuevo")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Self.unreadGreen)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct ThreadSummaryRow: View {
    let summary: CoreThreadSummary
    let isUnread: Bool

    private var preview: String {
        let content = summary.root.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty { return content }
        if let attachment = summary.root.attachments?.first {
            if attachment.isAudio { return "🎤 Nota de voz" }
            if attachment.isGIF { return "GIF" }
            if attachment.isImage { return "📷 Foto" }
            return attachment.fileName
        }
        return "Mensaje"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(name: summary.root.authorName, avatarURL: summary.root.author?.avatarURL)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(summary.root.authorName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(CoreFormat.relativeTime(summary.lastReplyAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(isUnread ? .primary : .secondary)
                    .fontWeight(isUnread ? .medium : .regular)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Label(
                        summary.replyCount == 1 ? "1 respuesta" : "\(summary.replyCount) respuestas",
                        systemImage: "bubble.left.and.bubble.right"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)

                    if isUnread {
                        Text("Nuevo")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(red: 0.08, green: 0.65, blue: 0.42))
                            .clipShape(Capsule())
                    }
                }
            }

            if isUnread {
                Circle()
                    .fill(Color(red: 0.08, green: 0.65, blue: 0.42))
                    .frame(width: 10, height: 10)
                    .padding(.top, 6)
                    .accessibilityLabel("Respuestas sin leer")
            }
        }
        .padding(.vertical, 4)
    }
}

private enum ComposerPanel: Equatable {
    case none
    case menu
    case command
    case poll
    case gif
    case sticker
    case emoji
}

private struct ComposerView: View {
    @ObservedObject var store: CoreChannelsStore
    let channel: CoreChannel
    var threadParentId: String? = nil
    @Binding var draft: String
    @Binding var replyTarget: CoreMessage?
    @Binding var editTarget: CoreMessage?
    @Binding var attachments: [CorePendingAttachment]
    let mentionableUsers: [CoreUserLite]
    let isSending: Bool
    var isFocused: FocusState<Bool>.Binding
    let onSend: () -> Void
    @State private var activePanel: ComposerPanel = .none
    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @StateObject private var voiceRecorder = VoiceNoteRecorder()
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isLoadingPhotos = false
    @State private var attachmentError: String?
    @State private var mediaEditorItems: [MediaEditorItem] = []
    @State private var showMediaEditor = false

    var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) &&
        !isLoadingPhotos &&
        !isSending
    }

    private var mentionSuggestions: [CoreUserLite] {
        guard let query = mentionQuery else { return [] }
        return Array(
            mentionableUsers
                .filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) }
                .prefix(6)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if let editTarget {
                HStack(spacing: 10) {
                    Image(systemName: "pencil")
                        .foregroundStyle(ZenitBrand.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Editando mensaje")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ZenitBrand.accent)
                        Text(editTarget.content)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        self.editTarget = nil
                        draft = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Cancelar edición")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(ZenitBrand.tealSoft)
            }

            if let replyTarget {
                HStack(spacing: 10) {
                    Rectangle()
                        .fill(ZenitBrand.accent)
                        .frame(width: 4)
                        .clipShape(Capsule())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Respondiendo a \(replyTarget.authorName)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ZenitBrand.accent)
                        Text(
                            replyTarget.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? (replyTarget.attachments?.isEmpty == false ? "Mensaje con adjuntos" : "Mensaje")
                                : replyTarget.content
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    }
                    Spacer()
                    Button {
                        self.replyTarget = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Cancelar respuesta")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .fixedSize(horizontal: false, vertical: true)
                .background(ZenitBrand.tealSoft)
            }

            if !attachments.isEmpty || isLoadingPhotos || attachmentError != nil {
                PendingAttachmentStrip(
                    attachments: attachments,
                    isLoading: isLoadingPhotos,
                    error: attachmentError,
                    onRemove: { id in
                        attachments.removeAll { $0.id == id }
                    }
                )
            }

            if !mentionSuggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(mentionSuggestions) { user in
                        Button {
                            insertMention(user)
                        } label: {
                            HStack(spacing: 10) {
                                AvatarView(name: user.displayName, avatarURL: user.avatarURL)
                                Text(user.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 46)
                        }
                        .buttonStyle(.plain)

                        if user.id != mentionSuggestions.last?.id {
                            Divider().padding(.leading, 54)
                        }
                    }
                }
                .background(Color.white)
                .overlay(alignment: .top) { Divider() }
            }

            HStack(alignment: .bottom, spacing: 8) {
                HStack(alignment: .bottom, spacing: 4) {
                    Button {
                        toggleToolsMenu()
                    } label: {
                        Image(systemName: activePanel == .menu ? "xmark" : "plus")
                            .font(.system(size: 21, weight: .medium))
                            .frame(width: 34, height: 38)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(activePanel == .menu ? Color.accentColor : .secondary)
                    .accessibilityLabel("Herramientas")

                    TextField("Mensaje", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .focused(isFocused)
                        .lineLimit(1...5)
                        .padding(.vertical, 9)
                        .submitLabel(.send)
                        .onSubmit {
                            if canSend {
                                onSend()
                            }
                        }
                        .onTapGesture {
                            activePanel = .none
                        }
                }
                .padding(.horizontal, 4)
                .background(Color(red: 0.95, green: 0.96, blue: 0.96))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                Button(action: onSend) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color(red: 0.08, green: 0.65, blue: 0.42))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.35)
                .accessibilityLabel("Send message")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(Color.white)

            composerPanels
        }
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPhotos(items) }
        }
        .onChange(of: isFocused.wrappedValue) { _, focused in
            if focused, activePanel == .menu || activePanel == .emoji {
                activePanel = .none
            }
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotos,
            maxSelectionCount: max(1, 5 - attachments.count),
            matching: .any(of: [.images, .videos])
        )
        .fullScreenCover(isPresented: $showMediaEditor) {
            MediaEditorView(
                items: mediaEditorItems,
                onCancel: {
                    showMediaEditor = false
                    mediaEditorItems = []
                },
                onSend: { editedAttachments, caption in
                    showMediaEditor = false
                    mediaEditorItems = []
                    sendEditedMedia(editedAttachments, caption: caption)
                },
                onSaveSticker: { data in
                    let format = StickerImageFormat.detect(data)
                    let fileName = "sticker-\(Int(Date().timeIntervalSince1970 * 1000)).\(format.fileExtension)"
                    return await store.uploadSticker(
                        name: "Sticker",
                        data: data,
                        fileName: fileName,
                        mimeType: format.mimeType
                    ) != nil
                }
            )
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
    }

    @ViewBuilder
    private var composerPanels: some View {
        if voiceRecorder.isRecording {
            VoiceNoteBar(
                recorder: voiceRecorder,
                onSend: { sendVoiceRecording() },
                onCancel: { voiceRecorder.cancel() }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            switch activePanel {
            case .menu:
                ComposerToolsTray(
                    tools: ComposerTool.allCases.filter { threadParentId == nil || $0 != .poll }
                ) { handleToolSelection($0) }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            case .command:
                CommandPalettePanel { insertCommand($0) }
            case .poll:
                PollComposerPanel { question, options in submitPoll(question, options) }
            case .gif:
                GifPickerPanel(apiKey: store.giphyAPIKey) { sendGif($0) }
            case .sticker:
                StickerPickerPanel(store: store) { sendSticker($0) }
            case .emoji:
                WhatsAppEmojiPicker(
                    onSelect: { draft.append($0) },
                    onDelete: {
                        guard !draft.isEmpty else { return }
                        draft.removeLast()
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            case .none:
                EmptyView()
            }
        }
    }

    private func toggleToolsMenu() {
        withAnimation(.snappy) {
            if activePanel == .menu {
                activePanel = .none
            } else {
                isFocused.wrappedValue = false
                activePanel = .menu
            }
        }
    }

    private func handleToolSelection(_ tool: ComposerTool) {
        switch tool {
        case .command:
            withAnimation(.snappy) { activePanel = .command }
        case .file:
            activePanel = .none
            showFileImporter = true
        case .photo:
            activePanel = .none
            showPhotoPicker = true
        case .audio:
            startVoiceRecording()
        case .poll:
            withAnimation(.snappy) { activePanel = .poll }
        case .emoji:
            isFocused.wrappedValue = false
            withAnimation(.snappy) { activePanel = .emoji }
        case .gif:
            isFocused.wrappedValue = false
            withAnimation(.snappy) { activePanel = .gif }
        case .sticker:
            isFocused.wrappedValue = false
            withAnimation(.snappy) { activePanel = .sticker }
        }
    }

    private func insertCommand(_ command: String) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = trimmed.isEmpty ? "\(command) " : "\(draft) \(command) "
        activePanel = .none
        isFocused.wrappedValue = true
    }

    private func submitPoll(_ question: String, _ options: [String]) {
        activePanel = .none
        Task { await store.createPoll(question: question, options: options, in: channel) }
    }

    private func sendGif(_ gif: GiphyGif) {
        activePanel = .none
        Task {
            await store.sendRemoteMedia(
                urlString: gif.originalURL,
                fileName: "giphy-\(gif.id).gif",
                in: channel,
                parentMessageId: threadParentId
            )
        }
    }

    private func sendSticker(_ sticker: CoreSticker) {
        activePanel = .none
        Task {
            await store.send(
                "[sticker:\(sticker.name)] \(sticker.imageURL)",
                in: channel,
                parentMessageId: threadParentId
            )
        }
    }

    private func startVoiceRecording() {
        activePanel = .none
        isFocused.wrappedValue = false
        attachmentError = nil
        Task {
            let started = await voiceRecorder.requestAndStart()
            if !started {
                attachmentError = "No se pudo acceder al micrófono."
            }
        }
    }

    private func sendVoiceRecording() {
        Task {
            guard let data = await voiceRecorder.stopAndFetch() else {
                voiceRecorder.cancel()
                attachmentError = "No se pudo capturar el audio. Intenta grabar de nuevo."
                return
            }
            attachmentError = nil
            let quoted = threadParentId == nil ? replyTarget : nil
            await store.sendVoiceNote(
                data: data,
                in: channel,
                parentMessageId: threadParentId,
                replyTo: quoted
            )
            if let error = store.lastError {
                attachmentError = "No se pudo enviar la nota de voz: \(error)"
            } else {
                replyTarget = nil
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result else { return }
        for url in urls.prefix(max(0, 5 - attachments.count)) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            guard data.count <= 15 * 1_024 * 1_024 else {
                attachmentError = "Cada archivo debe pesar 15 MB o menos."
                continue
            }
            attachments.append(
                CorePendingAttachment(
                    data: data,
                    fileName: url.lastPathComponent,
                    mimeType: CoreChannelsStore.mimeType(forFileName: url.lastPathComponent)
                )
            )
        }
    }

    private var mentionQuery: String? {
        guard let atIndex = draft.lastIndex(of: "@") else { return nil }
        if atIndex > draft.startIndex {
            let previous = draft[draft.index(before: atIndex)]
            guard previous.isWhitespace else { return nil }
        }

        let query = String(draft[draft.index(after: atIndex)...])
        guard !query.contains(where: \.isWhitespace) else { return nil }
        return query
    }

    private func insertMention(_ user: CoreUserLite) {
        guard let atIndex = draft.lastIndex(of: "@") else { return }
        draft.replaceSubrange(atIndex..<draft.endIndex, with: "@\(user.displayName) ")
        isFocused.wrappedValue = true
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        isLoadingPhotos = true
        attachmentError = nil
        defer {
            selectedPhotos = []
            isLoadingPhotos = false
        }

        var editorItems: [MediaEditorItem] = []

        for item in items.prefix(max(0, 5 - attachments.count)) {
            do {
                let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }

                if isVideo {
                    // El video se transfiere como archivo (sin cargarlo completo
                    // en memoria); el editor lo comprime/recorta y se validan
                    // 15 MB tras exportar.
                    guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { continue }
                    let fileSize = (try? FileManager.default
                        .attributesOfItem(atPath: movie.url.path)[.size] as? Int) ?? 0
                    guard fileSize <= 500 * 1_024 * 1_024 else {
                        try? FileManager.default.removeItem(at: movie.url)
                        attachmentError = "El video es demasiado grande (máx. 500 MB)."
                        continue
                    }
                    let ext = movie.url.pathExtension.lowercased()
                    editorItems.append(
                        MediaEditorItem(
                            videoURL: movie.url,
                            fileName: movie.url.lastPathComponent,
                            mimeType: ext == "mov" ? "video/quicktime" : "video/mp4"
                        )
                    )
                    continue
                }

                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let isGIF = item.supportedContentTypes.contains { $0.conforms(to: .gif) }

                if isGIF {
                    // Los GIF animados se envían tal cual (editarlos rompería la animación).
                    guard data.count <= 15 * 1_024 * 1_024 else {
                        attachmentError = "Cada GIF debe pesar 15 MB o menos."
                        continue
                    }
                    attachments.append(
                        CorePendingAttachment(
                            data: data,
                            fileName: "image-\(UUID().uuidString).gif",
                            mimeType: "image/gif"
                        )
                    )
                } else if let image = UIImage(data: data) {
                    guard data.count <= 60 * 1_024 * 1_024 else {
                        attachmentError = "La imagen es demasiado grande (máx. 60 MB)."
                        continue
                    }
                    editorItems.append(
                        MediaEditorItem(
                            image: image,
                            fileName: "image-\(UUID().uuidString).jpg",
                            mimeType: "image/jpeg"
                        )
                    )
                }
            } catch {
                attachmentError = error.localizedDescription
            }
        }

        if !editorItems.isEmpty {
            mediaEditorItems = editorItems
            showMediaEditor = true
        }
    }

    /// Envía los medios ya editados (crop/dibujo/trim/calidad) con su caption,
    /// respetando hilo y respuesta citada, igual que las notas de voz.
    private func sendEditedMedia(_ editedAttachments: [CorePendingAttachment], caption: String) {
        guard !editedAttachments.isEmpty else { return }
        attachmentError = nil
        let quoted = threadParentId == nil ? replyTarget : nil
        Task {
            await store.send(
                caption,
                attachments: editedAttachments,
                in: channel,
                parentMessageId: threadParentId,
                replyTo: quoted
            )
            if let error = store.lastError {
                attachmentError = "No se pudo enviar: \(error)"
            } else {
                replyTarget = nil
            }
        }
    }
}

private struct ChannelThemeDraft: Equatable {
    var preset = "classic"
    var background = "#ffffff"
    var backgroundImage = ""
    var backgroundImageOpacity: Double = 28
    var accent = "#007a5a"
    var titleColor = "#1d1c1d"
    var surface = "#ffffff"
    var bubbleMine = "#d8f5e6"
    var bubbleOther = "#ffffff"

    // Mismos presets que la web (CoreWorkspace.tsx → channelThemePresets).
    static let presets: [(id: String, name: String)] = [
        ("classic", "Classic"),
        ("lagoon", "Lagoon"),
        ("sunrise", "Sunrise"),
        ("lavender", "Lavender"),
        ("graphite", "Graphite")
    ]

    static func preset(_ id: String) -> ChannelThemeDraft {
        var draft = ChannelThemeDraft()
        switch id {
        case "lagoon":
            draft.preset = "lagoon"
            draft.background = "#eef8f6"
            draft.accent = "#007a5a"
            draft.surface = "#ffffff"
            draft.bubbleMine = "#c9f0df"
            draft.bubbleOther = "#ffffff"
        case "sunrise":
            draft.preset = "sunrise"
            draft.background = "#fff7ed"
            draft.accent = "#c2410c"
            draft.surface = "#fffaf5"
            draft.bubbleMine = "#fed7aa"
            draft.bubbleOther = "#fffaf5"
        case "lavender":
            draft.preset = "lavender"
            draft.background = "#f5f3ff"
            draft.accent = "#6d28d9"
            draft.surface = "#ffffff"
            draft.bubbleMine = "#ddd6fe"
            draft.bubbleOther = "#ffffff"
        case "graphite":
            draft.preset = "graphite"
            draft.background = "#f4f4f5"
            draft.accent = "#3f3f46"
            draft.surface = "#ffffff"
            draft.bubbleMine = "#e4e4e7"
            draft.bubbleOther = "#ffffff"
        default:
            break
        }
        return draft
    }

    var coreTheme: CoreChannelTheme {
        CoreChannelTheme(
            preset: preset,
            background: background,
            backgroundImage: backgroundImage,
            backgroundImageOpacity: backgroundImageOpacity,
            accent: accent,
            titleColor: titleColor,
            surface: surface,
            bubbleMine: bubbleMine,
            bubbleOther: bubbleOther
        )
    }

    static func from(_ theme: CoreChannelTheme?) -> ChannelThemeDraft {
        guard let theme else { return ChannelThemeDraft() }
        var draft = ChannelThemeDraft()
        draft.preset = theme.preset ?? "custom"
        draft.background = theme.background ?? draft.background
        draft.backgroundImage = theme.backgroundImage ?? ""
        draft.backgroundImageOpacity = theme.backgroundImageOpacity ?? draft.backgroundImageOpacity
        draft.accent = theme.accent ?? draft.accent
        draft.titleColor = theme.titleColor ?? draft.titleColor
        draft.surface = theme.surface ?? draft.surface
        draft.bubbleMine = theme.bubbleMine ?? draft.bubbleMine
        draft.bubbleOther = theme.bubbleOther ?? draft.bubbleOther
        return draft
    }
}

private extension Color {
    init(hexString: String) {
        let clean = hexString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        guard clean.count == 6, Scanner(string: clean).scanHexInt64(&value) else {
            self = .white
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var hexStringValue: String {
        var red: CGFloat = 1
        var green: CGFloat = 1
        var blue: CGFloat = 1
        var alpha: CGFloat = 1
        UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "#%02x%02x%02x",
            Int(round(min(max(red, 0), 1) * 255)),
            Int(round(min(max(green, 0), 1) * 255)),
            Int(round(min(max(blue, 0), 1) * 255))
        )
    }
}

private enum ChannelImageProcessor {
    static func dataURL(from data: Data, maxBytes: Int) -> String? {
        if data.count <= maxBytes, detectedMime(data) != nil {
            return "data:\(detectedMime(data) ?? "image/jpeg");base64,\(data.base64EncodedString())"
        }
        guard let image = UIImage(data: data) else { return nil }
        var maxDimension: CGFloat = 1024
        for _ in 0..<6 {
            let resized = resize(image, maxDimension: maxDimension)
            var quality: CGFloat = 0.8
            while quality >= 0.3 {
                if let jpeg = resized.jpegData(compressionQuality: quality), jpeg.count <= maxBytes {
                    return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
                }
                quality -= 0.15
            }
            maxDimension *= 0.7
        }
        return nil
    }

    static func image(fromDataURL dataURL: String) -> UIImage? {
        guard let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else {
            return nil
        }
        return UIImage(data: data)
    }

    private static func detectedMime(_ data: Data) -> String? {
        guard data.count > 3 else { return nil }
        let bytes = [UInt8](data.prefix(4))
        if bytes[0] == 0x89, bytes[1] == 0x50 { return "image/png" }
        if bytes[0] == 0xFF, bytes[1] == 0xD8 { return "image/jpeg" }
        if bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 { return "image/gif" }
        if data.count > 11, bytes[0] == 0x52, bytes[1] == 0x49 { return "image/webp" }
        return nil
    }

    private static func resize(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let largestSide = max(image.size.width, image.size.height)
        guard largestSide > maxDimension, largestSide > 0 else { return image }
        let scale = maxDimension / largestSide
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

private struct ChannelSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CoreChannelsStore
    /// nil = crear canal; con valor = configurar canal existente (paridad web).
    let editingChannel: CoreChannel?

    @State private var channelType = "text"
    @State private var name = ""
    @State private var description = ""
    @State private var visibility = CoreChannelVisibility.public
    @State private var businessUnitId: Int?
    @State private var didDefaultBusinessUnit = false
    @State private var businessUnitSearch = ""
    @State private var iconImage = ""
    @State private var iconPickerItem: PhotosPickerItem?
    @State private var backgroundPickerItem: PhotosPickerItem?
    @State private var theme = ChannelThemeDraft()
    @State private var memberSearch = ""
    @State private var memberIds: Set<String>
    @State private var adminIds: Set<String>
    @State private var imageError: String?
    @State private var isLoadingMembers = false
    @State private var inviteFeedback: String?
    @State private var isCreatingInvite = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false

    private let currentUserId: String

    private var isEditing: Bool { editingChannel != nil }

    init(store: CoreChannelsStore, editing channel: CoreChannel? = nil) {
        self.store = store
        editingChannel = channel
        let userId = store.configuration.userId
        currentUserId = userId
        _memberIds = State(initialValue: userId.isEmpty ? [] : [userId])
        _adminIds = State(initialValue: userId.isEmpty ? [] : [userId])

        if let channel {
            _channelType = State(initialValue: channel.isVoice ? "voice" : "text")
            _name = State(initialValue: channel.name)
            _description = State(initialValue: channel.description ?? "")
            _visibility = State(initialValue: channel.visibility)
            _businessUnitId = State(initialValue: channel.metadata?.businessUnitId)
            _didDefaultBusinessUnit = State(initialValue: true)
            _iconImage = State(initialValue: channel.metadata?.iconImage ?? "")
            _theme = State(initialValue: ChannelThemeDraft.from(channel.metadata?.theme))
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredBusinessUnits: [CoreInternalCompany] {
        let search = businessUnitSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !search.isEmpty else { return store.internalCompanies }
        return store.internalCompanies.filter { $0.name.lowercased().contains(search) }
    }

    private var filteredUsers: [CoreUserLite] {
        let search = memberSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !search.isEmpty else { return store.mentionableUsers }
        return store.mentionableUsers.filter { $0.displayName.lowercased().contains(search) }
    }

    var body: some View {
        NavigationStack {
            Form {
                if isEditing {
                    inviteLinkSection
                } else {
                    channelTypeSection
                }
                detailsSection
                businessUnitSection
                iconSection
                themeSection
                membersSection
                if let message = imageError ?? store.lastError {
                    Section {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                if isEditing {
                    deleteSection
                }
            }
            .navigationTitle(isEditing ? "Configurar canal" : "Crear canal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveButtonTitle) {
                        if isEditing {
                            saveChannel()
                        } else {
                            createChannel()
                        }
                    }
                    .disabled(trimmedName.isEmpty || store.isCreatingChannel || isDeleting)
                }
            }
            .task {
                await store.loadMentionableUsersIfNeeded()
                if store.internalCompanies.isEmpty {
                    await store.loadInternalCompanies()
                }
                applyDefaultBusinessUnitIfNeeded()
                await loadEditingState()
            }
            .onChange(of: store.internalCompanies) { _, _ in
                applyDefaultBusinessUnitIfNeeded()
            }
            .onChange(of: iconPickerItem) { _, item in
                guard let item else { return }
                loadPickedImage(item, maxBytes: 800_000, errorMessage: "El icono debe pesar menos de 800 KB") { dataURL in
                    iconImage = dataURL
                }
                iconPickerItem = nil
            }
            .onChange(of: backgroundPickerItem) { _, item in
                guard let item else { return }
                loadPickedImage(item, maxBytes: 1_500_000, errorMessage: "La imagen debe pesar menos de 1.5 MB para guardarse en el tema del canal") { dataURL in
                    theme.backgroundImage = dataURL
                    theme.preset = "custom"
                }
                backgroundPickerItem = nil
            }
        }
    }

    // MARK: - Secciones

    private var channelTypeSection: some View {
        Section("Tipo de canal") {
            channelTypeOption(
                type: "text",
                symbol: "number",
                title: "Texto",
                subtitle: "Chat con mensajes, archivos, threads, reacciones y herramientas Core."
            )
            channelTypeOption(
                type: "voice",
                symbol: "speaker.wave.2.fill",
                title: "Voz",
                subtitle: "Sala para hablar en vivo, compartir pantalla y ver participantes conectados."
            )
        }
    }

    private func channelTypeOption(type: String, symbol: String, title: String, subtitle: String) -> some View {
        Button {
            channelType = type
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(ZenitBrand.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: channelType == type ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(channelType == type ? ZenitBrand.accent : Color.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private var detailsSection: some View {
        Section("Canal") {
            TextField("Nombre del canal", text: $name)
            Picker("Visibilidad", selection: $visibility) {
                Text("Público").tag(CoreChannelVisibility.public)
                Text("Privado").tag(CoreChannelVisibility.private)
            }
            .pickerStyle(.segmented)
            TextField("Qué se coordina en este canal", text: $description, axis: .vertical)
                .lineLimit(2...4)
        }
    }

    private var businessUnitSection: some View {
        Section("Unidad de negocio") {
            TextField("Buscar unidad por nombre", text: $businessUnitSearch)
                .textInputAutocapitalization(.never)
            Picker("Unidad", selection: $businessUnitId) {
                Text("Sin unidad asignada").tag(Int?.none)
                ForEach(filteredBusinessUnits) { company in
                    Text(company.name).tag(Int?.some(company.id))
                }
            }
            if !businessUnitSearch.trimmingCharacters(in: .whitespaces).isEmpty, filteredBusinessUnits.isEmpty {
                Text("No encontramos unidades con ese nombre.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var iconSection: some View {
        Section {
            HStack(spacing: 12) {
                Group {
                    if let image = ChannelImageProcessor.image(fromDataURL: iconImage) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: channelType == "voice" ? "speaker.wave.2.fill" : "number")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 56, height: 56)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                PhotosPicker(selection: $iconPickerItem, matching: .images) {
                    Text(iconImage.isEmpty ? "Elegir imagen" : "Cambiar imagen")
                }

                Spacer()

                if !iconImage.isEmpty {
                    Button {
                        iconImage = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Icono del canal")
        } footer: {
            Text("Imagen cuadrada recomendada. Máximo 800 KB.")
        }
    }

    private var themeSection: some View {
        Section {
            Picker("Tema", selection: presetBinding) {
                ForEach(ChannelThemeDraft.presets, id: \.id) { preset in
                    Text(preset.name).tag(preset.id)
                }
                Text("Personalizado").tag("custom")
            }

            themePreview

            ColorPicker("Fondo", selection: themeColorBinding(\.background), supportsOpacity: false)
            ColorPicker("Acento", selection: themeColorBinding(\.accent), supportsOpacity: false)
            ColorPicker("Título", selection: themeColorBinding(\.titleColor), supportsOpacity: false)
            ColorPicker("Mensajes", selection: themeColorBinding(\.surface), supportsOpacity: false)
            ColorPicker("Mi burbuja", selection: themeColorBinding(\.bubbleMine), supportsOpacity: false)
            ColorPicker("Otra burbuja", selection: themeColorBinding(\.bubbleOther), supportsOpacity: false)

            HStack {
                PhotosPicker(selection: $backgroundPickerItem, matching: .images) {
                    Label(theme.backgroundImage.isEmpty ? "Imagen de fondo" : "Cambiar imagen de fondo", systemImage: "photo")
                }
                Spacer()
                if !theme.backgroundImage.isEmpty {
                    Button("Quitar") {
                        theme.backgroundImage = ""
                        theme.preset = "custom"
                    }
                    .foregroundStyle(.red)
                }
            }

            if !theme.backgroundImage.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Opacidad de imagen")
                        Spacer()
                        Text("\(Int(theme.backgroundImageOpacity))%")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    Slider(
                        value: Binding(
                            get: { theme.backgroundImageOpacity },
                            set: { newValue in
                                theme.backgroundImageOpacity = newValue.rounded()
                                theme.preset = "custom"
                            }
                        ),
                        in: 0...100,
                        step: 1
                    )
                }
            }
        } header: {
            Text("Tema del canal")
        } footer: {
            Text("Personaliza el fondo, acento y superficie de mensajes para este canal.")
        }
    }

    private var themePreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: channelType == "voice" ? "speaker.wave.2.fill" : "number")
                Text(trimmedName.isEmpty ? "nuevo-canal" : trimmedName)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color(hexString: theme.titleColor))

            VStack(alignment: .leading, spacing: 2) {
                Text("Mensaje del equipo")
                    .font(.caption.weight(.medium))
                Text("Así se verá una burbuja del equipo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(hexString: theme.bubbleOther))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)

            VStack(alignment: .leading, spacing: 2) {
                Text("Tu mensaje")
                    .font(.caption.weight(.medium))
                Text("Y así se verá tu burbuja.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(hexString: theme.bubbleMine))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                Color(hexString: theme.background)
                if let image = ChannelImageProcessor.image(fromDataURL: theme.backgroundImage) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .opacity(theme.backgroundImageOpacity / 100)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(hexString: theme.accent).opacity(0.4), lineWidth: 1)
        }
    }

    private var membersSection: some View {
        Section {
            TextField("Buscar personas por nombre", text: $memberSearch)
                .textInputAutocapitalization(.never)

            if isLoadingMembers {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Cargando miembros…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if store.mentionableUsers.isEmpty {
                Text("No hay usuarios disponibles para seleccionar.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if filteredUsers.isEmpty {
                Text("No encontramos personas con ese nombre.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filteredUsers) { person in
                    memberRow(person)
                }
            }
        } header: {
            HStack {
                Text("Miembros")
                Spacer()
                Text("\(memberIds.count) en el canal")
            }
        }
    }

    private func memberRow(_ person: CoreUserLite) -> some View {
        let isMember = memberIds.contains(person.id)
        let isAdmin = adminIds.contains(person.id)
        let locked = person.id == currentUserId

        return HStack(spacing: 10) {
            Button {
                toggleMember(person.id, isMember: isMember, locked: locked)
            } label: {
                Image(systemName: isMember ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isMember ? ZenitBrand.accent : Color.secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(locked)

            AvatarView(name: person.displayName, avatarURL: person.avatarURL)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(person.displayName)
                        .font(.subheadline)
                        .lineLimit(1)
                    if isAdmin {
                        Text("Admin")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(ZenitBrand.tealSoft)
                            .foregroundStyle(ZenitBrand.accent)
                            .clipShape(Capsule())
                    }
                }
                Text(locked ? "Admin actual" : (isMember ? "Miembro del canal" : "No incluido"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isMember {
                Button(isAdmin ? "Quitar admin" : "Hacer admin") {
                    toggleAdmin(person.id, isAdmin: isAdmin, locked: locked)
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(locked && isAdmin)
            }
        }
    }

    private var inviteLinkSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .foregroundStyle(ZenitBrand.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Link de invitación")
                        .font(.subheadline.weight(.semibold))
                    Text("Cualquier usuario de esta empresa con el link puede unirse a este canal.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    copyInviteLink()
                } label: {
                    if isCreatingInvite {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Copiar")
                            .font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isCreatingInvite)
            }
            if let inviteFeedback {
                Text(inviteFeedback)
                    .font(.caption)
                    .foregroundStyle(ZenitBrand.accent)
            }
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                HStack {
                    if isDeleting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "trash")
                    }
                    Text("Eliminar canal")
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(isDeleting)
            .confirmationDialog(
                "¿Eliminar el canal #\(trimmedName)? Dejará de aparecer para todos los usuarios.",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Eliminar canal", role: .destructive) {
                    deleteChannel()
                }
                Button("Cancelar", role: .cancel) {}
            }
        }
    }

    private var saveButtonTitle: String {
        if store.isCreatingChannel {
            return isEditing ? "Guardando…" : "Creando…"
        }
        return isEditing ? "Guardar" : "Crear"
    }

    // MARK: - Acciones

    private func loadEditingState() async {
        guard let channel = editingChannel else { return }
        isLoadingMembers = true
        // Miembros y admins actuales del canal.
        let roles = await store.loadChannelMemberRoles(channelId: channel.id)
        if !roles.isEmpty {
            memberIds = Set(roles.map(\.userId)).union(currentUserId.isEmpty ? [] : [currentUserId])
            adminIds = Set(roles.filter { $0.role == "admin" }.map(\.userId))
        }
        isLoadingMembers = false
        // La lista rápida no trae metadata: traemos la fresca para precargar
        // icono, tema y unidad reales.
        if channel.metadata == nil, let fresh = await store.fetchChannelMetadata(channel) {
            iconImage = fresh.iconImage ?? iconImage
            theme = ChannelThemeDraft.from(fresh.theme)
            businessUnitId = fresh.businessUnitId ?? businessUnitId
            channelType = fresh.channelType ?? channelType
        }
    }

    private func saveChannel() {
        guard let channel = editingChannel else { return }
        Task {
            let admins = adminIds.intersection(memberIds)
            let success = await store.updateChannel(
                channel,
                name: trimmedName,
                description: description,
                visibility: visibility,
                iconImage: iconImage.isEmpty ? nil : iconImage,
                theme: theme.coreTheme,
                businessUnitId: businessUnitId,
                memberIds: Array(memberIds),
                adminIds: Array(admins)
            )
            if success {
                dismiss()
            }
        }
    }

    private func deleteChannel() {
        guard let channel = editingChannel else { return }
        isDeleting = true
        Task {
            let success = await store.deleteChannel(channel)
            isDeleting = false
            if success {
                dismiss()
            }
        }
    }

    private func copyInviteLink() {
        guard let channel = editingChannel else { return }
        isCreatingInvite = true
        inviteFeedback = nil
        Task {
            if let link = await store.createChannelInviteLink(channel) {
                UIPasteboard.general.string = link
                inviteFeedback = "Link copiado al portapapeles."
            }
            isCreatingInvite = false
        }
    }

    private var presetBinding: Binding<String> {
        Binding(
            get: { theme.preset },
            set: { newValue in
                if newValue == "custom" {
                    theme.preset = "custom"
                } else {
                    // Igual que la web: el preset reemplaza todo el tema,
                    // incluida la imagen de fondo.
                    theme = ChannelThemeDraft.preset(newValue)
                }
            }
        )
    }

    private func themeColorBinding(_ keyPath: WritableKeyPath<ChannelThemeDraft, String>) -> Binding<Color> {
        Binding(
            get: { Color(hexString: theme[keyPath: keyPath]) },
            set: { newColor in
                theme[keyPath: keyPath] = newColor.hexStringValue
                theme.preset = "custom"
            }
        )
    }

    private func toggleMember(_ id: String, isMember: Bool, locked: Bool) {
        if isMember {
            guard !locked else { return }
            memberIds.remove(id)
            adminIds.remove(id)
        } else {
            memberIds.insert(id)
        }
    }

    private func toggleAdmin(_ id: String, isAdmin: Bool, locked: Bool) {
        guard memberIds.contains(id) else { return }
        if isAdmin {
            guard !locked else { return }
            let next = adminIds.subtracting([id])
            // Igual que la web: siempre debe quedar al menos un admin.
            guard !next.isEmpty else { return }
            adminIds = next
        } else {
            adminIds.insert(id)
        }
    }

    private func applyDefaultBusinessUnitIfNeeded() {
        guard !didDefaultBusinessUnit, !store.internalCompanies.isEmpty else { return }
        didDefaultBusinessUnit = true
        if let empresaId = store.configuration.empresaId,
           store.internalCompanies.contains(where: { $0.id == empresaId }) {
            businessUnitId = empresaId
        } else {
            businessUnitId = store.internalCompanies.first?.id
        }
    }

    private func loadPickedImage(
        _ item: PhotosPickerItem,
        maxBytes: Int,
        errorMessage: String,
        assign: @escaping (String) -> Void
    ) {
        Task {
            imageError = nil
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                imageError = "No se pudo cargar la imagen"
                return
            }
            if let dataURL = ChannelImageProcessor.dataURL(from: data, maxBytes: maxBytes) {
                assign(dataURL)
            } else {
                imageError = errorMessage
            }
        }
    }

    private func createChannel() {
        Task {
            let admins = adminIds.intersection(memberIds)
            await store.createChannel(
                name: trimmedName,
                description: description,
                visibility: visibility,
                channelType: channelType,
                iconImage: iconImage.isEmpty ? nil : iconImage,
                theme: theme.coreTheme,
                businessUnitId: businessUnitId,
                memberIds: Array(memberIds),
                adminIds: Array(admins)
            )
            if store.lastError == nil {
                dismiss()
            }
        }
    }
}

private struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CoreChannelsStore
    @State private var config: CoreAppConfiguration
    @State private var isTestingPush = false
    @State private var pushTestMessage: String?

    init(store: CoreChannelsStore) {
        self.store = store
        _config = State(initialValue: store.configuration)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Backend") {
                    TextField("Project URL", text: $config.supabaseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    SecureField("Anon key", text: $config.anonKey)
                    TextField("Convex URL", text: $config.convexURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }

                Section("Session") {
                    SecureField("Access token", text: $config.accessToken)
                    TextField("User ID", text: $config.userId)
                        .textInputAutocapitalization(.never)
                    TextField("Company ID", text: $config.empresaIdText)
                        .keyboardType(.numberPad)
                    TextField("Display name", text: $config.displayName)
                }

                Section("Push") {
                    Button {
                        testPush()
                    } label: {
                        HStack {
                            Label("Probar push", systemImage: "bell.badge")
                            Spacer()
                            if isTestingPush {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTestingPush || !store.configuration.isUsable)

                    if let pushTestMessage {
                        Text(pushTestMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text("ZiaChat uses Supabase only for login tokens and uses Convex for Core chat data.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Core Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.save(configuration: config)
                        Task { await store.refresh() }
                        dismiss()
                    }
                }
            }
        }
    }

    private func testPush() {
        isTestingPush = true
        pushTestMessage = nil
        Task {
            do {
                let configuration = try await store.ensureFreshSession()
                await PushNotificationService.shared.requestAuthorizationAndRegister()
                await PushNotificationService.shared.registerCurrentToken(configuration: configuration)
                let client = try ConvexCoreClient(configuration: configuration)
                let result = try await client.sendTestPush()
                await MainActor.run {
                    if result.sent > 0 {
                        pushTestMessage = "Push enviado (\(result.sent)/\(result.attempted))."
                    } else if let rejection = result.lastRejection {
                        let status = rejection.status.map { "HTTP \($0): " } ?? ""
                        pushTestMessage = "\(status)\(rejection.reason)"
                    } else {
                        pushTestMessage = "No se pudo enviar el push."
                    }
                    isTestingPush = false
                }
            } catch {
                await MainActor.run {
                    pushTestMessage = error.localizedDescription
                    isTestingPush = false
                }
            }
        }
    }
}

private struct ConfigurationBanner: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Connect Azank React Core", systemImage: "link.badge.plus")
                    .font(.headline)
                Text("Add Supabase auth, Convex URL, access token, user ID, and company ID.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.accentColor.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct AttachmentStrip: View {
    let attachments: [CoreAttachment]
    @State private var previewAttachment: CoreAttachment?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(attachments) { attachment in
                if attachment.isImage, let url = attachment.resolvedURL {
                    Button {
                        previewAttachment = attachment
                    } label: {
                        AttachmentMediaView(url: url, isGIF: attachment.isGIF)
                            .frame(width: 220, height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(alignment: .bottomLeading) {
                                Text(attachment.fileName)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .padding(6)
                                    .foregroundStyle(.white)
                                    .background(.black.opacity(0.65))
                            }
                    }
                    .buttonStyle(.plain)
                } else if attachment.isAudio, let url = attachment.resolvedURL {
                    AudioMessageView(url: url)
                } else {
                    Button {
                        previewAttachment = attachment
                    } label: {
                        Label(attachment.fileName, systemImage: attachment.systemImage)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.thinMaterial)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(attachment.resolvedURL == nil)
                }
            }
        }
        .fullScreenCover(item: $previewAttachment) { attachment in
            AttachmentViewerView(attachment: attachment)
        }
    }
}

private struct PendingAttachmentStrip: View {
    let attachments: [CorePendingAttachment]
    let isLoading: Bool
    let error: String?
    let onRemove: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        ZStack(alignment: .topTrailing) {
                            PendingAttachmentPreview(attachment: attachment)
                                .frame(width: 74, height: 74)
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                            Button {
                                onRemove(attachment.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.75))
                            }
                            .offset(x: 5, y: -5)
                            .accessibilityLabel("Remove attachment")
                        }
                    }

                    if isLoading {
                        ProgressView()
                            .frame(width: 74, height: 74)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
        }
    }
}

private struct AvatarView: View {
    let name: String
    let avatarURL: URL?
    var size: CGFloat = 30

    var body: some View {
        AsyncImage(url: avatarURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                Circle()
                    .fill(Color.accentColor.gradient)
                    .overlay {
                        Text(CoreFormat.initials(name))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

private struct CountBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color)
            .clipShape(Capsule())
    }
}

private struct EmptyChannelSelectionView: View {
    let isConfigured: Bool

    var body: some View {
        ContentUnavailableView(
            isConfigured ? "Choose a channel" : "Configure Core",
            systemImage: isConfigured ? "number" : "gearshape",
            description: Text(isConfigured ? "Open an Azank Core channel to start chatting." : "Save your backend settings to load channels from Azank React.")
        )
    }
}

private struct MissingChannelView: View {
    var body: some View {
        ContentUnavailableView("Channel unavailable", systemImage: "exclamationmark.bubble")
    }
}

#Preview {
    ContentView()
}
