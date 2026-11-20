import Foundation
import LidlessCore

/// App-side, read-only SMC monitor (fan RPMs + temperatures). Writes go through the helper only.
@MainActor
final class FanMonitor: ObservableObject {
    @Published private(set) var fans: [FanInfo] = []
    @Published private(set) var temps = TempSummary()
    @Published private(set) var fanCount = 0

    private let worker = DispatchQueue(label: "dev.lidless.fanmonitor", qos: .utility)
    private var smc: SMC?
    private var reader: SMCFanController?
    private var sensors: TempSensors?
    private var timer: Timer?

    init() {
        worker.async { [weak self] in
            guard let smc = try? SMC() else { return }
            let reader = SMCFanController(smc: smc)
            let sensors = TempSensors(smc: smc)
            sensors.discover()
            let count = reader.fanCount
            let fans = reader.readFans()
            let temps = TempSensors.summarize(sensors.read())
            Task { @MainActor in
                self?.smc = smc; self?.reader = reader; self?.sensors = sensors
                self?.fanCount = count; self?.fans = fans; self?.temps = temps
            }
        }
    }

    /// Poll while the menu is visible.
    func setVisible(_ visible: Bool) {
        timer?.invalidate(); timer = nil
        guard visible else { return }
        refresh()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        guard let reader, let sensors else { return }
        worker.async { [weak self] in
            let fans = reader.readFans()
            let temps = TempSensors.summarize(sensors.read())
            Task { @MainActor in self?.fans = fans; self?.temps = temps }
        }
    }
}
