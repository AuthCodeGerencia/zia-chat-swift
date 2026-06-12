import UIKit
import SwiftUI

/// Punto de entrada de la Share Extension (compartir desde WhatsApp, Fotos,
/// Archivos, etc.). Hospeda la UI SwiftUI del selector de canal.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let root = ShareComposerView(
            extensionItems: items,
            onFinish: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            },
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(
                    withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
                )
            }
        )

        let host = UIHostingController(rootView: root)
        addChild(host)
        view.addSubview(host.view)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.didMove(toParent: self)
    }
}
