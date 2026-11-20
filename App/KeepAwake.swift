import Foundation
import IOKit.pwr_mgt
import LidlessCore

/// Feature 1: ordinary keep-awake via IOPMAssertions (no root). Assertions die with the process,
/// so a crash can never leave the Mac stuck awake.
final class KeepAwakeController: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var endCondition: EndCondition = .indefinite

    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var timer: Timer?
    private var processLastSeen = Date()
    private var graceSeconds: TimeInterval = 120
    var onAutoStop: ((String) -> Void)?

    func start(_ end: EndCondition, keepDisplayOn: Bool, graceSeconds: TimeInterval) {
        stop(silently: true)
        let reason = "Lidless keep-awake" as CFString
        guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                          IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &systemAssertion) == kIOReturnSuccess
        else { return }
        if keepDisplayOn {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &displayAssertion)
        }
        endCondition = end
        self.graceSeconds = graceSeconds
        processLastSeen = Date()
        isActive = true
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop(silently: Bool = false) {
        timer?.invalidate(); timer = nil
        if systemAssertion != 0 { IOPMAssertionRelease(systemAssertion); systemAssertion = 0 }
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
        isActive = false
    }

    private func check() {
        switch endCondition {
        case .indefinite: break
        case .until(let d):
            if Date() >= d { stop(); onAutoStop?("Keep Awake ended as scheduled.") }
        case .whileProcess(let name):
            if ProcessFinder.isRunning(name) {
                processLastSeen = Date()
            } else if Date().timeIntervalSince(processLastSeen) >= graceSeconds {
                stop(); onAutoStop?("`\(name)` exited; Keep Awake turned off.")
            }
        }
    }
}
