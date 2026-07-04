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
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
