import Foundation

// MARK: - Injectable dependencies (real implementations below; fakes in tests)

public protocol SleepControlling {
    func readDisableSleep() throws -> Int
    func setDisableSleep(_ value: Int) throws
    func displaySleepNow()
    func sleepNow()
    func isLidClosed() -> Bool
}

public protocol EnvironmentReading {
    func thermal() -> ThermalLevel
    func power() -> PowerInfo
    func isProcessRunning(_ name: String) -> Bool
    func now() -> Date
    func uptime() -> TimeInterval
}

public protocol StateStoring {
    func load() -> PersistedState?
    func save(_ state: PersistedState) throws
    func clear()
}

// MARK: - Controller

/// The helper's brain. Owns all privileged state and is responsible for restoring it.
/// Not thread-safe: the helper calls everything on one serial queue.
public final class SessionController {
    public static let heartbeatTimeout: TimeInterval = 6
    public static let maxEvents = 20

    private let sleep: SleepControlling
    private let env: EnvironmentReading
    private let store: StateStoring
    private let fans: FanControlling?
    private let log: (String) -> Void

    // Lid mode
    private(set) var lidActive = false
    private var lidOwner: UUID?
    private var lidConfig = LidConfig()
    private var lidStartedAt: Date?
    private var originalDisableSleep: Int?
    private var processLastSeen: TimeInterval = 0
    private var lidWasClosed = false
    private var pendingSleepRestore: Int?     // a restore that failed and must be retried

    // Fans
    private(set) var fanMode: FanMode = .auto
    private var fanTargets: [Int: Double] = [:]
    private var fanOwner: UUID?
    private var tickCount = 0

    // Clients
    private var lastHeartbeat: [UUID: TimeInterval] = [:]

    // Reporting
    private var events: [SafetyEvent] = []
    private var nextEventID = 1
    private var lastThermal: ThermalLevel = .nominal
    private var lastError: String?

    public init(sleep: SleepControlling, env: EnvironmentReading, store: StateStoring,
                fans: FanControlling?, log: @escaping (String) -> Void = { _ in }) {
        self.sleep = sleep
        self.env = env
        self.store = store
        self.fans = (fans?.fanCount ?? 0) > 0 ? fans : nil
        self.log = log
    }

    // MARK: Boot

    /// Called once at helper launch. If a previous helper instance died (or the machine rebooted)
    /// mid-session, put the original settings back.
    public func bootRestore() {
        guard let s = store.load(), s.needsRestore else { store.clear(); return }
        var parts: [String] = []
        if s.lidModeActive {
            let original = s.originalDisableSleep ?? 0
            do { try sleep.setDisableSleep(original); parts.append("disablesleep \(original)") }
            catch { pendingSleepRestore = original; record(error) }
        }
        if s.fanOverrideActive, let fans {
            do { try fans.restoreAuto(using: s.fanRestore); parts.append("fans auto") } catch { record(error) }
        }
        addEvent(.helperRecovered, "Recovered from an interrupted session: restored \(parts.joined(separator: ", ")).")
        if pendingSleepRestore == nil { store.clear() }
    }

    // MARK: Clients

    public func clientConnected(_ id: UUID) { lastHeartbeat[id] = env.uptime() }

    public func heartbeat(_ id: UUID) { lastHeartbeat[id] = env.uptime() }

    public func clientDisconnected(_ id: UUID) {
        lastHeartbeat[id] = nil
        if lidOwner == id { disableLid(reason: .clientLost, "Lidless app disconnected; lid-closed mode turned off.", automatic: true) }
        if fanOwner == id { restoreFans(reason: .clientLost, "Lidless app disconnected; fans returned to automatic.") }
    }

    /// The system woke: uptime-based heartbeat stamps are still valid, but refresh them anyway so
    /// the app gets a grace period to reconnect.
    public func didWake() {
        let now = env.uptime()
        for k in lastHeartbeat.keys { lastHeartbeat[k] = now }
    }

    public func willSleep() {
        if fanMode != .auto { restoreFans(reason: .systemSleep, "System is sleeping; fans returned to automatic.") }
    }

    // MARK: Lid mode

    public func enableLid(config: LidConfig, owner: UUID) throws {
        let p = env.power()
        if config.acOnly && !p.onAC {
            throw err("Lid-closed mode is set to AC power only. Connect power first, or turn off “AC power only” in Settings.")
        }
        if !p.onAC, let pct = p.batteryPercent, pct < config.batteryThreshold {
            throw err("Battery is at \(pct)%, below the \(config.batteryThreshold)% safety threshold.")
        }
        if env.thermal() >= .critical { throw err("The Mac is too hot (thermal state critical).") }

        lidConfig = config
        lidOwner = owner
        processLastSeen = env.uptime()
        if lidActive { persist(); return }   // already on: just update config/owner

        let original = try sleep.readDisableSleep()
        // Persist BEFORE changing anything so a crash in between still restores.
        originalDisableSleep = original
        lidActive = true
        lidStartedAt = env.now()
        lidWasClosed = sleep.isLidClosed()
        persist()
        do {
            try sleep.setDisableSleep(1)
        } catch {
            lidActive = false; lidOwner = nil; lidStartedAt = nil; originalDisableSleep = nil
            persist()
            throw error
        }
        log("lid mode ON (original disablesleep=\(original))")
    }

    public func disableLid(reason: SafetyEvent.Kind? = nil, _ message: String? = nil, automatic: Bool = false) {
        guard lidActive else { return }
        let original = originalDisableSleep ?? 0
        do {
            try sleep.setDisableSleep(original)
            pendingSleepRestore = nil
        } catch {
            pendingSleepRestore = original
            record(error)
        }
        lidActive = false
        lidOwner = nil
        lidStartedAt = nil
        originalDisableSleep = nil
        persist()
        if let reason, let message { addEvent(reason, message) }
        log("lid mode OFF (restored disablesleep=\(original)) reason=\(reason?.rawValue ?? "user")")
        if automatic && lidConfig.sleepOnSafetyStop && sleep.isLidClosed() {
            log("lid is closed after automatic stop; sleeping now")
            sleep.sleepNow()
        }
    }

    // MARK: Fans

    public func setFan(mode: FanMode, rpm: Double, owner: UUID) throws {
        guard let fans else { throw err("This Mac has no controllable fans.") }
        if mode == .auto { restoreFans(); return }
        if env.thermal() >= .critical { throw err("Thermal state is critical; leaving fans under system control.") }

        let readings = fans.readFans()
        var targets: [Int: Double] = [:]
        for f in readings { targets[f.index] = mode == .max ? f.max : Swift.min(Swift.max(rpm, f.min), f.max) }

        fanOwner = owner
        let wasAuto = fanMode == .auto
        fanMode = mode
        fanTargets = targets
        persist()   // record the override before touching the SMC
        do {
            try fans.setManual(targets: targets)
            persist()   // now includes any restore info (e.g. Ftst used)
        } catch {
            if wasAuto { restoreFans() }
            throw error
        }
    }

    private func restoreFans(reason: SafetyEvent.Kind? = nil, _ message: String? = nil) {
        guard let fans else { return }
        let hadOverride = fanMode != .auto
        do { try fans.restoreAuto(using: nil) } catch { record(error) }
        fanMode = .auto
        fanTargets = [:]
        fanOwner = nil
        persist()
        if hadOverride, let reason, let message { addEvent(reason, message) }
    }

    // MARK: Restore all

    public func restoreAll(reason: SafetyEvent.Kind? = nil, _ message: String? = nil) {
        disableLid(reason: reason, message)
        restoreFans()
    }

    // MARK: Periodic checks (call ~1 Hz)

    public func tick() {
        tickCount += 1
        let now = env.uptime()

        if let v = pendingSleepRestore, !lidActive {
            if (try? sleep.setDisableSleep(v)) != nil { pendingSleepRestore = nil; persist() }
        }

        // Heartbeats: an owner that went silent is treated as gone.
        for owner in Set([lidOwner, fanOwner].compactMap { $0 }) {
            let last = lastHeartbeat[owner] ?? 0
            if now - last > Self.heartbeatTimeout {
                lastHeartbeat[owner] = nil
                if lidOwner == owner {
                    disableLid(reason: .heartbeatLost, "Lost contact with the Lidless app; lid-closed mode turned off.", automatic: true)
                }
                if fanOwner == owner { restoreFans(reason: .heartbeatLost, "Lost contact with the Lidless app; fans returned to automatic.") }
            }
        }

        // Thermal guard (applies to fans and lid mode).
        let thermal = env.thermal()
        if thermal >= .serious && lastThermal < .serious && thermal < .critical {
            addEvent(.thermalSerious, "Mac is running hot (thermal state serious).")
        }
        if thermal >= .critical {
            if lidActive {
                disableLid(reason: .thermalCritical, "Thermal state critical: lid-closed mode turned off so the Mac can sleep.", automatic: true)
            }
            if fanMode != .auto { restoreFans(reason: .thermalCritical, "Thermal state critical: fans handed back to the system.") }
        }
        lastThermal = thermal

        if lidActive { checkLidGuards() }

        if fanMode != .auto, let fans, tickCount % 5 == 0 {
            fans.reassert(targets: fanTargets)
        }
    }

    private func checkLidGuards() {
        let p = env.power()
        if lidConfig.acOnly && !p.onAC {
            return disableLid(reason: .onBattery, "Switched to battery: lid-closed mode turned off (AC-only is on).", automatic: true)
        }
        if !p.onAC, let pct = p.batteryPercent, pct < lidConfig.batteryThreshold {
            return disableLid(reason: .lowBattery, "Battery at \(pct)%: lid-closed mode turned off.", automatic: true)
        }
        if let start = lidStartedAt, env.now().timeIntervalSince(start) >= lidConfig.maxSessionHours * 3600 {
            return disableLid(reason: .maxSession, "Reached the \(formatHours(lidConfig.maxSessionHours)) maximum session; lid-closed mode turned off.", automatic: true)
        }
        switch lidConfig.endCondition {
        case .indefinite: break
        case .until(let date):
            if env.now() >= date {
                return disableLid(reason: .endConditionReached, "Lid-closed session ended as scheduled.", automatic: true)
            }
        case .whileProcess(let name):
            let now = env.uptime()
            if env.isProcessRunning(name) {
                processLastSeen = now
            } else if now - processLastSeen >= lidConfig.processGraceSeconds {
                return disableLid(reason: .endConditionReached, "`\(name)` is no longer running; lid-closed mode turned off.", automatic: true)
            }
        }
        // Dark screen when the lid closes.
        let closed = sleep.isLidClosed()
        if closed && !lidWasClosed && lidConfig.displaySleepOnLidClose { sleep.displaySleepNow() }
        lidWasClosed = closed
    }

    // MARK: Status

    public func status() -> HelperStatus {
        var s = HelperStatus()
        s.lidModeActive = lidActive
        s.lidStartedAt = lidStartedAt
        s.lidConfig = lidActive ? lidConfig : nil
        if let start = lidStartedAt {
            var end = start.addingTimeInterval(lidConfig.maxSessionHours * 3600)
            if case .until(let d) = lidConfig.endCondition { end = min(end, d) }
            s.lidEndsAt = end
        }
        s.originalDisableSleep = originalDisableSleep
        s.currentDisableSleep = try? sleep.readDisableSleep()
        s.fanMode = fanMode
        s.fanTargetRPM = fanTargets.values.max()
        s.fanControlAvailable = fans != nil
        s.thermal = env.thermal()
        s.power = env.power()
        s.events = events
        s.lastError = lastError
        return s
    }

    // MARK: Helpers

    private func persist() {
        var s = PersistedState()
        s.lidModeActive = lidActive || pendingSleepRestore != nil
        s.originalDisableSleep = originalDisableSleep ?? pendingSleepRestore
        s.fanOverrideActive = fanMode != .auto
        s.fanRestore = fanMode != .auto ? fans?.restoreInfo : nil
        s.writtenAt = env.now()
        if s.needsRestore {
            do { try store.save(s) } catch { record(error) }
        } else {
            store.clear()
        }
    }

    private func addEvent(_ kind: SafetyEvent.Kind, _ message: String) {
        events.append(SafetyEvent(id: nextEventID, kind: kind, message: message, date: env.now()))
        nextEventID += 1
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
        log("event \(kind.rawValue): \(message)")
    }

    private func record(_ error: Error) {
        lastError = "\(error)"
        log("error: \(error)")
    }

    private func err(_ msg: String) -> NSError {
        NSError(domain: "Lidless", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private func formatHours(_ h: Double) -> String {
        h == h.rounded() ? "\(Int(h)) h" : String(format: "%.1f h", h)
    }
}

// MARK: - Real implementations

public final class PMSetSleepControl: SleepControlling {
    public init() {}
    public func readDisableSleep() throws -> Int { PMSet.parseDisableSleep(try PMSet.run(["-g"])) }
    public func setDisableSleep(_ value: Int) throws { try PMSet.run(["-a", "disablesleep", String(value)]) }
    public func displaySleepNow() { _ = try? PMSet.run(["displaysleepnow"]) }
    public func sleepNow() { _ = try? PMSet.run(["sleepnow"]) }
    public func isLidClosed() -> Bool { Clamshell.isClosed() }
}

public final class SystemEnvironment: EnvironmentReading {
    public init() {}
    public func thermal() -> ThermalLevel { ThermalLevel(ProcessInfo.processInfo.thermalState) }
    public func power() -> PowerInfo { PowerSource.current() }
    public func isProcessRunning(_ name: String) -> Bool { ProcessFinder.isRunning(name) }
    public func now() -> Date { Date() }
    public func uptime() -> TimeInterval { uptimeSeconds() }
}

public final class FileStateStore: StateStoring {
    let url: URL
    public init(path: String = LidlessIDs.stateFile) { url = URL(fileURLWithPath: path) }

    public func load() -> PersistedState? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return Wire.decode(PersistedState.self, d)
    }

    public func save(_ state: PersistedState) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try Wire.encode(state).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    public func clear() { try? FileManager.default.removeItem(at: url) }
}
