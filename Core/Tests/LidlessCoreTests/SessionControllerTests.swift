import XCTest
@testable import LidlessCore

// MARK: - Fakes

final class FakeSleep: SleepControlling {
    var disableSleep = 0
    var setCalls: [Int] = []
    var failSet = false
    var lidClosed = false
    var sleptNow = 0
    var displaySlept = 0
    func readDisableSleep() throws -> Int { disableSleep }
    func setDisableSleep(_ v: Int) throws {
        if failSet { throw NSError(domain: "t", code: 1) }
        setCalls.append(v); disableSleep = v
    }
    func displaySleepNow() { displaySlept += 1 }
    func sleepNow() { sleptNow += 1 }
    func isLidClosed() -> Bool { lidClosed }
}

final class FakeEnv: EnvironmentReading {
    var thermalLevel: ThermalLevel = .nominal
    var powerInfo = PowerInfo(onAC: true, batteryPercent: 80, isCharging: true)
    var running: Set<String> = []
    var date = Date(timeIntervalSince1970: 1_000_000)
    var up: TimeInterval = 100
    func thermal() -> ThermalLevel { thermalLevel }
    func power() -> PowerInfo { powerInfo }
    func isProcessRunning(_ name: String) -> Bool { running.contains(name) }
    func now() -> Date { date }
    func uptime() -> TimeInterval { up }
    func advance(_ s: TimeInterval) { date += s; up += s }
}

final class MemoryStore: StateStoring {
    var state: PersistedState?
    func load() -> PersistedState? { state }
    func save(_ s: PersistedState) throws { state = s }
    func clear() { state = nil }
}

final class FakeFans: FanControlling {
    var fanCount = 2
    var manual: [Int: Double] = [:]
    var restoreCalls = 0
    var reassertCalls = 0
    var failManual = false
    var restoreInfo = FanRestoreInfo()
    func readFans() -> [FanInfo] {
        (0..<fanCount).map { FanInfo(index: $0, actual: 2500, min: 2300, max: 6500 + Double($0), target: nil, mode: manual[$0] == nil ? 0 : 1) }
    }
    func setManual(targets: [Int: Double]) throws {
        if failManual { throw NSError(domain: "t", code: 2) }
        manual.merge(targets) { $1 }
    }
    func reassert(targets: [Int: Double]) -> Bool { reassertCalls += 1; return false }
    func restoreAuto(using info: FanRestoreInfo?) throws { restoreCalls += 1; manual = [:] }
}

// MARK: - Tests

final class SessionControllerTests: XCTestCase {
    var sleep: FakeSleep!, env: FakeEnv!, store: MemoryStore!, fans: FakeFans!, c: SessionController!
    let app = UUID()

    override func setUp() {
        sleep = FakeSleep(); env = FakeEnv(); store = MemoryStore(); fans = FakeFans()
        c = SessionController(sleep: sleep, env: env, store: store, fans: fans)
        c.clientConnected(app)
    }

    /// Advances time in 1 s steps, heartbeating from the app, ticking the controller.
    func run(seconds: Int, heartbeat: Bool = true) {
        for _ in 0..<seconds {
            env.advance(1)
            if heartbeat { c.heartbeat(app) }
            c.tick()
        }
    }

    func testEnableDisableRestoresOriginal() throws {
        try c.enableLid(config: LidConfig(), owner: app)
        XCTAssertEqual(sleep.disableSleep, 1)
        XCTAssertEqual(store.state?.lidModeActive, true)
        XCTAssertEqual(store.state?.originalDisableSleep, 0)
        c.disableLid()
        XCTAssertEqual(sleep.disableSleep, 0)
        XCTAssertNil(store.state, "state file removed once everything is restored")
    }

    func testRestoresNonZeroOriginalExactly() throws {
        sleep.disableSleep = 1   // user already had disablesleep on
        try c.enableLid(config: LidConfig(), owner: app)
        c.disableLid()
        XCTAssertEqual(sleep.disableSleep, 1)
    }

    func testStateIsPersistedBeforePMSetRuns() throws {
        sleep.failSet = true
        XCTAssertThrowsError(try c.enableLid(config: LidConfig(), owner: app))
        XCTAssertNil(store.state, "rolled back after a failed enable")
        XCTAssertFalse(c.status().lidModeActive)
    }

    func testClientDisconnectRestoresEverything() throws {
        try c.enableLid(config: LidConfig(), owner: app)
        try c.setFan(mode: .max, rpm: 0, owner: app)
        XCTAssertEqual(fans.manual, [0: 6500, 1: 6501])
        c.clientDisconnected(app)
        XCTAssertEqual(sleep.disableSleep, 0)
        XCTAssertEqual(fans.manual, [:])
        XCTAssertEqual(c.status().fanMode, .auto)
        XCTAssertNil(store.state)
    }

    func testHeartbeatLossRestoresWithinTimeout() throws {
        try c.enableLid(config: LidConfig(), owner: app)
        try c.setFan(mode: .custom, rpm: 4000, owner: app)
        run(seconds: 10)
        XCTAssertTrue(c.status().lidModeActive)
        run(seconds: Int(SessionController.heartbeatTimeout) + 1, heartbeat: false)
        XCTAssertFalse(c.status().lidModeActive)
        XCTAssertEqual(sleep.disableSleep, 0)
        XCTAssertEqual(c.status().fanMode, .auto)
        XCTAssertTrue(c.status().events.contains { $0.kind == .heartbeatLost })
    }

    func testBootRestoreAfterHelperCrash() {
        var s = PersistedState()
        s.lidModeActive = true
        s.originalDisableSleep = 0
        s.fanOverrideActive = true
        store.state = s
        sleep.disableSleep = 1
        let fresh = SessionController(sleep: sleep, env: env, store: store, fans: fans)
        fresh.bootRestore()
        XCTAssertEqual(sleep.disableSleep, 0)
        XCTAssertEqual(fans.restoreCalls, 1)
        XCTAssertNil(store.state)
        XCTAssertEqual(fresh.status().events.last?.kind, .helperRecovered)
    }

    func testBootWithoutStateTouchesNothing() {
        sleep.disableSleep = 1
        c.bootRestore()
        XCTAssertEqual(sleep.setCalls, [])
        XCTAssertEqual(fans.restoreCalls, 0)
    }

    func testThermalSeriousNotifiesOnly() throws {
        try c.enableLid(config: LidConfig(), owner: app)
        env.thermalLevel = .serious
        run(seconds: 2)
        XCTAssertTrue(c.status().lidModeActive)
        XCTAssertEqual(c.status().events.filter { $0.kind == .thermalSerious }.count, 1, "only on the transition")
    }

    func testThermalCriticalDisablesAndSleepsIfLidClosed() throws {
        try c.enableLid(config: LidConfig(), owner: app)
        try c.setFan(mode: .max, rpm: 0, owner: app)
        sleep.lidClosed = true
        env.thermalLevel = .critical
        run(seconds: 1)
        XCTAssertFalse(c.status().lidModeActive)
        XCTAssertEqual(sleep.disableSleep, 0)
        XCTAssertEqual(sleep.sleptNow, 1)
        XCTAssertEqual(c.status().fanMode, .auto)
    }

    func testBatteryGuard() throws {
        var cfg = LidConfig(); cfg.acOnly = false; cfg.batteryThreshold = 20
        env.powerInfo = PowerInfo(onAC: false, batteryPercent: 50, isCharging: false)
        try c.enableLid(config: cfg, owner: app)
        run(seconds: 2)
        XCTAssertTrue(c.status().lidModeActive)
        env.powerInfo.batteryPercent = 19
        run(seconds: 1)
        XCTAssertFalse(c.status().lidModeActive)
        XCTAssertTrue(c.status().events.contains { $0.kind == .lowBattery })
    }

    func testRefusesEnableBelowThreshold() {
        var cfg = LidConfig(); cfg.acOnly = false
        env.powerInfo = PowerInfo(onAC: false, batteryPercent: 10, isCharging: false)
        XCTAssertThrowsError(try c.enableLid(config: cfg, owner: app))
        XCTAssertEqual(sleep.setCalls, [])
    }

    func testDefaultConfigWorksOnBattery() throws {
        XCTAssertFalse(LidConfig().acOnly, "lid mode runs on battery unless AC-only is opted into")
        env.powerInfo = PowerInfo(onAC: false, batteryPercent: 60, isCharging: false)
        try c.enableLid(config: LidConfig(), owner: app)
        run(seconds: 60)
        XCTAssertTrue(c.status().lidModeActive)
        XCTAssertEqual(sleep.disableSleep, 1)
        env.powerInfo.batteryPercent = 19   // battery guard still applies
        run(seconds: 1)
        XCTAssertFalse(c.status().lidModeActive)
        XCTAssertTrue(c.status().events.contains { $0.kind == .lowBattery })
    }

    func testACOnly() throws {
        var acOnly = LidConfig(); acOnly.acOnly = true
        env.powerInfo = PowerInfo(onAC: false, batteryPercent: 90, isCharging: false)
        XCTAssertThrowsError(try c.enableLid(config: acOnly, owner: app))
        env.powerInfo.onAC = true
        try c.enableLid(config: acOnly, owner: app)
        env.powerInfo.onAC = false   // unplugged
        run(seconds: 1)
        XCTAssertFalse(c.status().lidModeActive)
        XCTAssertTrue(c.status().events.contains { $0.kind == .onBattery })
    }

    func testMaxSessionTimer() throws {
        var cfg = LidConfig(); cfg.maxSessionHours = 1
        try c.enableLid(config: cfg, owner: app)
        run(seconds: 3599)
        XCTAssertTrue(c.status().lidModeActive)
        run(seconds: 1)
        XCTAssertFalse(c.status().lidModeActive)
        XCTAssertTrue(c.status().events.contains { $0.kind == .maxSession })
    }

    func testUntilDate() throws {
        var cfg = LidConfig(); cfg.endCondition = .until(env.date + 30)
        try c.enableLid(config: cfg, owner: app)
        XCTAssertEqual(c.status().lidEndsAt, env.date + 30)
        run(seconds: 29)
        XCTAssertTrue(c.status().lidModeActive)
        run(seconds: 1)
        XCTAssertFalse(c.status().lidModeActive)
    }

    func testProcessLinkedWithGrace() throws {
        var cfg = LidConfig(); cfg.endCondition = .whileProcess("claude"); cfg.processGraceSeconds = 120
        env.running = ["claude"]
        try c.enableLid(config: cfg, owner: app)
        run(seconds: 600)
        XCTAssertTrue(c.status().lidModeActive)
        env.running = []
        run(seconds: 119)
        XCTAssertTrue(c.status().lidModeActive, "still within the grace period")
        env.running = ["claude"]   // came back: grace resets
        run(seconds: 10)
        env.running = []
        run(seconds: 119)
        XCTAssertTrue(c.status().lidModeActive)
        run(seconds: 2)
        XCTAssertFalse(c.status().lidModeActive)
    }

    func testDisplaySleepsWhenLidCloses() throws {
        try c.enableLid(config: LidConfig(), owner: app)
        run(seconds: 1)
        XCTAssertEqual(sleep.displaySlept, 0)
        sleep.lidClosed = true
        run(seconds: 3)
        XCTAssertEqual(sleep.displaySlept, 1, "once per close")
    }

    func testFanFailureRollsBackToAuto() {
        fans.failManual = true
        XCTAssertThrowsError(try c.setFan(mode: .max, rpm: 0, owner: app))
        XCTAssertEqual(c.status().fanMode, .auto)
        XCTAssertEqual(fans.restoreCalls, 1)
        XCTAssertNil(store.state)
    }

    func testCustomRPMIsClampedAndPersisted() throws {
        try c.setFan(mode: .custom, rpm: 99_999, owner: app)
        XCTAssertEqual(fans.manual[0], 6500)
        XCTAssertEqual(store.state?.fanOverrideActive, true)
        try c.setFan(mode: .custom, rpm: 10, owner: app)
        XCTAssertEqual(fans.manual[0], 2300)
    }

    func testFansReassertedPeriodically() throws {
        try c.setFan(mode: .max, rpm: 0, owner: app)
        run(seconds: 10)
        XCTAssertEqual(fans.reassertCalls, 2)
    }

    func testSystemSleepRestoresFansButKeepsLidMode() throws {
        try c.enableLid(config: LidConfig(), owner: app)
        try c.setFan(mode: .max, rpm: 0, owner: app)
        c.willSleep()
        XCTAssertEqual(c.status().fanMode, .auto)
        XCTAssertTrue(c.status().lidModeActive)
    }

    func testWakeDoesNotCountAsHeartbeatLoss() throws {
        try c.enableLid(config: LidConfig(), owner: app)
        env.date += 3600          // wall clock jumps while asleep; uptime does not
        c.didWake()
        c.tick()
        XCTAssertTrue(c.status().lidModeActive)
    }

    func testFanlessMacHasNoFanControl() {
        fans.fanCount = 0
        let air = SessionController(sleep: sleep, env: env, store: store, fans: fans)
        XCTAssertFalse(air.status().fanControlAvailable)
        XCTAssertThrowsError(try air.setFan(mode: .max, rpm: 0, owner: app))
    }

    func testStatusRoundTripsOverWire() throws {
        try c.enableLid(config: LidConfig(), owner: app)
        let decoded = Wire.decode(HelperStatus.self, Wire.encode(c.status()))
        XCTAssertEqual(decoded?.lidModeActive, true)
        XCTAssertEqual(decoded?.lidConfig, LidConfig())
    }
}
