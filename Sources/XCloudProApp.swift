import SwiftUI

@main
struct XCloudProApp: App {
    @StateObject private var controllerManager = ControllerManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(controllerManager)
                .preferredColorScheme(.dark)
        }
    }
}
