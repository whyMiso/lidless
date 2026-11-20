import AppKit
import os
import Combine
import ServiceManagement
import UserNotifications
import LidlessCore

enum Prefs {
    static let acOnly = "acOnly"
    static let batteryThreshold = "batteryThreshold"
    static let maxSessionHours = "maxSessionHours"
    static let processName = "processName"
    static let graceMinutes = "graceMinutes"
    static let displaySleepOnLidClose = "displaySleepOnLidClose"
    static let sleepOnSafetyStop = "sleepOnSafetyStop"
    static let keepDisplayOn = "keepDisplayOn"
    static let hotkeyEnabled = "hotkeyEnabled"
    static let hotkeyCode = "hotkeyCode"
    static let hotkeyMods = "hotkeyMods"
    static let lidWarningShown = "lidWarningShown"
    static let customRPM = "customRPM"

    static func register() {
        UserDefaults.standard.register(defaults: [
            acOnly: false,
            batteryThreshold: 20,
            maxSessionHours: 8.0,
            processName: "claude",
            graceMinutes: 2.0,
            displaySleepOnLidClose: true,
            sleepOnSafetyStop: true,
            keepDisplayOn: false,
            hotkeyEnabled: true,
            hotkeyCode: 37,   // kVK_ANSI_L
            hotkeyMods: Int(NSEvent.ModifierFlags([.control, .option, .command]).rawValue),
            lidWarningShown: false,
            customRPM: 4000.0,
        ])
    }
}

enum DurationChoice: String, CaseIterable, Identifiable {
    case indefinite, m30, h1, h2, h4, until, whileProcess
    var id: String { rawValue }

    func label(process: String) -> String {
        switch self {
        case .indefinite: return "Indefinitely"
        case .m30: return "30 minutes"
        case .h1: return "1 hour"
        case .h2: return "2 hours"
        case .h4: return "4 hours"
        case .until: return "Until a specific time…"
        case .whileProcess: return "While \(process) is running"
        }
    }
}

enum IconState { case idle, awake, lid }

@MainActor
final class AppModel: ObservableObject {
    let keepAwake = KeepAwakeController()
    let helper = HelperClient()
    let fanMonitor = FanMonitor()

    @Published var duration: DurationChoice = .indefinite
    @Published var untilDate: Date = Calendar.current.date(byAdding: .hour, value: 3, to: Date())!
    @Published var lidError: String?
    @Published var fanError: String?
    @Published var lidBusy = false
    /// Mode currently being applied (shown immediately, before the helper confirms).
    @Published var pendingFanMode: FanMode?

    private var bag: Set<AnyCancellable> = []
    private let defaults = UserDefaults.standard

    init() {
        Prefs.register()
        // Re-publish child changes so views only need to observe AppModel.
        keepAwake.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        helper.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        fanMonitor.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)

        keepAwake.onAutoStop = { [weak self] msg in self?.notify(title: "Keep Awake off", body: msg) }
        helper.onNewEvent = { [weak self] e in self?.notify(event: e) }

        HotKey.shared.action = { [weak self] in self?.setKeepAwake(!(self?.keepAwake.isActive ?? false)) }
        applyHotKey()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.shutdown() }
        }
        ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { _ in
            // Fast user switch: keep running; the helper keeps guarding via heartbeats.
        }
        #if DEBUG
        installDebugCommands()
        #endif
    }

    #if DEBUG
    /// DEBUG builds only: drive the app from a shell for testing, e.g.
    ///   scripts/debug-command.swift fan-max | fan-auto | fan-custom:4000 | install-helper | status
    /// Results are logged under subsystem dev.lidless.Lidless, category "debug".
    private func installDebugCommands() {
        let logger = os.Logger(subsystem: LidlessIDs.appBundleID, category: "debug")
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.lidless.debug.command"), object: nil, queue: .main
        ) { [weak self] note in
            let cmd = (note.object as? String) ?? ""
            Task { @MainActor in
                guard let self else { return }
                logger.notice("command: \(cmd, privacy: .public)")
                switch cmd {
                case "install-helper": self.helper.install()
                case "fan-max": self.setFanMode(.max)
                case "fan-auto": self.setFanMode(.auto)
                case let c where c.hasPrefix("fan-custom:"):
                    self.setFanMode(.custom, rpm: Double(c.dropFirst("fan-custom:".count)) ?? 4000)
                case "lid-on": self.setLidMode(true)
                case "lid-off": self.setLidMode(false)
                case "keep-awake-on": self.setKeepAwake(true)
                case "keep-awake-off": self.setKeepAwake(false)
                default: break
                }
                try? await Task.sleep(for: .seconds(2))
                let status = String(decoding: Wire.encode(self.helper.status), as: UTF8.self)
                logger.notice("phase=\(String(describing: self.helper.phase), privacy: .public) fanError=\(self.fanError ?? "-", privacy: .public) status=\(status, privacy: .public)")
            }
        }
    }
    #endif

    // MARK: Derived state

    var processName: String { defaults.string(forKey: Prefs.processName) ?? "claude" }
    var lidActive: Bool { helper.status?.lidModeActive ?? false }
    var fanMode: FanMode { pendingFanMode ?? helper.status?.fanMode ?? .auto }
    var hasFans: Bool { fanMonitor.fanCount > 0 }

    var iconState: IconState {
        if lidActive { return .lid }
        if keepAwake.isActive { return .awake }
        return .idle
    }

    var fansBlasting: Bool { (helper.status?.fanMode ?? .auto) != .auto }

    func endCondition() -> EndCondition {
        let now = Date()
        switch duration {
        case .indefinite: return .indefinite
        case .m30: return .until(now.addingTimeInterval(30 * 60))
        case .h1: return .until(now.addingTimeInterval(3600))
        case .h2: return .until(now.addingTimeInterval(2 * 3600))
        case .h4: return .until(now.addingTimeInterval(4 * 3600))
        case .until: return .until(untilDate)
        case .whileProcess: return .whileProcess(processName)
        }
    }

    var graceSeconds: TimeInterval { defaults.double(forKey: Prefs.graceMinutes) * 60 }

    func lidConfig() -> LidConfig {
        var c = LidConfig()
        c.endCondition = endCondition()
        c.acOnly = defaults.bool(forKey: Prefs.acOnly)
        c.batteryThreshold = defaults.integer(forKey: Prefs.batteryThreshold)
        c.maxSessionHours = defaults.double(forKey: Prefs.maxSessionHours)
        c.processGraceSeconds = graceSeconds
        c.displaySleepOnLidClose = defaults.bool(forKey: Prefs.displaySleepOnLidClose)
        c.sleepOnSafetyStop = defaults.bool(forKey: Prefs.sleepOnSafetyStop)
        return c
    }

    // MARK: Actions

    func setKeepAwake(_ on: Bool) {
        if on {
            keepAwake.start(endCondition(), keepDisplayOn: defaults.bool(forKey: Prefs.keepDisplayOn), graceSeconds: graceSeconds)
        } else {
            keepAwake.stop()
        }
    }

    func setLidMode(_ on: Bool) {
        lidError = nil
        guard on else { helper.disableLidMode(); return }
        if !defaults.bool(forKey: Prefs.lidWarningShown) {
            guard confirmLidWarning() else { return }
            defaults.set(true, forKey: Prefs.lidWarningShown)
        }
        lidBusy = true
        helper.enableLidMode(lidConfig()) { [weak self] err in
            self?.lidBusy = false
            self?.lidError = err
        }
    }

    /// Re-applies the chosen duration to whatever is running.
    func durationChanged() {
        if keepAwake.isActive { setKeepAwake(true) }
        if lidActive { helper.enableLidMode(lidConfig()) { [weak self] err in self?.lidError = err } }
    }

    /// Settings changed: push the new safety config to an active lid session.
    func settingsChanged() {
        if lidActive { helper.enableLidMode(lidConfig()) { [weak self] err in self?.lidError = err } }
        applyHotKey()
    }

    func setFanMode(_ mode: FanMode, rpm: Double? = nil) {
        os.Logger(subsystem: LidlessIDs.appBundleID, category: "ui").notice("fan mode -> \(String(describing: mode), privacy: .public)")
        fanError = nil
        pendingFanMode = mode
        let r = rpm ?? defaults.double(forKey: Prefs.customRPM)
        helper.setFanMode(mode, rpm: r) { [weak self] err in
            self?.pendingFanMode = nil
            self?.fanError = err
        }
    }

    func applyHotKey() {
        if defaults.bool(forKey: Prefs.hotkeyEnabled) {
            HotKey.shared.register(keyCode: UInt32(defaults.integer(forKey: Prefs.hotkeyCode)),
                                   modifiers: NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: Prefs.hotkeyMods))))
        } else {
            HotKey.shared.unregister()
        }
    }

    /// Quit / logout / power off: hand everything back.
    func shutdown() {
        keepAwake.stop()
        helper.restoreAllSync()
    }

    // MARK: UI helpers

    private func confirmLidWarning() -> Bool {
        let a = NSAlert()
        a.messageText = "Keep running with the lid closed?"
        a.informativeText = """
        This disables all system sleep (pmset disablesleep 1) so your Mac stays fully awake and online with the lid shut.

        A closed laptop in a bag can overheat. Lidless turns this off automatically on critical temperature, low battery, after the maximum session time, and (if you turn on “AC power only” in Settings) when you unplug power — but don't put a running Mac in a bag.
        """
        a.alertStyle = .warning
        a.addButton(withTitle: "Enable")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }

    private func notify(event e: SafetyEvent) {
        let title: String
        switch e.kind {
        case .thermalSerious: title = "Mac is running hot"
        case .thermalCritical: title = "Critical temperature"
        case .lowBattery, .onBattery: title = "Lid-closed mode off"
        case .maxSession, .endConditionReached: title = "Session ended"
        case .clientLost, .heartbeatLost: title = "Lidless restored settings"
        case .systemSleep: title = "Fans back to automatic"
        case .helperRecovered: title = "Lidless recovered"
        case .error: title = "Lidless error"
        }
        notify(title: title, body: e.message)
    }

    private func notify(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
