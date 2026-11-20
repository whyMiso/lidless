import SwiftUI
import LidlessCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            SafetySettings().tabItem { Label("Safety", systemImage: "shield.lefthalf.filled") }
            HelperSettings().tabItem { Label("Helper", systemImage: "lock.shield") }
        }
        .frame(width: 460)
        .padding(20)
        .environmentObject(model)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?
    @AppStorage(Prefs.keepDisplayOn) private var keepDisplayOn = false
    @AppStorage(Prefs.processName) private var processName = "claude"
    @AppStorage(Prefs.graceMinutes) private var graceMinutes = 2.0
    @AppStorage(Prefs.hotkeyEnabled) private var hotkeyEnabled = true

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) {
                    do { try LaunchAtLogin.set(launchAtLogin); loginError = nil }
                    catch { loginError = error.localizedDescription; launchAtLogin = LaunchAtLogin.isEnabled }
                }
            if let loginError { Text(loginError).foregroundStyle(.red).font(.caption) }

            Toggle("Keep display on during Keep Awake", isOn: $keepDisplayOn)

            TextField("Watched process name", text: $processName)
                .onSubmit { model.settingsChanged() }
            Text("Used by “While … is running”. Exact, case-sensitive executable name (claude matches Claude Code, not the Claude desktop app).")
                .font(.caption).foregroundStyle(.secondary)
            Stepper("Grace period after it exits: \(Int(graceMinutes)) min", value: $graceMinutes, in: 0...30, step: 1)
                .onChange(of: graceMinutes) { model.settingsChanged() }

            Toggle("Global hotkey toggles Keep Awake", isOn: $hotkeyEnabled)
                .onChange(of: hotkeyEnabled) { model.applyHotKey() }
            if hotkeyEnabled { HotKeyRecorder() }
        }
    }
}

private struct HotKeyRecorder: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Prefs.hotkeyCode) private var code = 37
    @AppStorage(Prefs.hotkeyMods) private var mods = 0
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text("Shortcut")
            Spacer()
            Button(recording ? "Press keys…" : HotKey.describe(keyCode: UInt32(code), modifiers: NSEvent.ModifierFlags(rawValue: UInt(mods)))) {
                recording ? stop() : start()
            }
        }
    }

    private func start() {
        recording = true
        HotKey.shared.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let m = e.modifierFlags.intersection([.command, .option, .control, .shift])
            if e.keyCode == 53 { stop(); return nil }   // Esc cancels
            guard !m.intersection([.command, .option, .control]).isEmpty else { return nil }
            code = Int(e.keyCode)
            mods = Int(m.rawValue)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        model.applyHotKey()
    }
}

private struct SafetySettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Prefs.acOnly) private var acOnly = false
    @AppStorage(Prefs.batteryThreshold) private var batteryThreshold = 20
    @AppStorage(Prefs.maxSessionHours) private var maxSessionHours = 8.0
    @AppStorage(Prefs.displaySleepOnLidClose) private var displaySleep = true
    @AppStorage(Prefs.sleepOnSafetyStop) private var sleepOnStop = true

    var body: some View {
        Form {
            Section("Lid-closed mode") {
                Toggle("Only allow on AC power", isOn: $acOnly)
                Stepper("Turn off below \(batteryThreshold)% battery", value: $batteryThreshold, in: 5...90, step: 5)
                Stepper("Maximum session: \(Int(maxSessionHours)) h", value: $maxSessionHours, in: 1...48, step: 1)
                Toggle("Turn the display off when the lid closes", isOn: $displaySleep)
                Toggle("Sleep immediately if a guard trips while the lid is closed", isOn: $sleepOnStop)
            }
            Section {
                Text("Always on: critical temperature turns lid-closed mode off and hands fans back to the system; serious temperature sends a notification. If the app quits, crashes or stops responding, the helper restores everything within ~6 seconds.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: acOnly) { model.settingsChanged() }
        .onChange(of: batteryThreshold) { model.settingsChanged() }
        .onChange(of: maxSessionHours) { model.settingsChanged() }
        .onChange(of: displaySleep) { model.settingsChanged() }
        .onChange(of: sleepOnStop) { model.settingsChanged() }
    }
}

private struct HelperSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            LabeledContent("Status", value: phaseText)
            if let s = model.helper.status {
                LabeledContent("disablesleep now", value: s.currentDisableSleep.map(String.init) ?? "?")
                if let o = s.originalDisableSleep { LabeledContent("Original (will restore)", value: String(o)) }
                LabeledContent("Fan control", value: s.fanControlAvailable ? "Available" : "No fans")
                if let e = s.lastError { LabeledContent("Last error", value: e) }
                if !s.events.isEmpty {
                    Section("Recent events") {
                        ForEach(s.events.reversed()) { e in
                            VStack(alignment: .leading) {
                                Text(e.message).font(.caption)
                                Text(e.date.formatted(date: .abbreviated, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            HStack {
                Button("Install / Re-register") { model.helper.install() }
                Button("Open Login Items") { model.helper.openLoginItems() }
                Button("Uninstall Helper", role: .destructive) { model.helper.uninstall() }
            }
        }
    }

    private var phaseText: String {
        switch model.helper.phase {
        case .ready: return "Running"
        case .connecting: return "Connecting…"
        case .notInstalled: return "Not installed"
        case .needsApproval: return "Waiting for approval in Login Items"
        case .failed(let m): return m
        }
    }
}
