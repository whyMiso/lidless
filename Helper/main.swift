import Foundation
import IOKit
import IOKit.pwr_mgt
import os
import LidlessCore

// Lidless privileged helper (LaunchDaemon, runs as root).
// The ONLY component that touches pmset and writes the SMC. It owns all state and restores it
// when the app disconnects, stops heart-beating, or when this process itself (re)starts.

let logger = Logger(subsystem: LidlessIDs.helperBundleID, category: "helper")
func log(_ s: String) { logger.notice("\(s, privacy: .public)") }

if CommandLine.arguments.contains("--read-only") {
    exit(SMCReport.run(all: CommandLine.arguments.contains("--all")))
}

guard getuid() == 0 else {
    FileHandle.standardError.write("LidlessHelper must run as root (via launchd). Use --read-only to inspect the SMC.\n".data(using: .utf8)!)
    exit(1)
}

let teamID = (Bundle.main.object(forInfoDictionaryKey: "LidlessTeamID") as? String) ?? ""
guard !teamID.isEmpty else {
    log("missing LidlessTeamID in embedded Info.plist; refusing to run")
    exit(1)
}

let queue = DispatchQueue(label: "dev.lidless.helper.state")
let fans: SMCFanController? = (try? SMC()).map { SMCFanController(smc: $0, log: log) }
#if DEBUG
/// DEBUG builds only: lets you simulate thermal/battery conditions for the testing checklist by
/// writing root-owned JSON, e.g.
///   echo '{"thermal":"critical"}' | sudo tee "/Library/Application Support/Lidless/simulate.json"
///   echo '{"onAC":false,"batteryPercent":15}' | sudo tee ...   — delete the file to stop.
final class SimulatedEnvironment: EnvironmentReading {
    struct Overrides: Decodable { var thermal: ThermalLevel?; var onAC: Bool?; var batteryPercent: Int? }
    private let base = SystemEnvironment()
    private let url = URL(fileURLWithPath: LidlessIDs.stateDirectory + "/simulate.json")
    private var o: Overrides? { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Overrides.self, from: $0) } }
    func thermal() -> ThermalLevel { o?.thermal ?? base.thermal() }
    func power() -> PowerInfo {
        var p = base.power()
        if let o { p.onAC = o.onAC ?? p.onAC; p.batteryPercent = o.batteryPercent ?? p.batteryPercent }
        return p
    }
    func isProcessRunning(_ name: String) -> Bool { base.isProcessRunning(name) }
    func now() -> Date { base.now() }
    func uptime() -> TimeInterval { base.uptime() }
}
let environment: EnvironmentReading = SimulatedEnvironment()
#else
let environment: EnvironmentReading = SystemEnvironment()
#endif

let controller = SessionController(
    sleep: PMSetSleepControl(), env: environment, store: FileStateStore(), fans: fans, log: log)

queue.sync { controller.bootRestore() }
log("helper started (fans=\(fans?.fanCount ?? 0), platform=\(fans?.platform.rawValue ?? "n/a"))")

// MARK: - 1 Hz watchdog / safety guards

let ticker = DispatchSource.makeTimerSource(queue: queue)
ticker.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
ticker.setEventHandler { controller.tick() }
ticker.resume()

// MARK: - Restore on SIGTERM (launchd stop, unregister, shutdown)

signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
sigterm.setEventHandler {
    log("SIGTERM: restoring and exiting")
    controller.restoreAll()
    exit(0)
}
sigterm.resume()

// MARK: - System sleep / wake

// iokit_common_msg(x) = sys_iokit | sub_iokit_common | x — the C macros don't import into Swift.
let kMsgCanSystemSleep: UInt32 = 0xE000_0270
let kMsgSystemWillSleep: UInt32 = 0xE000_0280
let kMsgSystemHasPoweredOn: UInt32 = 0xE000_0300

var rootPort: io_connect_t = 0
var notifierObject: io_object_t = 0
var notifyPortRef: IONotificationPortRef?

private func powerCallback(_: UnsafeMutableRawPointer?, _: io_service_t, _ type: UInt32, _ arg: UnsafeMutableRawPointer?) {
    let notificationID = Int(bitPattern: arg)
    switch type {
    case kMsgCanSystemSleep:
        IOAllowPowerChange(rootPort, notificationID)
    case kMsgSystemWillSleep:
        queue.sync { controller.willSleep() }
        IOAllowPowerChange(rootPort, notificationID)
    case kMsgSystemHasPoweredOn:
        queue.async { controller.didWake() }
    default:
        break
    }
}

rootPort = IORegisterForSystemPower(nil, &notifyPortRef, powerCallback, &notifierObject)
if rootPort != 0, let port = notifyPortRef {
    IONotificationPortSetDispatchQueue(port, DispatchQueue(label: "dev.lidless.helper.power"))
} else {
    log("IORegisterForSystemPower failed; fans will not be restored before sleep")
}

// MARK: - XPC

final class HelperService: NSObject, LidlessHelperProtocol {
    let id = UUID()

    func hello(clientVersion: Int, reply: @escaping (Int) -> Void) {
        queue.async { controller.heartbeat(self.id); reply(LidlessIDs.helperProtocolVersion) }
    }

    func heartbeat(reply: @escaping (Data) -> Void) {
        queue.async {
            controller.heartbeat(self.id)
            reply(Wire.encode(controller.status()))
        }
    }

    func enableLidMode(config: Data, reply: @escaping (String?) -> Void) {
        queue.async {
            guard let cfg = Wire.decode(LidConfig.self, config) else { return reply("Invalid configuration") }
            do { try controller.enableLid(config: cfg, owner: self.id); reply(nil) }
            catch { reply(error.localizedDescription) }
        }
    }

    func disableLidMode(reply: @escaping (String?) -> Void) {
        queue.async { controller.disableLid(); reply(nil) }
    }

    func setFanMode(_ mode: Int, rpm: Double, reply: @escaping (String?) -> Void) {
        queue.async {
            guard let m = FanMode(rawValue: mode) else { return reply("Invalid fan mode") }
            do { try controller.setFan(mode: m, rpm: rpm, owner: self.id); reply(nil) }
            catch { reply("\(error)") }
        }
    }

    func restoreAll(reply: @escaping () -> Void) {
        queue.async { controller.restoreAll(); reply() }
    }

    func shutdownForUpgrade(reply: @escaping () -> Void) {
        queue.async {
            log("shutting down for upgrade")
            controller.restoreAll()
            reply()
            queue.asyncAfter(deadline: .now() + 0.5) { exit(0) }
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let requirement = LidlessIDs.requirement(identifier: LidlessIDs.appBundleID, teamID: teamID)

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        // The kernel-verified audit token of the peer is checked against this requirement for
        // every message; a non-matching client's messages are rejected and the connection invalidated.
        c.setCodeSigningRequirement(requirement)

        let service = HelperService()
        let id = service.id
        let pid = c.processIdentifier
        c.exportedInterface = XPCInterface.make()
        c.exportedObject = service
        c.invalidationHandler = {
            log("client \(pid) disconnected")
            queue.async { controller.clientDisconnected(id) }
        }
        c.interruptionHandler = c.invalidationHandler
        queue.async { controller.clientConnected(id) }
        c.resume()
        log("accepted connection from pid \(pid)")
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: LidlessIDs.helperMachService)
listener.delegate = delegate
listener.resume()

dispatchMain()
