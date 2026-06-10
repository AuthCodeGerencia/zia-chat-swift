import Combine
import UIKit
import UserNotifications

@MainActor
final class PushNotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = PushNotificationService()

    @Published private(set) var deviceToken: String?
    @Published var pendingChannelId: String?
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
        let channelId = response.notification.request.content.userInfo["channelId"] as? String
        await MainActor.run {
            pendingChannelId = channelId
        }
        try? await center.setBadgeCount(0)
    }
}

final class ZiaChatAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Task { @MainActor in
            PushNotificationService.shared.configure()
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
