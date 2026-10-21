import ServiceManagement

/// 登录时打开。首次从「应用程序」启动时默认开启一次，之后以系统设置里的状态为准
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// 用户在系统设置里关掉过时注册后仍要求批准（不一定报错），这时打开登录项设置页
    static func set(_ enabled: Bool) {
        if enabled { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        if enabled, SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    /// 只在已拖进「应用程序」时开启，避免从 DMG 或 Xcode 编译目录运行时登记临时路径
    static func enableOnFirstLaunch() {
        let key = "loginItemEnabledOnce"
        guard !UserDefaults.standard.bool(forKey: key), Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        UserDefaults.standard.set(true, forKey: key)
        set(true)
    }
}
