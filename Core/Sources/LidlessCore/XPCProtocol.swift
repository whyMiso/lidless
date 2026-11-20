import Foundation

/// App → helper interface. Payloads are JSON (`Wire`) to keep the ObjC surface tiny.
/// Every call that changes state is bound to the calling connection: when that connection
/// drops (quit, crash, kill -9) or stops sending heartbeats, the helper restores everything.
@objc public protocol LidlessHelperProtocol {
    /// Returns the helper's protocol version.
    func hello(clientVersion: Int, reply: @escaping (Int) -> Void)
    /// Must be called every ~2 s while anything is active. Replies with `HelperStatus` JSON.
    func heartbeat(reply: @escaping (Data) -> Void)
    /// `config` is `LidConfig` JSON. Replies with an error message on failure, nil on success.
    func enableLidMode(config: Data, reply: @escaping (String?) -> Void)
    func disableLidMode(reply: @escaping (String?) -> Void)
    /// `mode` is a `FanMode` raw value; `rpm` used only for `.custom`.
    func setFanMode(_ mode: Int, rpm: Double, reply: @escaping (String?) -> Void)
    /// Restore everything (used on app quit/logout).
    func restoreAll(reply: @escaping () -> Void)
    /// Restore everything and exit so launchd can start a newer helper binary.
    func shutdownForUpgrade(reply: @escaping () -> Void)
}

public enum XPCInterface {
    public static func make() -> NSXPCInterface {
        NSXPCInterface(with: LidlessHelperProtocol.self)
    }
}
