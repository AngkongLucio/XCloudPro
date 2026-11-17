import SwiftUI

@main
struct XCloudProApp: App {
    @StateObject private var controllerManager = ControllerManager()
    @StateObject private var authenticationService = XboxAuthenticationService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(controllerManager)
                .environmentObject(authenticationService)
                .preferredColorScheme(.dark)
        }
    }
}
