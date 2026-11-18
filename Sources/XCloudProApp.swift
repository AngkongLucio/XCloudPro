import SwiftUI

@main
struct XCloudProApp: App {
    @StateObject private var controllerManager: ControllerManager
    @StateObject private var authenticationService: XboxAuthenticationService
    @StateObject private var appModel: XboxCloudAppModel

    init() {
        let controller = ControllerManager()
        let authentication = XboxAuthenticationService()
        _controllerManager = StateObject(wrappedValue: controller)
        _authenticationService = StateObject(wrappedValue: authentication)
        _appModel = StateObject(
            wrappedValue: XboxCloudAppModel(
                authenticationService: authentication,
                controllerManager: controller
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(controllerManager)
                .environmentObject(authenticationService)
                .environmentObject(appModel)
                .preferredColorScheme(.dark)
        }
    }
}
