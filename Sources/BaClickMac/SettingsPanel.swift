import AppKit
import SwiftUI

/// Management panel (Apple native controls) opened from the menu bar icon.
struct SettingsPanelView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(L10n.t("enableEffects"), isOn: store.binding(\.enabled))
                .toggleStyle(.switch)
                .controlSize(.small)
            Toggle(L10n.t("launchAtLogin"), isOn: $store.launchAtLogin)
                .toggleStyle(.switch)
                .controlSize(.small)
            Toggle(L10n.t("trailAlwaysVisible"), isOn: store.binding(\.trailAlwaysVisible))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(L10n.t("trailHelp"))

            Divider()

            slider(L10n.t("trailThickness"), value: store.binding(\.trailScale), range: 0.5...5.0)
            slider(L10n.t("trailGlow"), value: store.binding(\.trailBloomStrength), range: 0...8.0)
            slider(L10n.t("clickSize"), value: store.clickScaleBinding(), range: 0.4...1.6)
            slider(L10n.t("clickBrightness"), value: store.binding(\.clickBrightness), range: 0...3.0)
            slider(L10n.t("clickDiskOpacity"), value: store.binding(\.clickDiskOpacity), range: 0...1.0)
            slider(L10n.t("triangleOpacity"), value: store.binding(\.triangleOpacity), range: 0...1.0)

            Divider()

            HStack {
                Text(L10n.t("refreshRate"))
                Spacer()
                Picker(L10n.t("refreshRate"), selection: store.binding(\.refreshRate)) {
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
                Button(L10n.t("quit")) { NSApp.terminate(nil) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .padding(.top, 30) // clear the native traffic lights (fullSizeContentView)
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

/// Hosts the SwiftUI panel in a titled NSPanel with a frosted-glass body.
/// `titlebarAppearsTransparent` + `fullSizeContentView` keep the native
/// traffic lights (red/yellow/green) and title-bar dragging while the window
/// itself stays transparent so the glass blur shows through. The panel is
/// non-activating, so the app never becomes frontmost and the global mouse
/// monitor keeps feeding the overlay while the panel is used.
final class SettingsPanelController: NSObject {
    private let store: SettingsStore
    private var panel: NSPanel?
    private let cornerRadius: CGFloat = 14

    init(store: SettingsStore) {
        self.store = store
        super.init()

        let hosting = NSHostingView(rootView: SettingsPanelView(store: store))
        let contentFitting = hosting.fittingSize
        let size = NSSize(
            width: max(330, contentFitting.width),
            height: contentFitting.height + 10
        )
        let contentRect = NSRect(x: 0, y: 0, width: size.width, height: size.height)

        let panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.t("panelTitle")
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
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

        // Native Liquid Glass body (NSGlassEffectView, macOS 26+), falling back
        // to classic vibrancy on older systems.
        hosting.frame = contentRect
        hosting.autoresizingMask = [.width, .height]

        let root: NSView
        if let glass = Self.makeGlassEffectView(frame: contentRect, cornerRadius: cornerRadius, content: hosting) {
            root = glass
        } else {
            // Fallback: rounded NSVisualEffectView (.menu material) + content.
            let container = NSView(frame: contentRect)
            container.wantsLayer = true
            container.layer?.cornerRadius = cornerRadius
            container.layer?.masksToBounds = true
            let visual = NSVisualEffectView(frame: container.bounds)
            visual.material = .menu
            visual.blendingMode = .behindWindow
            visual.state = .active
            visual.isEmphasized = true
            visual.autoresizingMask = [.width, .height]
            container.addSubview(visual)
            hosting.frame = container.bounds
            container.addSubview(hosting)
            root = container
        }

        panel.contentView = root
        self.panel = panel
    }

    /// Creates the native `NSGlassEffectView` via runtime lookup so this builds
    /// against SDKs that don't declare it (e.g. CommandLineTools) yet. Returns
    /// nil on macOS < 26 or if the class is missing — callers fall back.
    private static func makeGlassEffectView(
        frame: NSRect,
        cornerRadius: CGFloat,
        content: NSView
    ) -> NSView? {
        guard #available(macOS 26.0, *),
              let cls = NSClassFromString("NSGlassEffectView") as? NSView.Type else {
            return nil
        }
        let glass = cls.init(frame: frame)
        glass.autoresizingMask = [.width, .height]
        if glass.responds(to: Selector(("setCornerRadius:"))) {
            glass.setValue(NSNumber(value: Double(cornerRadius)), forKey: "cornerRadius")
        }
        if glass.responds(to: Selector(("setContentView:"))) {
            glass.setValue(content, forKey: "contentView")
        }
        // Interactive glass (macOS 27+): subtle visual response to interaction.
        if glass.responds(to: Selector(("setEffectIsInteractive:"))) {
            glass.setValue(true, forKey: "effectIsInteractive")
        }
        return glass
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
