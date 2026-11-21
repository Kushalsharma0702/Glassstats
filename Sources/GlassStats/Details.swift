import AppKit
import GlassStatsCore
import SwiftUI

struct Details: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $model.detailPage) {
                ForEach(DetailPage.allCases) { page in Label(page.rawValue, systemImage: page.symbol).tag(page) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.top, .horizontal], 18)
            .padding(.bottom, 12)
            switch model.detailPage {
            case .activity: activity
            case .processes: ProcessList(model: model)
            case .sensors: sensors
            case .ports: PortList(model: model)
            case .docker: DockerList(model: model)
            }
        }
        .frame(minWidth: 680, minHeight: 420)
    }

    private var activity: some View {
        let data = model.snapshot
        return Form {
            if model.preferences.modules.contains(.cpu) {
                Section("CPU") {
                    LabeledContent("Total", value: Display.percent(data.cpu?.total))
                    LabeledContent("User and nice", value: Display.percent(data.cpu?.user))
                    LabeledContent("System", value: Display.percent(data.cpu?.system))
                    LabeledContent("Load (1, 5 and 15 minutes)",
                                   value: data.load.map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(separator: "  /  "))
                    if let cpu = data.cpu {
                        if data.history.cpu.values.count >= 2 {
                            TrendChart(primary: data.history.cpu.values, accent: metricColor(.cpu), scale: 0...1,
                                       animate: model.preferences.animations, label: "CPU history")
                                .frame(height: 66)
                        }
                        ForEach(cpu.cores.indices, id: \.self) { index in
                            LabeledContent("Logical core \(index + 1)") {
                                if let usage = cpu.cores[index] {
                                    Gauge(value: usage) { Text("Core utilization") }
                                        .gaugeStyle(.accessoryLinear).labelsHidden()
                                    Text(Display.percent(usage)).monospacedDigit()
                                } else { Text("Unavailable") }
                            }
                        }
                    }
                }
            }
            if model.preferences.modules.contains(.memory) {
                Section("Memory") {
                    if let memory = data.memory {
                        LabeledContent("Physical RAM", value: Display.bytes(memory.total))
                        LabeledContent("Used", value: Display.bytes(memory.used))
                        LabeledContent("Estimated available", value: Display.bytes(memory.available))
                        LabeledContent("Memory pressure", value: memory.pressure.rawValue)
                        LabeledContent("Compressed", value: Display.bytes(memory.compressed))
                        LabeledContent("File-backed pages", value: Display.bytes(memory.cached))
                        LabeledContent("Swap used", value: memory.swap.map(Display.bytes) ?? "Unavailable")
                        if data.history.memory.values.count >= 2 {
                            TrendChart(primary: data.history.memory.values, accent: metricColor(.memory), scale: 0...1,
                                       animate: model.preferences.animations, label: "Memory history")
                                .frame(height: 66)
                        }
                    } else { Text("Awaiting a memory sample").foregroundStyle(.secondary) }
                }
            }
            if model.preferences.modules.contains(.network) {
                Section("Network") {
                    if let network = data.network {
                        LabeledContent("Primary interface", value: network.name)
                        LabeledContent("IP addresses", value: network.addresses.joined(separator: "\n"))
                        LabeledContent("Download", value: Display.rate(network.rate?.down))
                        LabeledContent("Upload", value: Display.rate(network.rate?.up))
                        LabeledContent("Downloaded this session", value: Display.bytes(network.downloaded))
                        LabeledContent("Uploaded this session", value: Display.bytes(network.uploaded))
                        let downloads = data.history.down.values
                        let uploads = data.history.up.values
                        if downloads.count >= 2 {
                            let peak = max(1024, downloads.map(\.value).max() ?? 0, uploads.map(\.value).max() ?? 0)
                            TrendChart(primary: downloads, secondary: uploads, accent: metricColor(.network),
                                       comparison: metricColor(.memory), scale: 0...(peak * 1.12),
                                       animate: model.preferences.animations, label: "Download and upload history")
                                .frame(height: 72)
                        }
                    } else { Text("No primary interface").foregroundStyle(.secondary) }
                }
            }
            if model.preferences.modules.contains(.storage), let storage = data.storage {
                Section("Storage · Home volume") {
                    LabeledContent("Capacity", value: Display.bytes(storage.capacity))
                    LabeledContent("Available", value: Display.bytes(storage.available))
                }
            }
            if model.preferences.modules.isDisjoint(with: [.cpu, .memory, .network, .storage]) {
                Text("Enable CPU, memory, network, or storage monitoring in Settings.")
            }
        }.formStyle(.grouped).textSelection(.enabled)
    }

    private func metricColor(_ metric: Metric) -> Color {
        metric.color(in: scheme, custom: model.preferences.colorAccents)
    }

    private var sensors: some View {
        Form {
            if model.preferences.modules.contains(.thermal) || model.preferences.modules.contains(.fans) {
                Section("Thermals") {
                    if model.preferences.modules.contains(.thermal) {
                        LabeledContent("macOS thermal pressure", value: model.snapshot.thermal?.rawValue ?? "Unavailable")
                        LabeledContent("Temperature sensor / history", value: "Unavailable")
                    }
                    if model.preferences.modules.contains(.fans) {
                        LabeledContent("Fan speed", value: "Unavailable")
                    }
                    Text("GlassStats uses the thermal pressure signal published by macOS. Temperature and fan readings require a supported sensor provider.")
                        .foregroundStyle(.secondary)
                }
            }
            if model.preferences.modules.contains(.gpu) {
                Section("GPU") {
                    let gpus = model.snapshot.hardware?.gpus ?? []
                    if gpus.isEmpty { Text("No Metal device reported") }
                    ForEach(Array(gpus.enumerated()), id: \.offset) { _, gpu in
                        LabeledContent(gpu.name, value: gpu.unifiedMemory ? "Unified memory" : "Dedicated memory")
                        LabeledContent("Recommended working set", value: Display.bytes(gpu.workingSet))
                    }
                    LabeledContent("System-wide utilization and memory usage", value: "Unavailable")
                }
            }
            if model.preferences.modules.contains(.neural) {
                Section("Neural Engine") {
                    LabeledContent("Core ML compute device", value: model.snapshot.hardware?.neuralEngine == true ? "Available" : "Unavailable")
                    LabeledContent("System-wide utilization", value: "Unavailable")
                    Link("Profile a model with Core ML and Instruments",
                         destination: URL(string: "https://developer.apple.com/documentation/coreml/analyzing-a-core-ml-model-s-performance-in-xcode")!)
                }
            }
        }.formStyle(.grouped)
    }
}

private struct PortList: View {
    let model: AppModel
    @State private var transport = SocketTransport.tcp
    @State private var search = ""
    @State private var process = ""
    @State private var scope = "Any bind"
    @State private var descending = false
    @State private var selection: SocketReading?
    @State private var requesting = false
    @State private var working = false
    @State private var plan: PortStopPlan?
    @State private var actionMessage: String?

    private var rows: [SocketReading] {
        let items = model.snapshot.ports?.sockets ?? []
        let filtered = items.filter { row in
            row.transport == transport &&
            (search.isEmpty || String(row.port).contains(search.trimmingCharacters(in: .whitespaces))) &&
            (process.isEmpty || row.process.localizedCaseInsensitiveContains(process) || String(row.owner.pid) == process) &&
            (scope == "Any bind" || (scope == "Localhost" && row.scope == .loopback) ||
             (scope == "Non-loopback" && row.scope != .loopback))
        }
        return descending ? filtered.reversed() : filtered
    }

    var body: some View {
        if model.preferences.modules.contains(.ports) {
            VStack(spacing: 9) {
                HStack {
                    Picker("Protocol", selection: $transport) {
                        Text("TCP listeners").tag(SocketTransport.tcp)
                        Text("UDP sockets").tag(SocketTransport.udp)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    Button(requesting ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise") {
                        requesting = true
                        model.requestPorts()
                    }.disabled(requesting)
                    Button("Copy", systemImage: "document.on.document") {
                        if let selection { copy(selection) }
                    }.disabled(selection == nil)
                    Button("Process details") { if let selection { showProcess(selection) } }
                        .disabled(selection == nil || !model.preferences.processInspection)
                }.padding(.horizontal)
                HStack(spacing: 10) {
                    TextField("Search port", text: $search)
                    TextField("Process name or PID", text: $process)
                    Picker("Bind", selection: $scope) {
                        ForEach(["Any bind", "Localhost", "Non-loopback"], id: \.self) { Text($0) }
                    }.labelsHidden().fixedSize()
                    Button(descending ? "Port ↓" : "Port ↑") { descending.toggle() }.help("Reverse port sort")
                }.padding(.horizontal)
                Table(rows, selection: $selection) {
                    TableColumn("Port") { row in Text(String(row.port)).monospacedDigit() }.width(50)
                    TableColumn("Process") { row in Text(row.process).help(row.process) }.width(min: 85, ideal: 120)
                    TableColumn("PID") { row in Text(String(row.owner.pid)).monospacedDigit() }.width(48)
                    TableColumn("Bind address") { row in
                        Text(row.address).font(.caption.monospaced())
                            .help(row.address)
                            .foregroundStyle(row.scope == .loopback ? Color.primary : Color.orange)
                    }.width(min: 108, ideal: 150)
                    TableColumn("IP") { row in Text(row.ipv6 ? "IPv6" : "IPv4") }.width(38)
                    TableColumn("Service") { row in Text(row.service.isEmpty ? "—" : row.service) }.width(min: 52, ideal: 70)
                    TableColumn("Status") { row in Text(row.status) }.width(76)
                }
                .overlay {
                    if rows.isEmpty {
                        ContentUnavailableView(model.snapshot.ports == nil ? "Discovering sockets" : "No matching sockets",
                                               systemImage: "network")
                            .allowsHitTesting(false)
                    }
                }
                .contextMenu(forSelectionType: SocketReading.self) { items in
                    if let row = items.first {
                        Button("Copy socket and process") { copy(row) }
                        if model.preferences.processInspection { Button("Process details") { showProcess(row) } }
                    }
                } primaryAction: { items in
                    if model.preferences.processInspection, let row = items.first { showProcess(row) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let result = model.snapshot.ports {
                        Text("\(rows.count) shown · \(result.inspected) processes inspected · \(result.inaccessible) inaccessible or exited")
                    }
                    Text("Orange marks a non-loopback bind. Internet reachability depends on firewall and routing.")
                    HStack {
                        Button("Close Selected Port…", role: .destructive) {
                            if let selection { prepareClose([selection]) }
                        }.disabled(selection == nil || working)
                        Menu("Close All Ports…") {
                            Button("Close Shown Ports…", role: .destructive) { prepareClose(rows) }
                                .disabled(rows.isEmpty)
                            Button("Close All Eligible Ports…", role: .destructive) {
                                let listeners = model.snapshot.ports?.sockets.filter { !$0.connected } ?? []
                                prepareClose(listeners)
                            }
                        }
                        .disabled(model.snapshot.ports?.sockets.isEmpty != false || working)
                        if working { ProgressView().controlSize(.small) }
                        if let actionMessage { Text(actionMessage).foregroundStyle(.primary) }
                        Spacer()
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .bottom])
            }
            .sheet(isPresented: Binding(get: { plan != nil }, set: { if !$0 { plan = nil } })) {
                if let plan {
                    PortCloseSheet(plan: plan, cancel: { self.plan = nil }, confirm: { confirmClose(plan) })
                }
            }
            .onAppear { scope = model.preferences.portsLocalOnly ? "Localhost" : "Any bind" }
            .onChange(of: model.snapshot.ports?.date) { requesting = false }
            .onChange(of: transport) { selection = nil }
            .onChange(of: rows) { if let selection, !rows.contains(selection) { self.selection = nil } }
        } else {
            ContentUnavailableView("Port monitoring is disabled", systemImage: "network",
                                   description: Text("Enable Ports in Monitoring settings."))
        }
    }

    private func prepareClose(_ selected: [SocketReading]) {
        guard !working else { return }
        working = true
        actionMessage = nil
        Task {
            let candidate = await model.preparePortClose(selected)
            working = false
            if candidate.endpoints.isEmpty {
                actionMessage = "No eligible local development processes in this selection."
            } else {
                plan = candidate
            }
        }
    }

    private func confirmClose(_ confirmed: PortStopPlan) {
        plan = nil
        working = true
        Task {
            let result = await model.closePorts(confirmed)
            working = false
            actionMessage = "Stop requested for \(result.requested) · \(result.skipped) changed or skipped"
        }
    }

    private func copy(_ row: SocketReading) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(row.transport.rawValue) \(row.endpoint) · \(row.process) (PID \(row.owner.pid)) · \(row.status)",
                                       forType: .string)
    }

    private func showProcess(_ row: SocketReading) {
        model.focusedProcess = row.owner
        model.detailPage = .processes
    }
}

private struct PortCloseSheet: View {
    let plan: PortStopPlan
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Close ports by stopping their processes?").font(.headline)
            Text("GlassStats will request a graceful stop for these local development processes. Any other ports those processes own may close too.")
            List(plan.owners) { owner in
                let ports = plan.endpoints.filter { $0.owner == owner.owner }.map(\.endpoint)
                VStack(alignment: .leading) {
                    Text("\(owner.process) · PID \(owner.owner.pid)")
                    Text(ports.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
            }.frame(height: min(220, max(55, CGFloat(plan.owners.count) * 40)))
            let skipped = plan.selectedCount - plan.endpoints.count
            if skipped > 0 { Text("\(skipped) protected or unavailable sockets will be skipped.").foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Stop \(plan.owners.count) Processes", role: .destructive, action: confirm)
            }
        }.padding(22).frame(width: 450)
    }
}

private struct DockerList: View {
    let model: AppModel

    var body: some View {
        if !model.preferences.isEnabled(.docker) {
            ContentUnavailableView("Docker monitoring is disabled", systemImage: "shippingbox")
        } else {
            VStack(spacing: 10) {
                HStack {
                    Label("Local Docker Engine", systemImage: "shippingbox").font(.headline)
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { model.requestDocker() }
                }.padding(.horizontal, 16)
                if let containers = model.dockerInventory?.containers {
                    if containers.isEmpty {
                        ContentUnavailableView("No containers", systemImage: "shippingbox")
                    } else {
                        Table(containers) {
                            TableColumn("Container", value: \.name).width(min: 100, ideal: 140)
                            TableColumn("Image", value: \.image).width(min: 120, ideal: 180)
                            TableColumn("Status") { item in
                                Text(item.status).foregroundStyle(item.state == "running" ? Color.green : Color.secondary)
                            }.width(min: 90, ideal: 120)
                            TableColumn("Published ports") { item in
                                let ports = item.publishedPorts.joined(separator: ", ")
                                Text(ports.isEmpty ? "—" : ports).help(ports)
                            }.width(min: 140, ideal: 230)
                        }
                    }
                } else if model.dockerInventory != nil {
                    ContentUnavailableView("Docker Engine unavailable", systemImage: "shippingbox",
                                           description: Text("Start Docker Desktop or a local engine with a standard Docker socket."))
                } else {
                    ProgressView("Checking Docker…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ProcessList: View {
    let model: AppModel
    @State private var mode = "CPU"
    @State private var filter = ""
    @State private var detail: ProcessReading?
    @State private var loading = false
    @State private var focus: ProcessID?

    private var rows: [ProcessReading] {
        let processes = model.snapshot.processes ?? []
        return processes.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || String($0.id.pid) == filter }
            .sorted { a, b in
                if mode == "Memory" { return (a.memory, a.id.pid) > (b.memory, b.id.pid) }
                return (a.cpu ?? -1, a.memory, a.id.pid) > (b.cpu ?? -1, b.memory, b.id.pid)
            }
    }

    var body: some View {
        if model.preferences.processInspection {
            VStack(spacing: 9) {
                HStack {
                    Picker("Sort by", selection: $mode) { Text("CPU").tag("CPU"); Text("Memory").tag("Memory") }
                        .pickerStyle(.segmented).fixedSize()
                    Spacer()
                    TextField("Process name or PID", text: $filter).frame(maxWidth: 270)
                }.padding(.horizontal)
                if let focus {
                    HStack {
                        if let detail {
                            VStack(alignment: .leading) {
                                Text(detail.name).font(.headline)
                                Text("PID \(detail.id.pid) · \(Display.bytes(detail.memory)) memory footprint").foregroundStyle(.secondary)
                            }
                        } else {
                            Text(loading ? "Reading process details…" : "Process \(focus.pid) exited or cannot be inspected.")
                        }
                        Spacer()
                        Button("Done") { model.focusedProcess = nil; self.focus = nil; detail = nil }
                    }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal)
                }
                Table(rows) {
                    TableColumn("Process", value: \.name)
                    TableColumn("PID") { Text(String($0.id.pid)).monospacedDigit() }.width(min: 65, ideal: 95)
                    TableColumn("CPU") { Text(Display.percent($0.cpu)).monospacedDigit() }.width(min: 60, ideal: 100)
                    TableColumn("Memory footprint") { Text(Display.bytes($0.memory)).monospacedDigit() }.width(min: 110, ideal: 140)
                }
                .contextMenu(forSelectionType: ProcessID.self) { items in
                    if let id = items.first { Button("Process details") { model.focusedProcess = id } }
                } primaryAction: { items in
                    model.focusedProcess = items.first
                }
                Text("CPU is relative to one logical core. macOS may limit which processes are visible.")
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 10)
            }
            .task(id: model.focusedProcess) {
                focus = model.focusedProcess
                detail = nil
                guard let focus else { return }
                loading = true
                let result = await model.process(focus)
                guard !Task.isCancelled else { return }
                loading = false
                detail = result
            }
        } else {
            ContentUnavailableView("Process inspection is disabled", systemImage: "list.bullet.rectangle",
                                   description: Text("Enable process inspection in Developer settings."))
        }
    }
}
