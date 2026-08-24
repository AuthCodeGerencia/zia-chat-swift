import Observation
import UIKit
import UserNotifications

struct PushNotificationDestination: Equatable, Sendable {
    var channelId: String?
    var conversationId: String?
    var messageId: String?
    /// Chat de WhatsApp (push del portal de AuthCode vía el puente de Zia).
    var whatsAppChatId: String?

    nonisolated var isValid: Bool {
        channelId != nil || conversationId != nil || whatsAppChatId != nil
    }
}

struct ForegroundPushNotificationEvent: Equatable, Sendable {
    let id = UUID()
    var destination: PushNotificationDestination
}

@Observable
@MainActor
final class PushNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushNotificationService()

    private(set) var deviceToken: String?
    private(set) var pendingDestination: PushNotificationDestination?
    private(set) var foregroundEvent: ForegroundPushNotificationEvent?
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    var lastError: String?
    /// La app se lanzó al tocar una notificación: el NavigationStack aún se
    /// está restaurando cuando llega el tap, así que ese caso espera un poco.
    @ObservationIgnored var launchedFromNotification = false
    /// En apps con escenas el tap que arranca la app suele llegar sin
    /// launchOptions; la antigüedad del proceso cubre ese caso.
    @ObservationIgnored private let launchDate = Date()

    private override init() {
        super.init()
    }

    func configure() {
        UNUserNotificationCenter.current().delegate = self
        Task {
            authorizationStatus = await UNUserNotificationCenter.current()
                .notificationSettings()
                .authorizationStatus
        }
    }

    func requestAuthorizationAndRegister() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            authorizationStatus = granted ? .authorized : .denied
            guard granted else { return }
            UIApplication.shared.registerForRemoteNotifications()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func didRegister(deviceToken data: Data) {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        lastError = nil
    }

    func didFailToRegister(error: Error) {
        lastError = error.localizedDescription
    }

    func receive(userInfo: [AnyHashable: Any]) {
        receive(destination: Self.destination(from: userInfo))
    }

    func receive(destination: PushNotificationDestination) {
        guard destination.isValid else {
            lastError = "This notification does not contain a chat destination."
            return
        }
        pendingDestination = destination
    }

    func receiveForeground(destination: PushNotificationDestination) {
        guard destination.isValid else { return }
        foregroundEvent = ForegroundPushNotificationEvent(destination: destination)
    }

    func consume(_ destination: PushNotificationDestination) {
        guard pendingDestination == destination else { return }
        pendingDestination = nil
    }

    func registerCurrentToken(configuration: CoreAppConfiguration) async {
        guard let deviceToken, configuration.isUsable, !ZiaDemoMode.isEnabled else { return }

        do {
            let client = try ConvexCoreClient(configuration: configuration)
            try await client.registerPushToken(
                token: deviceToken,
                deviceName: UIDevice.current.name
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func unregisterCurrentUser(configuration: CoreAppConfiguration) async {
        guard configuration.isUsable else {
            await updateBadgeCount(0)
            return
        }
        if let client = try? ConvexCoreClient(configuration: configuration) {
            try? await client.unregisterPushTokens()
        }
        await updateBadgeCount(0)
    }

    func updateBadgeCount(_ count: Int) async {
        try? await UNUserNotificationCenter.current().setBadgeCount(max(0, count))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Canales silenciados por el usuario: sin banner ni sonido.
        let destination = Self.destination(from: notification.request.content.userInfo)
        if destination.isValid {
            Task { await PushNotificationService.shared.receiveForeground(destination: destination) }
        }
        let muted = Set(UserDefaults.standard.stringArray(forKey: "zia.mutedChannelIds") ?? [])
        if let channelId = destination.channelId, muted.contains(channelId) {
            return [.list]
        }
        if let conversationId = destination.conversationId, muted.contains(conversationId) {
            return [.list]
        }
        return [.banner, .list, .sound, .badge]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let destination = Self.destination(from: response.notification.request.content.userInfo)
        completionHandler()

        Task { @MainActor in
            let service = PushNotificationService.shared
            if service.launchedFromNotification || Date().timeIntervalSince(service.launchDate) < 2 {
                service.launchedFromNotification = false
                try? await Task.sleep(for: .milliseconds(750))
            }
            service.receive(destination: destination)
        }
    }

    nonisolated private static func destination(from userInfo: [AnyHashable: Any]) -> PushNotificationDestination {
        PushNotificationDestination(
            channelId: stringValue(userInfo["channelId"] ?? userInfo["channel_id"]),
            conversationId: stringValue(userInfo["conversationId"] ?? userInfo["conversation_id"]),
            messageId: stringValue(userInfo["messageId"] ?? userInfo["message_id"]),
            whatsAppChatId: stringValue(userInfo["chatId"] ?? userInfo["chat_id"])
        )
    }

    nonisolated private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = value as? UUID {
            return value.uuidString
        }
        return nil
    }
}

@MainActor
final class ZiaChatAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PushNotificationService.shared.configure()
        PushNotificationService.shared.launchedFromNotification =
            launchOptions?[.remoteNotification] != nil
        Task {
            try? await UNUserNotificationCenter.current().setBadgeCount(0)
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            PushNotificationService.shared.didRegister(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            PushNotificationService.shared.didFailToRegister(error: error)
        }
    }
}
