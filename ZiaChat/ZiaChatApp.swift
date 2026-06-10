//
//  ZiaChatApp.swift
//  ZiaChat
//
//  Created by Ingeniero on 9/6/26.
//

import SwiftUI

@main
struct ZiaChatApp: App {
    @UIApplicationDelegateAdaptor(ZiaChatAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
