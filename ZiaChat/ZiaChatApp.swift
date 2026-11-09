//
//  ZiaChatApp.swift
//  ZiaChat
//
//  Created by Ingeniero on 9/6/26.
//

import ConvexMobile
import SwiftUI

@main
struct ZiaChatApp: App {
    @UIApplicationDelegateAdaptor(ZiaChatAppDelegate.self) private var appDelegate

    init() {
        #if DEBUG
        initConvexLogging()
        #endif
        // Se crea aquí, fuera del `body` de la escena: si naciera durante su
        // evaluación, las lecturas del `init` del store quedarían registradas
        // como dependencias de la escena y cada cambio la reevaluaría entera.
        _ = ContentView.sharedStore
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
