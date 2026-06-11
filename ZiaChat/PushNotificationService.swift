import Combine
import UIKit
import UserNotifications

struct PushNotificationDestination: Equatable, Sendable {
    var channelId: String?
    var conversationId: String?
    var messageId: String?

    var isValid: Bool {
        channelId != nil || conversationId != nil
    }
}

@MainActor
final class PushNotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = PushNotificationService()

    @Published private(set) var deviceToken: String?
    @Published private(set) var pendingDestination: PushNotificationDestination?
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published var lastError: String?

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

    func consume(_ destination: PushNotificationDestination) {
        guard pendingDestination == destination else { return }
        pendingDestination = nil
    }

    func registerCurrentToken(configuration: CoreAppConfiguration) async {
        guard let deviceToken, configuration.isUsable else { return }

        do {
            let client = try SupabaseCoreClient(configuration: configuration)
            try await client.registerPushToken(
                token: deviceToken,
                deviceName: UIDevice.current.name
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound, .badge]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let destination = Self.destination(from: response.notification.request.content.userInfo)
        await MainActor.run {
            receive(destination: destination)
        }
        try? await center.setBadgeCount(0)
    }

    nonisolated private static func destination(from userInfo: [AnyHashable: Any]) -> PushNotificationDestination {
        PushNotificationDestination(
            channelId: stringValue(userInfo["channelId"] ?? userInfo["channel_id"]),
            conversationId: stringValue(userInfo["conversationId"] ?? userInfo["conversation_id"]),
            messageId: stringValue(userInfo["messageId"] ?? userInfo["message_id"])
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
