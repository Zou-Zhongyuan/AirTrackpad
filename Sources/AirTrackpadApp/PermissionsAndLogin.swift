import AppKit
import ApplicationServices
import Foundation
import ServiceManagement

public enum LoginItemState: Equatable, Sendable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable(String)
}

public enum PermissionsAndLogin {
    public static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    @MainActor
    public static func requestAccessibilityPrompt(openSystemSettings: Bool = true) {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if openSystemSettings,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    public static func loginItemState() -> LoginItemState {
        let status = SMAppService.mainApp.status
        switch status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .disabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            let path = Bundle.main.bundlePath
            let inApplications = path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
            if inApplications {
                return .disabled
            }
            return .unavailable("请先将 AirTrackpad.app 安装到“应用程序”目录")
        @unknown default:
            return .disabled
        }
    }

    public static func setLoginItemEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    @MainActor
    public static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
