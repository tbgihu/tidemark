import ServiceManagement

/// Open at Login, through the system's login items. On by default: Tidemark registers itself on its first launch
/// only, so turning it off in Settings or System Settings sticks.
@MainActor
enum LoginItem {
    static var service: SMAppService { .mainApp }

    static var enabled: Bool { service.status == .enabled }
    static var needsApproval: Bool { service.status == .requiresApproval }

    static func registerOnFirstLaunch() {
        guard !Preferences.loginItemInitialized else { return }
        Preferences.loginItemInitialized = true
        try? service.register()
    }

    static func set(_ on: Bool) {
        if on { try? service.register() } else { try? service.unregister() }
    }
}
