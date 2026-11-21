import AppKit
import Carbon
import GlassStatsCore
import ServiceManagement
import SwiftUI

@MainActor
private final class GlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model: AppModel
    private let smokeSeconds: Double?
    private lazy var statusBar = StatusBar(coordinator: self)
    private var dashboard: GlassPanel?
    private var details: NSWindow?
    private var settings: NSWindow?
    private var shortcut: EventHotKeyRef?
    private var shortcutHandler: EventHandlerRef?
    private var currentCompact = false

    override init() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--smoke-test") {
            let requested = args.dropFirst(index + 1).first.flatMap(Double.init) ?? 5
            smokeSeconds = requested.isFinite ? max(4, min(600, requested)) : 5
            model = AppModel(defaults: nil, widgets: false)
        } else {
            smokeSeconds = nil
            model = AppModel()
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.preferencesChanged = { [weak self] in self?.applyPreferences() }
        model.didSample = { [weak self] in
            guard let self else { return }
            statusBar.update(model: model)
        }
        let main = NSMenu()
        let glass = NSMenuItem(title: "GlassStats", action: nil, keyEquivalent: "")
        glass.submenu = actionMenu(title: "GlassStats")
        main.addItem(glass)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [
            ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")
        ] {
            editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        edit.submenu = editMenu
        main.addItem(edit)
        NSApp.mainMenu = main
        applyPreferences()
        registerShortcut()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke),
                                                         name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        model.start()
        if model.preferences.showDashboard && !model.preferences.startMinimized { showDashboard() }
        if let smokeSeconds {
            Task { await smokeTest(duration: smokeSeconds) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        if let shortcut { UnregisterEventHotKey(shortcut) }
        if let shortcutHandler { RemoveEventHandler(shortcutHandler) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "glassstats" {
            switch url.host {
            case "ports": showDetails(.ports)
            case "sensors": showDetails(.sensors)
            case "docker": showDetails(.docker)
            case "activity": showDetails(.activity)
            default: showDashboard()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard()
        return true
    }

    func actionMenu(title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        let actions: [(String, Selector, String)] = [
            ("Toggle Dashboard", #selector(toggleDashboard), ""),
            ("System Activity", #selector(openActivity), ""),
            ("Processes", #selector(openProcesses), ""),
            ("Sensors", #selector(openSensors), ""),
            ("Open Ports", #selector(openPorts), ""),
            ("Docker", #selector(openDocker), ""),
            ("Settings…", #selector(openSettings), ",")
        ]
        for (title, action, key) in actions {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
            if action == #selector(toggleDashboard) {
                item.keyEquivalent = "g"
                item.keyEquivalentModifierMask = [.command, .control, .option]
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit GlassStats", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc func toggleDashboard() {
        if dashboard?.isVisible == true { hideDashboard() }
        else { showDashboard() }
    }

    func showDashboard() {
        if dashboard == nil { dashboard = makeDashboard() }
        guard let dashboard else { return }
        if !model.dashboardVisible { attachDashboard(to: dashboard) }
        constrain(dashboard)
        dashboard.orderFrontRegardless()
        model.dashboardVisible = true
    }

    private func hideDashboard() {
        dashboard?.orderOut(nil)
        dashboard?.contentView = nil
        model.dashboardVisible = false
    }

    @objc func openSettings() {
        if settings == nil {
            let view = SettingsView(model: model, showDashboard: { [weak self] in self?.showDashboard() },
                                    launchAtLogin: { SMAppService.mainApp.status == .enabled },
                                    setLaunchAtLogin: { [weak self] in self?.setLaunch($0) })
            settings = toolWindow(title: "GlassStats Settings", root: view, size: .init(width: 580, height: 490),
                                  minimum: .init(width: 540, height: 440), name: "Settings")
        }
        NSApp.activate()
        settings?.makeKeyAndOrderFront(nil)
    }

    private func setLaunch(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            model.loginStatusMessage = SMAppService.mainApp.status == .requiresApproval
                ? "Approve GlassStats in System Settings → General → Login Items." : nil
        } catch {
            model.loginStatusMessage = error.localizedDescription
        }
    }

    @objc private func openActivity() { showDetails(.activity) }
    @objc private func openProcesses() { showDetails(.processes) }
    @objc private func openSensors() { showDetails(.sensors) }
    @objc private func openPorts() { showDetails(.ports) }
    @objc private func openDocker() { showDetails(.docker) }

    private func showDetails(_ page: DetailPage) {
        model.detailPage = page
        if details == nil {
            details = toolWindow(title: "GlassStats Details", root: Details(model: model),
                                 size: .init(width: 790, height: 570), minimum: .init(width: 680, height: 420), name: "Details")
        }
        model.detailsVisible = true
        if page == .ports { model.requestPorts() }
        NSApp.activate()
        details?.makeKeyAndOrderFront(nil)
    }

    private func toolWindow<Root: View>(title: String, root: Root, size: NSSize, minimum: NSSize, name: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: root)
        window.contentMinSize = minimum
        window.delegate = self
        window.center()
        if smokeSeconds == nil {
            _ = window.setFrameUsingName(name)
            window.setFrameAutosaveName(name)
        }
        constrain(window)
        return window
    }

    private func makeDashboard() -> GlassPanel {
        let size = dashboardSize
        let panel = GlassPanel(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.borderless, .resizable, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.title = "GlassStats Dashboard"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.contentMinSize = NSSize(width: 330, height: 360)
        let restored = smokeSeconds == nil && panel.setFrameUsingName("Dashboard")
        if !restored, let screen = screenUnderMouse() {
            let visible = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - size.width - 22, y: visible.maxY - 22))
        }
        if smokeSeconds == nil { panel.setFrameAutosaveName("Dashboard") }
        configure(panel)
        return panel
    }

    private func attachDashboard(to panel: NSPanel) {
        let backdrop = NSView()
        let host = NSHostingView(rootView: Dashboard(model: model, close: { [weak self] in self?.hideDashboard() },
            settings: { [weak self] in self?.openSettings() }, show: { [weak self] in self?.showDetails($0) }))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            host.topAnchor.constraint(equalTo: backdrop.topAnchor),
            host.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor)
        ])
        panel.contentView = backdrop
    }

    private var dashboardSize: NSSize {
        model.preferences.compact ? NSSize(width: 370, height: 510) : NSSize(width: 430, height: 748)
    }

    private func applyPreferences() {
        let preferences = model.preferences
        let policy: NSApplication.ActivationPolicy = preferences.menuBar ? .accessory : .regular
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
        switch preferences.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        statusBar.update(model: model)
        model.clearWidgetIfDisabled()
        if let dashboard {
            configure(dashboard)
            if currentCompact != preferences.compact {
                let old = dashboard.frame
                let size = dashboardSize
                dashboard.setFrame(NSRect(x: old.maxX - size.width, y: old.maxY - size.height,
                                          width: size.width, height: size.height), display: true)
                constrain(dashboard)
            }
        }
        currentCompact = preferences.compact
    }

    private func configure(_ panel: NSPanel) {
        panel.level = model.preferences.alwaysOnTop ? .floating : .normal
        panel.collectionBehavior = model.preferences.allSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            : [.moveToActiveSpace, .fullScreenNone, .ignoresCycle]
    }

    private func screenUnderMouse() -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func constrain(_ window: NSWindow) {
        let frame = window.frame
        let screens = NSScreen.screens
        func area(_ rect: NSRect) -> CGFloat { max(0, rect.width) * max(0, rect.height) }
        let best = screens.max { area($0.frame.intersection(frame)) < area($1.frame.intersection(frame)) }
        let screen = best.flatMap { area($0.frame.intersection(frame)) > 0 ? $0 : nil } ?? screenUnderMouse()
        guard let visible = screen?.visibleFrame else { return }
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        let origin = NSPoint(x: max(visible.minX, min(frame.minX, visible.maxX - width)),
                             y: max(visible.minY, min(frame.minY, visible.maxY - height)))
        let corrected = NSRect(origin: origin, size: .init(width: width, height: height))
        if corrected != frame { window.setFrame(corrected, display: true) }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === dashboard { model.dashboardVisible = false }
        if window === details {
            model.detailsVisible = false
            details = nil
        }
        if window === settings { settings = nil }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        if notification.object as? NSWindow === details { model.detailsVisible = false }
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        if notification.object as? NSWindow === details { model.detailsVisible = true }
    }

    @objc private func woke() { model.resetBaselines() }

    @objc private func screensChanged() {
        if let dashboard { constrain(dashboard) }
    }

    private func smokeTest(duration: Double) async {
        var failures: [String] = []
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failures.append(name) }
        }
        check(dashboard?.isVisible == true, "dashboard appears on launch")
        if let dashboard {
            let visible = NSScreen.screens.contains { $0.visibleFrame.contains(dashboard.frame) }
            check(visible, "dashboard fits its display")
            check(!dashboard.styleMask.contains(.titled) && !dashboard.isOpaque &&
                  dashboard.backgroundColor.alphaComponent == 0, "dashboard window is transparent and title-bar free")
            print("Dashboard window ID \(dashboard.windowNumber)")
        }
        toggleDashboard()
        check(dashboard?.isVisible == false, "dashboard hides")
        toggleDashboard()
        check(dashboard?.isVisible == true, "dashboard reopens")
        check(shortcut != nil, "global dashboard shortcut registers")
        let started = ProcessInfo.processInfo.systemUptime
        let initialCPU = ProcessInfo.processInfo.systemUptime
        var startUsage = rusage()
        getrusage(RUSAGE_SELF, &startUsage)
        try? await Task.sleep(for: .seconds(3))
        check(model.snapshot.cpu != nil && !model.snapshot.history.cpu.values.isEmpty, "live CPU and history")
        check(model.snapshot.memory?.total == ProcessInfo.processInfo.physicalMemory, "live RAM")
        check(statusBar.isPresent && statusBar.accessibleTitle?.contains("CPU") == true &&
              statusBar.accessibleTitle?.contains("RAM") == true, "menu bar CPU and RAM readouts")
        if model.snapshot.network == nil {
            print("SKIP live network throughput (no primary interface)")
        } else {
            check(model.snapshot.network?.rate != nil, "live network throughput")
        }
        check((model.snapshot.ports?.inspected ?? 0) > 0, "local socket inventory")
        check(model.snapshot.thermal != nil && model.snapshot.hardware != nil, "thermal and hardware capability discovery")
        model.preferences.menuMetrics = [.memory]
        check(statusBar.accessibleTitle?.contains("CPU") == false &&
              statusBar.accessibleTitle?.contains("RAM") == true, "configuration changes menu bar metrics")
        model.preferences.menuMetrics = [.cpu, .memory]
        model.preferences.appearance = .dark
        check(NSApp.appearance?.name == .darkAqua, "dark appearance applies")
        model.preferences.appearance = .light
        check(NSApp.appearance?.name == .aqua, "light appearance applies")
        model.preferences.appearance = .system
        model.preferences.compact = true
        check(dashboard?.frame.width == dashboardSize.width, "compact dashboard resizes")
        model.preferences.compact = false
        showDetails(.ports)
        check(details?.isVisible == true && model.detailPage == .ports, "port inspector opens")
        details?.close()
        openSettings()
        check(settings?.isVisible == true, "settings open")
        settings?.close()
        showDetails(.docker)
        try? await Task.sleep(for: .milliseconds(500))
        check(details?.isVisible == true && model.detailPage == .docker, "Docker inspector opens")
        details?.close()
        model.cardBinding(.network).wrappedValue = false
        model.cardBinding(.ports).wrappedValue = false
        try? await Task.sleep(for: .milliseconds(300))
        check(model.snapshot.network == nil && model.snapshot.ports == nil, "hidden cards release unused samplers")
        model.cardBinding(.network).wrappedValue = true
        model.cardBinding(.ports).wrappedValue = true
        print("Smoke test running for \(Int(duration)) seconds")
        fflush(nil)
        try? await Task.sleep(for: .seconds(max(0, duration - (ProcessInfo.processInfo.systemUptime - started))))
        let sampleCount = model.snapshot.history.cpu.values.count
        check(sampleCount >= 2, "CPU history continues updating (\(sampleCount) samples)")
        check(dashboard?.isVisible == true, "dashboard stays visible after closing auxiliary windows")
        var endUsage = rusage()
        getrusage(RUSAGE_SELF, &endUsage)
        let wall = ProcessInfo.processInfo.systemUptime - initialCPU
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        let cpu = seconds(endUsage.ru_utime) + seconds(endUsage.ru_stime) -
                  seconds(startUsage.ru_utime) - seconds(startUsage.ru_stime)
        print("Dashboard visible: \(String(format: "%.2f", 100 * cpu / wall))% of one core over \(String(format: "%.1f", wall))s; peak RSS \(Display.bytes(UInt64(clamping: endUsage.ru_maxrss)))")
        captureDashboard("dark")
        captureDashboard("light")
        fflush(nil)
        if duration >= 20 {
            hideDashboard()
            try? await Task.sleep(for: .seconds(1))
            check(model.snapshot.network == nil && model.snapshot.ports == nil && model.dockerInventory == nil,
                  "menu-bar-only mode stops unused network, port and Docker sampling")
            let hiddenStart = ProcessInfo.processInfo.systemUptime
            getrusage(RUSAGE_SELF, &startUsage)
            try? await Task.sleep(for: .seconds(10))
            getrusage(RUSAGE_SELF, &endUsage)
            let hiddenWall = ProcessInfo.processInfo.systemUptime - hiddenStart
            let hiddenCPU = seconds(endUsage.ru_utime) + seconds(endUsage.ru_stime) -
                            seconds(startUsage.ru_utime) - seconds(startUsage.ru_stime)
            print("Menu bar only: \(String(format: "%.2f", 100 * hiddenCPU / hiddenWall))% of one core over \(String(format: "%.1f", hiddenWall))s")
        }
        if CommandLine.arguments.contains("--measure-low-power") {
            model.preferences.economyMode = true
            showDashboard()
            try? await Task.sleep(for: .seconds(4))
            let economyStart = ProcessInfo.processInfo.systemUptime
            getrusage(RUSAGE_SELF, &startUsage)
            try? await Task.sleep(for: .seconds(15))
            getrusage(RUSAGE_SELF, &endUsage)
            let economyWall = ProcessInfo.processInfo.systemUptime - economyStart
            let economyCPU = seconds(endUsage.ru_utime) + seconds(endUsage.ru_stime) -
                             seconds(startUsage.ru_utime) - seconds(startUsage.ru_stime)
            print("Low Power dashboard: \(String(format: "%.2f", 100 * economyCPU / economyWall))% of one core over \(String(format: "%.1f", economyWall))s")
        }
        fflush(nil)
        if failures.isEmpty { NSApp.terminate(nil) }
        else { exit(EXIT_FAILURE) }
    }

    private func captureDashboard(_ appearance: String) {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--capture-dashboard"),
              let directory = args.dropFirst(index + 1).first, let size = dashboard?.contentView?.bounds.size else { return }
        let renderer = ImageRenderer(content: Dashboard(model: model, close: {}, settings: {}, show: { _ in },
                                                       documentationPreview: true)
            .environment(\.colorScheme, appearance == "dark" ? .dark : .light)
            .frame(width: size.width))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            print("Could not render the dashboard")
            return
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true).appending(path: "dashboard-\(appearance).png")
        do {
            try png.write(to: output, options: .atomic)
            print("Dashboard preview exported in \(appearance) appearance")
        } catch {
            print("Could not save the dashboard preview: \(error.localizedDescription)")
        }
    }

    private func registerShortcut() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let app = Unmanaged<AppCoordinator>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { app.toggleDashboard() }
            return noErr
        }
        let target = GetApplicationEventTarget()
        guard InstallEventHandler(target, callback, 1, &spec, Unmanaged.passUnretained(self).toOpaque(),
                                  &shortcutHandler) == noErr else { return }
        let identifier = EventHotKeyID(signature: 0x474C5354, id: 1)
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        let code = smokeSeconds == nil ? kVK_ANSI_G : kVK_ANSI_J
        RegisterEventHotKey(UInt32(code), modifiers, identifier, target, 0, &shortcut)
    }
}
