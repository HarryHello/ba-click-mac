import AppKit
import SwiftUI

/// Management panel (Apple native controls) opened from the menu bar icon.
struct SettingsPanelView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("启用效果", isOn: store.binding(\.enabled))
                .toggleStyle(.switch)
                .controlSize(.small)
            Toggle("开机自启", isOn: $store.launchAtLogin)
                .toggleStyle(.switch)
                .controlSize(.small)
            Toggle("始终显示尾迹", isOn: store.binding(\.trailAlwaysVisible))
                .toggleStyle(.switch)
                .controlSize(.small)
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
                Button("退出 BA Click") { NSApp.terminate(nil) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .padding(.top, 8)
        .frame(width: 330)
    }

    private func slider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        HStack {
            Text(title)
                .frame(width: 120, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }
}

/// Hosts the SwiftUI panel in a borderless, rounded, frosted-glass NSPanel
/// with a custom draggable header (a transparent window breaks the native
/// title bar, so we draw our own). The app never becomes frontmost, so the
/// global mouse monitor keeps feeding the overlay while the panel is used.
final class SettingsPanelController: NSObject {
    private let store: SettingsStore
    private var panel: NSPanel?
    private let headerHeight: CGFloat = 40
    private let cornerRadius: CGFloat = 14

    init(store: SettingsStore) {
        self.store = store
        super.init()

        let hosting = NSHostingView(rootView: SettingsPanelView(store: store))
        let contentFitting = hosting.fittingSize
        let size = NSSize(
            width: max(330, contentFitting.width),
            height: headerHeight + contentFitting.height
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)

        // Rounded container: also gives the window shadow a rounded shape.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height))
        container.wantsLayer = true
        container.layer?.cornerRadius = cornerRadius
        container.layer?.masksToBounds = true

        // Frosted-glass background (light material = more transparent).
        let visual = NSVisualEffectView(frame: container.bounds)
        visual.material = .popover
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.isEmphasized = true
        visual.autoresizingMask = [.width, .height]
        container.addSubview(visual)

        // Custom draggable header (transparent windows have no usable title bar).
        let header = PanelDragView(frame: NSRect(
            x: 0, y: container.bounds.height - headerHeight,
            width: container.bounds.width, height: headerHeight
        ))
        header.autoresizingMask = [.width, .minYMargin]

        let title = NSTextField(labelWithString: "BA Click 设置")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white
        title.frame = NSRect(x: 14, y: (headerHeight - 16) / 2, width: 180, height: 16)
        header.addSubview(title)

        let closeButton = NSButton(title: "✕", target: self, action: #selector(closePanel))
        closeButton.isBordered = false
        closeButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        closeButton.contentTintColor = .white
        closeButton.frame = NSRect(
            x: container.bounds.width - 34, y: (headerHeight - 20) / 2,
            width: 24, height: 20
        )
        closeButton.autoresizingMask = [.minXMargin]
        header.addSubview(closeButton)

        container.addSubview(header)

        // SwiftUI content below the header.
        hosting.frame = NSRect(
            x: 0, y: 0,
            width: container.bounds.width,
            height: container.bounds.height - headerHeight
        )
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        panel.contentView = container
        self.panel = panel
    }

    @objc private func closePanel() {
        close()
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

/// Header view that drags the borderless panel.
final class PanelDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
