import SwiftUI
import LidlessCore

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Prefs.customRPM) private var customRPM = 4000.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            keepAwakeSection
            lidSection
            durationSection
            if model.hasFans {
                Divider()
                fanSection
            }
            Divider()
            statusLine
            footer
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { model.fanMonitor.setVisible(true) }
        .onDisappear { model.fanMonitor.setVisible(false) }
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Image(nsImage: StatusIcon.image(state: model.iconState, fans: model.fansBlasting))
            Text("Lidless").font(.headline)
            Spacer()
            Text(StatusIcon.label(state: model.iconState, fans: model.fansBlasting)
                    .replacingOccurrences(of: "Lidless: ", with: ""))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var keepAwakeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { model.keepAwake.isActive }, set: { model.setKeepAwake($0) })) {
                Label("Keep Awake", systemImage: "eye").font(.title3.weight(.semibold))
            }
            .toggleStyle(.switch)
            if model.keepAwake.isActive {
                Text(describe(model.keepAwake.endCondition)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var lidSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch model.helper.phase {
            case .ready:
                Toggle(isOn: Binding(get: { model.lidActive }, set: { model.setLidMode($0) })) {
                    Label("Lid-Closed Mode", systemImage: "laptopcomputer")
                }
                .toggleStyle(.switch)
                .disabled(model.lidBusy)
                if model.lidActive, let s = model.helper.status {
                    Group {
                        if let cfg = s.lidConfig { Text(describe(cfg.endCondition)) }
                        if let end = s.lidEndsAt { Text("Reverts by \(end.formatted(date: .omitted, time: .shortened)) at the latest") }
                    }
                    .font(.caption).foregroundStyle(.orange)
                }
            case .connecting:
                Label("Connecting to helper…", systemImage: "hourglass").foregroundStyle(.secondary)
            case .notInstalled:
                helperCard(text: "Lid-closed mode and fan control need the Lidless helper (runs as root).",
                           button: "Install Helper…") { model.helper.install() }
            case .needsApproval:
                helperCard(text: "Approve “Lidless” in System Settings → General → Login Items & Extensions (Allow in the Background).",
                           button: "Open Login Items") { model.helper.openLoginItems() }
            case .failed(let msg):
                helperCard(text: msg, button: "Retry") { model.helper.install() }
            }
            if let err = model.lidError {
                Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func helperCard(text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Lid-Closed Mode", systemImage: "laptopcomputer").foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(button, action: action).controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    private var durationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Duration", selection: $model.duration) {
                ForEach(DurationChoice.allCases) { Text($0.label(process: model.processName)).tag($0) }
            }
            .onChange(of: model.duration) { model.durationChanged() }
            if model.duration == .until {
                DatePicker("Until", selection: $model.untilDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .onChange(of: model.untilDate) { model.durationChanged() }
            }
        }
    }

    private var fanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Fans", systemImage: "fan").font(.subheadline.weight(.semibold))
                Spacer()
                if let t = model.fanMonitor.temps.cpuAverage {
                    Text(String(format: "CPU %.0f°C", t)).monospacedDigit()
                        .foregroundStyle((model.fanMonitor.temps.cpuMax ?? 0) > 95 ? .red : .secondary)
                }
                if let g = model.fanMonitor.temps.gpuMax {
                    Text(String(format: "GPU %.0f°C", g)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .font(.caption)

            Picker("", selection: Binding(get: { model.fanMode }, set: { model.setFanMode($0) })) {
                Text("Auto").tag(FanMode.auto)
                Text("Max").tag(FanMode.max)
                Text("Custom").tag(FanMode.custom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!model.helper.isReady)

            if model.fanMode == .custom, let f = model.fanMonitor.fans.first, f.max > f.min {
                VStack(alignment: .leading, spacing: 2) {
                    Slider(value: $customRPM, in: f.min...f.max, step: 100) { editing in
                        if !editing { model.setFanMode(.custom, rpm: customRPM) }
                    }
                    Text("Target \(Int(customRPM)) rpm").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }

            ForEach(model.fanMonitor.fans) { f in
                HStack {
                    Text(model.fanMonitor.fans.count > 1 ? "Fan \(f.index + 1)" : "Fan")
                    ProgressView(value: min(max(f.actual - f.min, 0), f.max - f.min), total: max(f.max - f.min, 1))
                    Text("\(Int(f.actual)) rpm").monospacedDigit().frame(width: 70, alignment: .trailing)
                }
                .font(.caption)
            }
            if !model.helper.isReady {
                Text("Install the helper to control fans.").font(.caption2).foregroundStyle(.secondary)
            }
            if let err = model.fanError {
                Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusLine: some View {
        let p = model.helper.status?.power ?? PowerSource.current()
        let thermal = model.helper.status?.thermal ?? ThermalLevel(ProcessInfo.processInfo.thermalState)
        return HStack(spacing: 10) {
            if let pct = p.batteryPercent {
                Label("\(pct)%", systemImage: p.onAC ? "battery.100.bolt" : "battery.50")
            }
            Text(p.onAC ? "AC power" : "Battery")
            Spacer()
            Label(thermal.rawValue.capitalized, systemImage: "thermometer.medium")
                .foregroundStyle(thermal >= .serious ? .red : thermal == .fair ? .orange : .secondary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var footer: some View {
        HStack {
            SettingsLink { Text("Settings…") }
                .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
            Spacer()
            Button("Quit Lidless") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
    }

    private func describe(_ e: EndCondition) -> String {
        switch e {
        case .indefinite: return "Until turned off"
        case .until(let d): return "Until \(d.formatted(date: .abbreviated, time: .shortened))"
        case .whileProcess(let n): return "While \(n) is running (+\(Int(model.graceSeconds / 60)) min)"
        }
    }
}
