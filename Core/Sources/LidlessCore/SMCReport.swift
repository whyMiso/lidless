import Foundation

/// The `--read-only` debug report: prints fan + temperature keys without writing anything.
public enum SMCReport {
    public static func run(all: Bool, out: (String) -> Void = { print($0) }) -> Int32 {
        let smc: SMC
        do { smc = try SMC() } catch { out("error: \(error)"); return 1 }

        #if arch(arm64)
        out("Platform: Apple Silicon")
        #else
        out("Platform: Intel")
        #endif
        out("Mode: READ-ONLY (no SMC writes are performed)\n")

        let fans = SMCFanController(smc: smc)
        let n = fans.fanCount
        out("== Fans (FNum = \(n)) ==")
        if n == 0 { out("No fans reported (fanless Mac). Fan UI would be hidden.") }
        for i in 0..<n {
            out("-- Fan \(i) --")
            for suffix in ["Ac", "Mn", "Mx", "Tg", "md", "Md", "ID", "Sf", "St"] {
                let key = "F\(i)\(suffix)"
                if let v = try? smc.read(key) { out("  \(v)") }
            }
            out("  mode key in use: \(fans.modeKey(i) ?? "none")")
        }
        out("\n== Control keys ==")
        for key in ["Ftst", "FS! ", "FNum"] {
            if let v = try? smc.read(key) { out("  \(v)") } else { out("  \(key)  (absent)") }
        }

        out("\n== Temperature sensors (discovered) ==")
        let temps = TempSensors(smc: smc)
        temps.discover()
        let readings = temps.read()
        for g in [TempReading.Group.cpu, .gpu, .other] {
            let rs = readings.filter { $0.group == g }
            guard !rs.isEmpty else { continue }
            out("-- \(g.rawValue) (\(rs.count)) --")
            for r in rs { out(String(format: "  %@  %.1f °C", r.key, r.celsius)) }
        }
        let s = TempSensors.summarize(readings)
        out(String(format: "\nCPU avg %.1f °C, CPU max %.1f °C, GPU max %.1f °C",
                   s.cpuAverage ?? .nan, s.cpuMax ?? .nan, s.gpuMax ?? .nan))

        if all {
            out("\n== All SMC keys ==")
            let keys = (try? smc.allKeys()) ?? []
            for k in keys {
                if let v = try? smc.read(k) { out("  \(v)") } else if let info = try? smc.keyInfo(k) {
                    out("  \(k)  [\(info.type)] size=\(info.size)  (unreadable)")
                }
            }
            out("\(keys.count) keys")
        }
        return 0
    }
}
