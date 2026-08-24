import SwiftUI
import UIKit

/// Última altura conocida del teclado (sin el inset inferior seguro) para que
/// los paneles del compositor midan lo mismo que el teclado y el intercambio
/// teclado ↔ panel no mueva la lista dos veces.
@Observable
@MainActor
final class KeyboardObserver {
    static let shared = KeyboardObserver()

    private(set) var lastHeight: CGFloat?
    @ObservationIgnored private var observation: Task<Void, Never>?

    private init() {
        observation = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: UIResponder.keyboardWillShowNotification
            )
            for await notification in notifications {
                let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?
                    .cgRectValue
                guard let self, let frame else { continue }
                self.record(keyboardFrame: frame)
            }
        }
    }

    private func record(keyboardFrame frame: CGRect) {
        let bottomInset = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow?.safeAreaInsets.bottom ?? 0
        let height = frame.height - bottomInset
        // Un teclado físico solo muestra la barra de sugerencias; no sirve
        // como medida para los paneles.
        guard height >= 150 else { return }
        if lastHeight != height {
            lastHeight = height
        }
    }
}
