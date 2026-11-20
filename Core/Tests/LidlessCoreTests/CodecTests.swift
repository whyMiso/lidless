import XCTest
import CSMC
@testable import LidlessCore

final class CodecTests: XCTestCase {
    func testStructLayoutIs80Bytes() {
        XCTAssertEqual(lsmc_param_size(), 80)
    }

    func testFourCC() {
        XCTAssertEqual(FourCC.string(FourCC.code("F0md")), "F0md")
        XCTAssertEqual(FourCC.string(FourCC.code("FS!")), "FS! ")
        XCTAssertEqual(FourCC.code("#KEY"), 0x234B4559)
    }

    func testFltMatchesValuesReadOnM5() {
        // Captured with `lidless-smc --read-only` on Mac17,2: F0Ac = 0x00501c45, F0Mx = 0x00b0cc45.
        XCTAssertEqual(SMCCodec.decode(type: "flt ", bytes: [0x00, 0x50, 0x1c, 0x45]), 2501)
        XCTAssertEqual(SMCCodec.decode(type: "flt ", bytes: [0x00, 0xb0, 0xcc, 0x45]), 6550)
        XCTAssertEqual(SMCCodec.encode(type: "flt ", value: 6550, size: 4), [0x00, 0xb0, 0xcc, 0x45])
    }

    func testFpe2IntelRPM() {
        // smcFanControl README: 3500 rpm -> 0x36b0
        XCTAssertEqual(SMCCodec.encode(type: "fpe2", value: 3500, size: 2), [0x36, 0xb0])
        XCTAssertEqual(SMCCodec.decode(type: "fpe2", bytes: [0x36, 0xb0]), 3500)
    }

    func testSp78Signed() {
        XCTAssertEqual(SMCCodec.decode(type: "sp78", bytes: [0x2a, 0x80]), 42.5)
        XCTAssertEqual(SMCCodec.decode(type: "sp78", bytes: [0xff, 0x00]), -1)
    }

    func testIntegers() {
        XCTAssertEqual(SMCCodec.decode(type: "ui8 ", bytes: [0x03]), 3)
        XCTAssertEqual(SMCCodec.decode(type: "ui16", bytes: [0x00, 0x03]), 3)
        XCTAssertEqual(SMCCodec.encode(type: "ui16", value: 3, size: 2), [0x00, 0x03])
        XCTAssertEqual(SMCCodec.encode(type: "ui8 ", value: 1, size: 1), [0x01])
        XCTAssertEqual(SMCCodec.decode(type: "si8 ", bytes: [0xff]), -1)
        XCTAssertNil(SMCCodec.encode(type: "ui8 ", value: 1, size: 2), "size must match type")
        XCTAssertNil(SMCCodec.encode(type: "{fds", value: 1, size: 16))
    }

    func testPMSetParse() {
        XCTAssertEqual(PMSet.parseDisableSleep(" sleep 1\n displaysleep 10\n"), 0)
        XCTAssertEqual(PMSet.parseDisableSleep(" SleepDisabled\t\t1\n sleep 1\n"), 1)
    }

    func testProcessMatchingIsExactAndCaseSensitive() {
        XCTAssertTrue(ProcessFinder.matches(name: "claude", executable: "claude", argv0: nil))
        XCTAssertTrue(ProcessFinder.matches(name: "claude", executable: "node", argv0: "claude"))
        XCTAssertTrue(ProcessFinder.matches(name: "claude", executable: "node", argv0: "/usr/local/bin/claude"))
        XCTAssertFalse(ProcessFinder.matches(name: "claude", executable: "Claude", argv0: "/Applications/Claude.app/Contents/MacOS/Claude"))
        XCTAssertFalse(ProcessFinder.matches(name: "claude", executable: "claude-helper", argv0: nil))
    }

    func testOwnProcessIsFound() {
        let me = ProcessInfo.processInfo.processName
        XCTAssertTrue(ProcessFinder.isRunning(me))
        XCTAssertFalse(ProcessFinder.isRunning("definitely-not-a-real-process-xyz"))
    }

    func testSensorGrouping() {
        #if arch(arm64)
        XCTAssertEqual(TempSensors.group(for: "Tp0C"), .cpu)
        XCTAssertEqual(TempSensors.group(for: "Te04"), .cpu)
        XCTAssertEqual(TempSensors.group(for: "Tg0G"), .gpu)
        XCTAssertEqual(TempSensors.group(for: "TCMb"), .other)
        #endif
        XCTAssertNil(TempSensors.group(for: "F0Ac"))
    }
}
