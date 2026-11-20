import Foundation

public enum LidlessIDs {
    public static let appBundleID = "dev.lidless.Lidless"
    public static let helperBundleID = "dev.lidless.helper"
    public static let helperMachService = "dev.lidless.helper"
    public static let helperPlistName = "dev.lidless.helper.plist"
    /// Bump when the XPC protocol or helper behaviour changes; the app replaces a mismatched helper.
    public static let helperProtocolVersion = 1
    public static let stateDirectory = "/Library/Application Support/Lidless"
    public static let stateFile = stateDirectory + "/state.json"

    /// Code-signing requirement for a peer: Apple-anchored, exact identifier, same team.
    public static func requirement(identifier: String, teamID: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}

// MARK: - Session configuration

public enum EndCondition: Codable, Equatable {
    case indefinite
    case until(Date)
    case whileProcess(String)
}

public enum FanMode: Int, Codable, CaseIterable {
    case auto = 0, max = 1, custom = 2
}

/// Safety + end-condition settings sent by the app when lid mode is enabled.
public struct LidConfig: Codable, Equatable {
    public var endCondition: EndCondition = .indefinite
    public var acOnly = false              // opt-in: refuse / stop lid mode when not on AC power
    public var batteryThreshold = 20          // percent
    public var maxSessionHours = 8.0
    public var processGraceSeconds = 120.0
    public var displaySleepOnLidClose = true     // run `pmset displaysleepnow` when the lid closes
    public var sleepOnSafetyStop = true       // if the lid is closed when a guard trips, sleep now
    public init() {}
}

// MARK: - Status reported to the app

public enum ThermalLevel: String, Codable, Comparable {
    case nominal, fair, serious, critical
    private var rank: Int { [.nominal: 0, .fair: 1, .serious: 2, .critical: 3][self]! }
    public static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.rank < b.rank }

    public init(_ s: ProcessInfo.ThermalState) {
        switch s {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }
}

public struct PowerInfo: Codable, Equatable {
    public var onAC: Bool
    public var batteryPercent: Int?   // nil on desktops
    public var isCharging: Bool
    public init(onAC: Bool, batteryPercent: Int?, isCharging: Bool) {
        self.onAC = onAC; self.batteryPercent = batteryPercent; self.isCharging = isCharging
    }
}

public struct SafetyEvent: Codable, Equatable, Identifiable {
    public enum Kind: String, Codable {
        case thermalSerious, thermalCritical, lowBattery, onBattery, maxSession, endConditionReached,
             clientLost, heartbeatLost, systemSleep, helperRecovered, error
    }
    public var id: Int
    public var kind: Kind
    public var message: String
    public var date: Date
}

public struct HelperStatus: Codable, Equatable {
    public var protocolVersion = LidlessIDs.helperProtocolVersion
    public var lidModeActive = false
    public var lidStartedAt: Date?
    public var lidEndsAt: Date?                 // earliest of max session / until
    public var lidConfig: LidConfig?
    public var originalDisableSleep: Int?
    public var currentDisableSleep: Int?
    public var fanMode: FanMode = .auto
    public var fanTargetRPM: Double?
    public var fanControlAvailable = false
    public var thermal: ThermalLevel = .nominal
    public var power: PowerInfo?
    public var events: [SafetyEvent] = []       // most recent last, capped
    public var lastError: String?
    public init() {}
}

/// Persisted by the helper so that a crashed/restarted helper (or a reboot) restores originals.
public struct PersistedState: Codable, Equatable {
    public var lidModeActive = false
    public var originalDisableSleep: Int?
    public var fanOverrideActive = false
    public var fanRestore: FanRestoreInfo?
    public var writtenAt = Date()
    public init() {}

    public var needsRestore: Bool { lidModeActive || fanOverrideActive }
}

// MARK: - JSON helpers

public enum Wire {
    public static func encode<T: Encodable>(_ v: T) -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return (try? e.encode(v)) ?? Data()
    }

    public static func decode<T: Decodable>(_ t: T.Type, _ d: Data) -> T? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(t, from: d)
    }
}
