import Combine
import Foundation
import GameController

struct XboxGamepadState: Equatable {
    var buttons: UInt16 = 0
    var leftTrigger: UInt16 = 0
    var rightTrigger: UInt16 = 0
    var leftX: Int16 = 0
    var leftY: Int16 = 0
    var rightX: Int16 = 0
    var rightY: Int16 = 0

    static let neutral = XboxGamepadState()
}

@MainActor
final class ControllerManager: ObservableObject {
    @Published private(set) var connectedControllers: [String] = []
    var onGamepadStateChanged: ((XboxGamepadState) -> Void)?
    var onControllerConnectionChanged: ((Bool) -> Void)?
    private var lastReportedControllerConnection: Bool?

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
        let controllers = GCController.controllers()
        connectedControllers = controllers.map { controller in
            let name = controller.vendorName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (name?.isEmpty == false ? name! : "Game Controller")
        }

        let hasExtendedController = controllers.contains { $0.extendedGamepad != nil }
        if lastReportedControllerConnection != hasExtendedController {
            lastReportedControllerConnection = hasExtendedController
            onControllerConnectionChanged?(hasExtendedController)
        }

        for controller in controllers {
            controller.extendedGamepad?.valueChangedHandler = { [weak self, weak controller] _, _ in
                guard let controller else { return }
                Task { @MainActor in self?.publishState(from: controller) }
            }
        }
        if let primary = controllers.first(where: { $0.extendedGamepad != nil }) {
            publishState(from: primary)
        } else {
            onGamepadStateChanged?(.neutral)
        }
    }

    private func publishState(from controller: GCController) {
        guard let gamepad = controller.extendedGamepad else {
            onGamepadStateChanged?(.neutral)
            return
        }

        var mask: UInt16 = 0
        if gamepad.buttonHome?.isPressed == true { mask |= 1 << 1 } // Nexus
        if gamepad.buttonMenu.isPressed { mask |= 1 << 2 } // Menu
        if gamepad.buttonOptions?.isPressed == true { mask |= 1 << 3 } // View
        if gamepad.buttonA.isPressed { mask |= 1 << 4 }
        if gamepad.buttonB.isPressed { mask |= 1 << 5 }
        if gamepad.buttonX.isPressed { mask |= 1 << 6 }
        if gamepad.buttonY.isPressed { mask |= 1 << 7 }
        if gamepad.dpad.up.isPressed { mask |= 1 << 8 }
        if gamepad.dpad.down.isPressed { mask |= 1 << 9 }
        if gamepad.dpad.left.isPressed { mask |= 1 << 10 }
        if gamepad.dpad.right.isPressed { mask |= 1 << 11 }
        if gamepad.leftShoulder.isPressed { mask |= 1 << 12 }
        if gamepad.rightShoulder.isPressed { mask |= 1 << 13 }
        if gamepad.leftThumbstickButton?.isPressed == true { mask |= 1 << 14 }
        if gamepad.rightThumbstickButton?.isPressed == true { mask |= 1 << 15 }

        onGamepadStateChanged?(
            XboxGamepadState(
                buttons: mask,
                leftTrigger: Self.normalizedTrigger(gamepad.leftTrigger.value),
                rightTrigger: Self.normalizedTrigger(gamepad.rightTrigger.value),
                leftX: Self.normalizedAxis(gamepad.leftThumbstick.xAxis.value),
                leftY: Self.normalizedAxis(gamepad.leftThumbstick.yAxis.value),
                rightX: Self.normalizedAxis(gamepad.rightThumbstick.xAxis.value),
                rightY: Self.normalizedAxis(gamepad.rightThumbstick.yAxis.value)
            )
        )
    }

    private static func normalizedAxis(_ value: Float) -> Int16 {
        let clamped = max(-1, min(1, value))
        return Int16(clamped * 32_767)
    }

    private static func normalizedTrigger(_ value: Float) -> UInt16 {
        let clamped = max(0, min(1, value))
        return UInt16(clamped * 65_535)
    }
}
