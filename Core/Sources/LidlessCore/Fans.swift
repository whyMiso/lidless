import Foundation

public struct FanInfo: Codable, Equatable, Identifiable {
    public var index: Int
    public var actual: Double
    public var min: Double
    public var max: Double
    public var target: Double?
    /// Raw SMC mode value if a mode key exists (0 auto, 1 manual, 3 system-owned on M4+).
    public var mode: Int?
    public var id: Int { index }

    public init(index: Int, actual: Double, min: Double, max: Double, target: Double?, mode: Int?) {
        self.index = index; self.actual = actual; self.min = min; self.max = max; self.target = target; self.mode = mode
    }
}

/// What must be put back if the helper dies mid-override. Persisted in the state file.
public struct FanRestoreInfo: Codable, Equatable {
    public var usedForceTestKey = false        // Apple Silicon M4-style `Ftst` unlock
    public var originalForceBits: Int?         // Intel `FS! ` bitmask before we touched it
    public var originalMins: [Int: Double] = [:] // Intel Mn floors we overwrote
    public init() {}
}

public protocol FanControlling: AnyObject {
    var fanCount: Int { get }
    func readFans() -> [FanInfo]
    /// Puts every fan in `targets` under manual control at the given RPM (clamped to Mn...Mx).
    func setManual(targets: [Int: Double]) throws
    /// Re-applies the override if the OS took control back. Returns true if anything was re-written.
    @discardableResult func reassert(targets: [Int: Double]) -> Bool
    /// Hands every fan back to automatic control.
    func restoreAuto(using info: FanRestoreInfo?) throws
    var restoreInfo: FanRestoreInfo { get }
}

/// Fan control over the SMC. Key names and data types are probed at runtime rather than
/// hard-coded, because they differ by generation:
/// - M1/M4: `F%dMd`; M5 (Mac17,7 confirmed by others): `F%dmd`.
/// - M4: writes to the mode key are rejected (0x82) until `Ftst=1`, then thermalmonitord yields
///   after a few seconds. M5: direct write works and `Ftst` does not exist.
/// - Intel (pre-T2): no mode key; `FS! ` force bitmask + `F%dTg`, or raise `F%dMn` as a floor.
public final class SMCFanController: FanControlling, @unchecked Sendable {
    public enum Platform: String { case appleSilicon, intel }

    private let smc: SMC
    public let platform: Platform
    public private(set) var restoreInfo = FanRestoreInfo()
    private let log: (String) -> Void

    public init(smc: SMC, log: @escaping (String) -> Void = { _ in }) {
        self.smc = smc
        self.log = log
        #if arch(arm64)
        platform = .appleSilicon
        #else
        platform = .intel
        #endif
    }

    public var fanCount: Int { Int(smc.readDouble("FNum") ?? 0) }

    public func modeKey(_ i: Int) -> String? {
        if smc.exists("F\(i)md") { return "F\(i)md" }
        if smc.exists("F\(i)Md") { return "F\(i)Md" }
        return nil
    }

    public func readFans() -> [FanInfo] {
        (0..<fanCount).map { i in
            FanInfo(
                index: i,
                actual: smc.readDouble("F\(i)Ac") ?? 0,
                min: smc.readDouble("F\(i)Mn") ?? 0,
                max: smc.readDouble("F\(i)Mx") ?? 0,
                target: smc.readDouble("F\(i)Tg"),
                mode: modeKey(i).flatMap { smc.readDouble($0) }.map { Int($0) }
            )
        }
    }

    private func clamp(_ rpm: Double, fan i: Int) -> Double {
        let mn = smc.readDouble("F\(i)Mn") ?? 0
        let mx = smc.readDouble("F\(i)Mx") ?? rpm
        return Swift.min(Swift.max(rpm, mn), mx > 0 ? mx : rpm)
    }

    // MARK: Manual

    public func setManual(targets: [Int: Double]) throws {
        for (i, rpm) in targets.sorted(by: { $0.key < $1.key }) {
            let rpm = clamp(rpm, fan: i)
            switch platform {
            case .appleSilicon:
                try ensureManualAppleSilicon(fan: i)
                try retry(10, delay: 0.05) { try smc.write("F\(i)Tg", value: rpm) }
            case .intel:
                try setManualIntel(fan: i, rpm: rpm)
            }
            log("fan \(i): manual @ \(Int(rpm)) rpm")
        }
    }

    private func ensureManualAppleSilicon(fan i: Int) throws {
        guard let mk = modeKey(i) else { throw SMCError.keyNotFound("F\(i)md/F\(i)Md") }
        if Int(smc.readDouble(mk) ?? -1) == 1 { return }
        do {
            try smc.write(mk, value: 1)
            return
        } catch {
            guard smc.exists("Ftst") else { throw error }
            log("direct \(mk)=1 rejected (\(error)); unlocking with Ftst")
        }
        // M4-style: ask thermalmonitord to yield, then retry until the mode write sticks.
        try retry(20, delay: 0.05) { try smc.write("Ftst", value: 1) }
        restoreInfo.usedForceTestKey = true
        try retry(60, delay: 0.2) { try smc.write(mk, value: 1) }   // up to ~12 s
    }

    private func setManualIntel(fan i: Int, rpm: Double) throws {
        if let mk = modeKey(i) {                // T2-era Intel
            try smc.write(mk, value: 1)
            try smc.write("F\(i)Tg", value: rpm)
        } else if smc.exists("FS! ") {
            let current = Int(smc.readDouble("FS! ") ?? 0)
            if restoreInfo.originalForceBits == nil { restoreInfo.originalForceBits = current }
            try smc.write("FS! ", value: Double(current | (1 << i)))
            try smc.write("F\(i)Tg", value: rpm)
        } else {                                // floor approach (smcFanControl style)
            if restoreInfo.originalMins[i] == nil { restoreInfo.originalMins[i] = smc.readDouble("F\(i)Mn") }
            try smc.write("F\(i)Mn", value: rpm)
        }
    }

    @discardableResult
    public func reassert(targets: [Int: Double]) -> Bool {
        var rewrote = false
        for (i, rpm) in targets {
            let rpm = clamp(rpm, fan: i)
            let modeOK = modeKey(i).map { Int(smc.readDouble($0) ?? -1) == 1 } ?? true
            let tgKey = (platform == .intel && modeKey(i) == nil && !smc.exists("FS! ")) ? "F\(i)Mn" : "F\(i)Tg"
            let tgOK = smc.readDouble(tgKey).map { abs($0 - rpm) < 50 } ?? false
            if !modeOK || !tgOK {
                log("fan \(i): override drifted (modeOK=\(modeOK) targetOK=\(tgOK)); re-applying")
                try? setManual(targets: [i: rpm])
                rewrote = true
            }
        }
        return rewrote
    }

    // MARK: Auto

    public func restoreAuto(using info: FanRestoreInfo?) throws {
        let info = info ?? restoreInfo
        var firstError: Error?
        func attempt(_ body: () throws -> Void) {
            do { try body() } catch { if firstError == nil { firstError = error } }
        }
        for i in 0..<fanCount {
            switch platform {
            case .appleSilicon:
                if let mk = modeKey(i) {
                    attempt { try retry(5, delay: 0.05) { try smc.write(mk, value: 0) } }
                    attempt { try smc.write("F\(i)Tg", value: 0) }   // as Stats / macos-smc-fan do
                }
            case .intel:
                if let mk = modeKey(i) { attempt { try smc.write(mk, value: 0) } }
                if let mn = info.originalMins[i] { attempt { try smc.write("F\(i)Mn", value: mn) } }
            }
        }
        if platform == .appleSilicon, smc.exists("Ftst"),
           info.usedForceTestKey || Int(smc.readDouble("Ftst") ?? 0) == 1 {
            attempt { try retry(5, delay: 0.05) { try smc.write("Ftst", value: 0) } }
        }
        if platform == .intel, smc.exists("FS! ") {
            attempt { try smc.write("FS! ", value: Double(info.originalForceBits ?? 0)) }
        }
        restoreInfo = FanRestoreInfo()
        log("fans: restored to automatic")
        if let e = firstError { throw e }
    }

    private func retry(_ times: Int, delay: TimeInterval, _ body: () throws -> Void) throws {
        var last: Error?
        for n in 0..<times {
            do { try body(); return } catch { last = error }
            if n < times - 1 { Thread.sleep(forTimeInterval: delay) }
        }
        throw last!
    }
}

// MARK: - Temperatures

public struct TempReading: Codable, Equatable {
    public enum Group: String, Codable { case cpu, gpu, other }
    public var key: String
    public var group: Group
    public var celsius: Double
}

public struct TempSummary: Codable, Equatable {
    public var cpuAverage: Double?
    public var cpuMax: Double?
    public var gpuMax: Double?
    public init(cpuAverage: Double? = nil, cpuMax: Double? = nil, gpuMax: Double? = nil) {
        self.cpuAverage = cpuAverage; self.cpuMax = cpuMax; self.gpuMax = gpuMax
    }
}

/// Discovers temperature keys by enumerating the SMC instead of using per-chip tables,
/// so new chips (M5) work without updates. Apple Silicon: `Tp*` P-cores, `Te*` E-cores, `Tg*` GPU.
/// Intel: `TC*` CPU, `TG*` GPU.
public final class TempSensors: @unchecked Sendable {
    private let smc: SMC
    public private(set) var keys: [(String, TempReading.Group)] = []

    public init(smc: SMC) { self.smc = smc }

    public static func group(for key: String) -> TempReading.Group? {
        guard key.hasPrefix("T") else { return nil }
        let p = String(key.prefix(2))
        #if arch(arm64)
        switch p {
        case "Tp", "Te": return .cpu     // P-core / E-core dies
        case "Tg": return .gpu
        default: return .other
        }
        #else
        switch p {
        case "TC": return .cpu
        case "TG": return .gpu
        default: return .other
        }
        #endif
    }

    public static func plausible(_ c: Double) -> Bool { c > 5 && c < 130 }

    /// Expensive (enumerates all keys); call once, off the main thread.
    public func discover() {
        guard let all = try? smc.allKeys() else { return }
        keys = all.compactMap { key in
            guard let g = Self.group(for: key),
                  let info = try? smc.keyInfo(key),
                  ["flt", "sp78"].contains(info.type.trimmingCharacters(in: .whitespaces)),
                  let v = smc.readDouble(key), Self.plausible(v) else { return nil }
            return (key, g)
        }
    }

    public func read() -> [TempReading] {
        keys.compactMap { key, g in
            smc.readDouble(key).flatMap { Self.plausible($0) ? TempReading(key: key, group: g, celsius: $0) : nil }
        }
    }

    public static func summarize(_ r: [TempReading]) -> TempSummary {
        let cpu = r.filter { $0.group == .cpu }.map(\.celsius)
        let gpu = r.filter { $0.group == .gpu }.map(\.celsius)
        return TempSummary(
            cpuAverage: cpu.isEmpty ? nil : cpu.reduce(0, +) / Double(cpu.count),
            cpuMax: cpu.max(),
            gpuMax: gpu.max()
        )
    }
}
