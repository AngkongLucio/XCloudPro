import Foundation
import GameController

@MainActor
final class ControllerManager: ObservableObject {
    @Published private(set) var connectedControllers: [String] = []

    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(controllerDidChange(_:)), name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(controllerDidChange(_:)), name: .GCControllerDidDisconnect, object: nil)
        GCController.startWirelessControllerDiscovery(completionHandler: {})
        refreshControllers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var statusText: String {
        connectedControllers.isEmpty ? "No controller connected" : "\(connectedControllers.count) controller(s) connected"
    }

    @objc private func controllerDidChange(_ notification: Notification) {
        refreshControllers()
    }

    private func refreshControllers() {
        connectedControllers = GCController.controllers().map { controller in
            let name = controller.vendorName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (name?.isEmpty == false ? name! : "Game Controller")
        }
    }
}
