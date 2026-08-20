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
            "关闭后，仅在按下左键并拖动时才有尾迹",
            "When off, the trail only appears while holding the left button and dragging"
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
    ]

    /// Localized string for `key` in the detected language.
    static func t(_ key: String) -> String {
        guard let pair = strings[key] else { return key }
        return isChinese ? pair.zh : pair.en
    }
}
