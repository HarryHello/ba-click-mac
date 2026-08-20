import AppKit
import SwiftUI

/// Management panel (Apple native controls) opened from the menu bar icon.
struct SettingsPanelView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("启用效果", isOn: store.binding(\.enabled))
            Toggle("开机自启", isOn: $store.launchAtLogin)
            Toggle("始终显示尾迹", isOn: store.binding(\.trailAlwaysVisible))
                .help("关闭后，仅在按下左键并拖动时才有尾迹")

            Divider()

            slider("尾迹粗细", value: store.binding(\.trailScale), range: 0.5...5.0)
            slider("尾迹辉光亮度", value: store.binding(\.trailBloomStrength), range: 0...8.0)
            slider("点击效果大小", value: store.clickScaleBinding(), range: 0.4...1.6)
            slider("点击效果亮度", value: store.binding(\.clickBrightness), range: 0...3.0)
            slider("点击圆盘透明度", value: store.binding(\.clickDiskOpacity), range: 0...1.0)
            slider("三角粒子透明度", value: store.binding(\.triangleOpacity), range: 0...1.0)

            Divider()

            HStack {
                Text("效果刷新率")
                Spacer()
                Picker("效果刷新率", selection: store.binding(\.refreshRate)) {
                    Text("30").tag(30)
                    Text("60").tag(60)
                    Text("120").tag(120)
                    Text("240").tag(240)
                }
                .labelsHidden()
                .frame(width: 90)
            }

            Divider()

            HStack {
                Spacer()
                Button("退出 ba-click") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 330)
    }

    private func slider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        HStack {
            Text(title)
                .frame(width: 120, alignment: .leading)
            Slider(value: value, in: range)
        }
    }
}

/// Hosts the SwiftUI panel in a non-activating NSPanel, so the app never
/// becomes frontmost and the global mouse monitor keeps feeding the overlay
/// while the panel is being used.
final class SettingsPanelController {
    private let store: SettingsStore
    private var panel: NSPanel?
    private let panelSize = NSSize(width: 360, height: 460)

    init(store: SettingsStore) {
        self.store = store
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "ba-click 设置"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: SettingsPanelView(store: store))
        let fitting = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: fitting)
        panel.setContentSize(fitting)
        panel.contentView = hosting
        self.panel = panel
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? close() : show()
    }

    func show() {
        guard let panel else { return }
        // Place just below the menu bar, near the top-right (where the status
        // item lives), on the current screen.
        let screen = panel.screen ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameTopLeftPoint(NSPoint(
                x: frame.maxX - size.width - 8,
                y: frame.maxY + 4
            ))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }
}
