import AppKit
import GlassStatsCore

@MainActor
final class StatusBar: NSObject {
    private var item: NSStatusItem?
    private let coordinator: AppCoordinator

    init(coordinator: AppCoordinator) { self.coordinator = coordinator }

    func update(model: AppModel) {
        let prefs = model.preferences
        guard prefs.menuBar else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        if item == nil {
            let new = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            new.autosaveName = "GlassStats"
            new.button?.target = self
            new.button?.action = #selector(pressed)
            new.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            new.button?.imagePosition = .imageLeading
            new.button?.toolTip = "GlassStats · Click to toggle dashboard · Right-click for options"
            item = new
        }
        guard let button = item?.button else { return }
        let data = model.snapshot
        let parts = prefs.menuMetrics.filter(prefs.isEnabled)
            .prefix(prefs.lowDensity ? 2 : 4)
            .compactMap { reading($0, data: data, mode: prefs.readoutMode, lowDensity: prefs.lowDensity) }
        let title = parts.map(\.title).joined(separator: "   ")
        let help = parts.map(\.description).joined(separator: ", ")
        if (button.attributedTitle.string != title) || (title.isEmpty && button.image == nil) {
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            ])
            button.image = title.isEmpty ? NSImage(systemSymbolName: "waveform.path", accessibilityDescription: "GlassStats") : nil
        }
        let accessibilityTitle = help.isEmpty ? "GlassStats" : "GlassStats. \(help)"
        if button.accessibilityLabel() != accessibilityTitle { button.setAccessibilityLabel(accessibilityTitle) }
    }

    var isPresent: Bool { item?.button != nil }
    var accessibleTitle: String? { item?.button?.accessibilityLabel() }

    @objc private func pressed() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            guard let button = item?.button else { return }
            let menu = coordinator.actionMenu(title: "GlassStats")
            if let event = NSApp.currentEvent { NSMenu.popUpContextMenu(menu, with: event, for: button) }
        } else {
            coordinator.toggleDashboard()
        }
    }

    private func reading(_ metric: Metric, data: TelemetrySnapshot, mode: ReadoutMode, lowDensity: Bool)
    -> (title: String, description: String)? {
        let compact: String
        let label: String
        let glyph: String
        var points: [HistoryPoint] = []
        var ceiling: Double = 1
        switch metric {
        case .cpu:
            guard let cpu = data.cpu else { return nil }
            compact = Display.percent(cpu.total); label = "CPU"; glyph = "◫"
            if mode == .graph { points = data.history.cpu.values }
        case .memory:
            guard let memory = data.memory else { return nil }
            compact = lowDensity ? Display.percent(memory.fraction) : Display.bytes(memory.used)
            label = "RAM"; glyph = "▤"
            if mode == .graph { points = data.history.memory.values }
        case .network:
            guard let rate = data.network?.rate else { return nil }
            let down = Display.rate(rate.down)
            compact = lowDensity ? down : "↓\(down) ↑\(Display.rate(rate.up))"
            label = "NET"; glyph = "↕"
            if mode == .graph {
                points = data.history.down.values
                ceiling = max(points.lazy.map(\.value).max() ?? 0, 1024)
            }
        case .thermal:
            guard let thermal = data.thermal, thermal != .unknown else { return nil }
            compact = thermal.rawValue; label = "Thermal"; glyph = "♨"
        case .ports:
            guard let ports = data.ports, ports.inspected > 0 else { return nil }
            compact = String(ports.listeners); label = "Ports"; glyph = "◎"
        case .storage:
            guard let storage = data.storage else { return nil }
            compact = Display.bytes(storage.available); label = "Disk"; glyph = "▱"
        case .gpu, .neural, .fans, .docker:
            return nil
        }
        let title: String
        switch mode {
        case .text: title = "\(label) \(compact)"
        case .icon: title = "\(glyph) \(compact)"
        case .graph:
            let levels = Array("▁▂▃▄▅▆▇█")
            let graph = String(points.suffix(lowDensity ? 4 : 7).map { point in
                levels[Int((max(0, min(1, point.value / ceiling)) * 7).rounded())]
            })
            title = graph.isEmpty ? "\(glyph) \(compact)" : "\(label) \(graph)"
        }
        return (title, "\(label) \(compact)")
    }
}
