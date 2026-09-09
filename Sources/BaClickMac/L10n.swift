import Foundation

/// Minimal in-app i18n (no bundle resources needed with the raw-swiftc build).
/// Detects the system language once at launch; zh* -> Chinese, everything else
/// -> English.
enum L10n {
    /// Detect system language (Chinese variants => zh, otherwise en).
    static let isChinese: Bool = {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return code.hasPrefix("zh")
    }()

    /// Keyed strings: Chinese + English for every user-facing string.
    static let strings: [String: (zh: String, en: String)] = [
        // Panel title
        "panelTitle": ("BA Click 设置", "BA Click Settings"),

        // Toggles
        "enableEffects": ("启用效果", "Enable Effects"),
        "launchAtLogin": ("开机自启", "Launch at Login"),
        "trailAlwaysVisible": ("始终显示尾迹", "Always Show Trail"),
        "trailHelp": (
            "关闭后，仅在按下鼠标按钮并拖动时才有尾迹",
            "When off, the trail only appears while holding a mouse button and dragging"
        ),
        "rightClickEffect": ("右键点击效果", "Right-Click Effect"),
        "middleClickEffect": ("中键点击效果", "Middle-Click Effect"),
        "powerConnectedOnly": ("仅接通电源时启用", "Only When Plugged In"),
        "powerConnectedOnlyHelp": (
            "使用电池时自动关闭全部特效，把消耗降到最低",
            "Pause all effects while on battery power to keep the drain near zero"
        ),

        // Sliders
        "trailThickness": ("尾迹粗细", "Trail Thickness"),
        "trailGlow": ("尾迹辉光亮度", "Trail Glow Brightness"),
        "clickSize": ("点击效果大小", "Click Effect Size"),
        "clickBrightness": ("点击效果亮度", "Click Brightness"),
        // 不透明度: higher value = more opaque (matches the 0...1 slider logic).
        "clickDiskOpacity": ("点击圆盘不透明度", "Click Disk Opacity"),
        "triangleOpacity": ("三角粒子不透明度", "Triangle Opacity"),
        "refreshRate": ("效果刷新率", "Refresh Rate"),

        // Menu bar
        "openPanel": ("打开管理面板", "Open Management Panel"),
        "quit": ("退出 BA Click", "Quit BA Click"),

        // Updates + GitHub
        "checkForUpdates": ("检查更新", "Check for Updates"),
        "openGitHub": ("GitHub 仓库", "GitHub Repo"),
        "checkingUpdates": ("正在检查更新…", "Checking for updates…"),
        "upToDate": ("%@ 已是最新版本", "%@ — You're up to date"),
        "updateAvailable": ("发现新版本", "Update available"),
        "autoUpdateCheck": ("自动检测更新", "Check for Updates Automatically"),
        "autoUpdateCheckHelp": (
            "每次启动软件和打开面板时检查一次",
            "Checks once at launch and each time the panel opens"
        ),
        "updateNow": ("立即更新", "Update Now"),
        "downloadingUpdate": ("正在下载更新", "Downloading update"),
        "installingUpdate": ("正在更新，即将重启…", "Updating, restarting…"),
        "updateCheckFailed": ("检查更新失败", "Update check failed"),
        "updateNotPossible": ("无法自动更新，已打开 GitHub Releases", "Auto-update unavailable — opened GitHub Releases"),
        "updateDownloadFailed": ("更新下载失败，已打开 GitHub Releases", "Download failed — opened GitHub Releases"),
        "updateMountFailed": ("更新安装失败，已打开 GitHub Releases", "Install failed — opened GitHub Releases"),
    ]

    /// Localized string for `key` in the detected language.
    static func t(_ key: String) -> String {
        guard let pair = strings[key] else { return key }
        return isChinese ? pair.zh : pair.en
    }

    /// "v0.2.2 已是最新版本" — the "upToDate" entry is a "%@" template; the
    /// RUNNING version is substituted here (a beta/dev build is "up to date"
    /// while newer than the release feed, and the label must reflect what is
    /// actually running, not the release feed).
    static func upToDateLabel(currentVersion: String) -> String {
        t("upToDate").replacingOccurrences(
            of: "%@",
            with: "v\(currentVersion)"
        )
    }
}
