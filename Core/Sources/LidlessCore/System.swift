import Foundation
import IOKit
import IOKit.ps
import Darwin

// MARK: - Power source

public enum PowerSource {
    public static func current() -> PowerInfo {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerInfo(onAC: true, batteryPercent: nil, isCharging: false)
        }
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        let onAC = providing != kIOPSBatteryPowerValue
        var percent: Int?
        var charging = false
        if let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                      (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
                if let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    percent = Int((Double(cur) / Double(max) * 100).rounded())
                }
                charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
            }
        }
        return PowerInfo(onAC: onAC, batteryPercent: percent, isCharging: charging)
    }
}

// MARK: - Lid (clamshell) state

public enum Clamshell {
    public static func isClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(root) }
        let v = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (v as? Bool) ?? false
    }
}

// MARK: - Process lookup

public enum ProcessFinder {
    /// True if any process is named `name` (exact executable name), or was launched as `name`
    /// (argv[0] basename — covers node-based CLIs that set process.title, e.g. `claude`).
    /// Matching is case-sensitive so `claude` does not match the `Claude` desktop app.
    public static func isRunning(_ name: String) -> Bool {
        !pids(named: name).isEmpty
    }

    public static func pids(named name: String) -> [pid_t] {
        guard !name.isEmpty else { return [] }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }
        return pids.prefix(Int(n)).filter { pid in
            guard pid > 0 else { return false }
            return matches(name: name, executable: executableName(pid), argv0: argv0(pid))
        }
    }

    public static func matches(name: String, executable: String?, argv0: String?) -> Bool {
        if executable == name { return true }
        if let a = argv0, (a as NSString).lastPathComponent == name { return true }
        return false
    }

    static func executableName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let r = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard r > 0 else { return nil }
        return (String(cString: buf) as NSString).lastPathComponent
    }

    /// argv[0] via KERN_PROCARGS2 (readable for own-user processes, or all when root).
    static func argv0(_ pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        // Layout: argc (int32), exec path, NULs, argv[0], ...
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }   // skip exec path
        while i < size, buf[i] == 0 { i += 1 }   // skip padding
        let start = i
        while i < size, buf[i] != 0 { i += 1 }
        guard i > start else { return nil }
        return String(decoding: buf[start..<i], as: UTF8.self)
    }
}

// MARK: - pmset

public enum PMSet {
    static let path = "/usr/bin/pmset"

    /// Parses `SleepDisabled` from `pmset -g` output. Absent means 0.
    public static func parseDisableSleep(_ output: String) -> Int {
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "SleepDisabled", let v = Int(parts[1]) { return v }
        }
        return 0
    }

    @discardableResult
    public static func run(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "pmset", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "pmset \(args.joined(separator: " ")) failed: \(out)"])
        }
        return out
    }
}

/// Monotonic seconds that do NOT advance while the system sleeps (so a sleep/wake cycle
/// is not mistaken for a lost heartbeat).
public func uptimeSeconds() -> TimeInterval {
    Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
}
