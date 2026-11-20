import Foundation
import ServiceManagement
import os
import LidlessCore

private let log = Logger(subsystem: LidlessIDs.appBundleID, category: "helper-client")

/// Registers the privileged helper with SMAppService and talks to it over XPC.
/// Sends a heartbeat every 2 s; the helper restores everything if heartbeats stop.
@MainActor
final class HelperClient: ObservableObject {
    enum Phase: Equatable {
        case notInstalled
        case needsApproval
        case connecting
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .notInstalled
    @Published private(set) var status: HelperStatus?
    var onNewEvent: ((SafetyEvent) -> Void)?

    private let service = SMAppService.daemon(plistName: LidlessIDs.helperPlistName)
    private var connection: NSXPCConnection?
    private var timer: Timer?
    private var lastEventID = 0
    private let launchedAt = Date()
    private var upgradeAttempted = false
    private var versionChecked = false

    private var teamID: String { (Bundle.main.object(forInfoDictionaryKey: "LidlessTeamID") as? String) ?? "" }

    init() {
        refreshPhase()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    var isReady: Bool { phase == .ready && status != nil }

    // MARK: Registration

    func refreshPhase() {
        switch service.status {
        case .enabled: if phase != .ready { phase = .connecting }
        case .requiresApproval: phase = .needsApproval; dropConnection()
        case .notRegistered, .notFound: phase = .notInstalled; dropConnection()
        @unknown default: phase = .notInstalled
        }
    }

    func install() {
        do {
            try service.register()
        } catch {
            // Registering returns an error when the user still has to approve it; that's expected.
            log.notice("register: \(error.localizedDescription, privacy: .public)")
        }
        refreshPhase()
        if phase == .needsApproval { SMAppService.openSystemSettingsLoginItems() }
        if case .notInstalled = phase { phase = .failed("Could not register the helper. Is Lidless in /Applications and properly signed?") }
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    func uninstall() {
        restoreAllSync()
        dropConnection()
        try? service.unregister()
        status = nil
        refreshPhase()
    }

    // MARK: Connection

    private func makeConnection() -> NSXPCConnection {
        let c = NSXPCConnection(machServiceName: LidlessIDs.helperMachService, options: .privileged)
        c.remoteObjectInterface = XPCInterface.make()
        // Only talk to a helper signed by the same team with the expected identifier.
        c.setCodeSigningRequirement(LidlessIDs.requirement(identifier: LidlessIDs.helperBundleID, teamID: teamID))
        c.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.versionChecked = false
                if self?.phase == .ready { self?.phase = .connecting }
            }
        }
        c.interruptionHandler = { [weak self] in
            // Helper crashed/restarted; it restores state on launch. We reconnect on next tick.
            Task { @MainActor in self?.versionChecked = false }
        }
        c.resume()
        return c
    }

    private func dropConnection() {
        connection?.invalidate()
        connection = nil
        versionChecked = false
    }

    private func proxy(_ onError: @escaping (Error) -> Void = { _ in }) -> LidlessHelperProtocol? {
        if connection == nil { connection = makeConnection() }
        return connection?.remoteObjectProxyWithErrorHandler { error in
            log.error("xpc: \(error.localizedDescription, privacy: .public)")
            onError(error)
        } as? LidlessHelperProtocol
    }

    private func tick() {
        refreshPhase()
        guard service.status == .enabled else { return }
        if !versionChecked { checkVersion(); return }
        refresh()
    }

    /// Heartbeat + status fetch; `then` runs once fresh status has been applied (or on error).
    private func refresh(then: (() -> Void)? = nil) {
        proxy({ [weak self] _ in
            Task { @MainActor in
                self?.status = nil
                self?.phase = .connecting
                then?()
            }
        })?.heartbeat { [weak self] data in
            let s = Wire.decode(HelperStatus.self, data)
            Task { @MainActor in self?.receive(s); then?() }
        }
    }

    private func checkVersion() {
        proxy()?.hello(clientVersion: LidlessIDs.helperProtocolVersion) { [weak self] v in
            Task { @MainActor in
                guard let self else { return }
                if v == LidlessIDs.helperProtocolVersion {
                    self.versionChecked = true
                } else if !self.upgradeAttempted {
                    // An older helper binary is still running: ask it to restore + exit so launchd
                    // starts the one inside the current app bundle.
                    self.upgradeAttempted = true
                    self.proxy()?.shutdownForUpgrade { Task { @MainActor in self.dropConnection() } }
                } else {
                    self.phase = .failed("Helper version \(v) doesn't match app (\(LidlessIDs.helperProtocolVersion)). Reinstall the helper from Settings.")
                }
            }
        }
    }

    private func receive(_ s: HelperStatus?) {
        guard let s else { return }
        status = s
        phase = .ready
        for e in s.events where e.id > lastEventID {
            if e.date > launchedAt.addingTimeInterval(-120) { onNewEvent?(e) }
        }
        lastEventID = max(lastEventID, s.events.map(\.id).max() ?? 0)
    }

    // MARK: Commands

    func enableLidMode(_ cfg: LidConfig, completion: @escaping (String?) -> Void) {
        guard let p = proxy({ e in Task { @MainActor in completion(e.localizedDescription) } }) else {
            return completion("Helper not available")
        }
        p.enableLidMode(config: Wire.encode(cfg)) { err in
            Task { @MainActor in self.refresh { completion(err) } }
        }
    }

    func disableLidMode() {
        proxy()?.disableLidMode { _ in Task { @MainActor in self.refresh() } }
    }

    func setFanMode(_ mode: FanMode, rpm: Double, completion: @escaping (String?) -> Void) {
        guard let p = proxy({ e in Task { @MainActor in completion(e.localizedDescription) } }) else {
            return completion("Helper not available")
        }
        p.setFanMode(mode.rawValue, rpm: rpm) { err in
            Task { @MainActor in self.refresh { completion(err) } }
        }
    }

    /// Blocking restore used on quit / logout / power-off. Bounded to ~2 s.
    func restoreAllSync() {
        guard service.status == .enabled, connection != nil else { return }
        let done = DispatchSemaphore(value: 0)
        let p = connection?.remoteObjectProxyWithErrorHandler { _ in done.signal() } as? LidlessHelperProtocol
        p?.restoreAll { done.signal() }
        _ = done.wait(timeout: .now() + 2)
    }
}
