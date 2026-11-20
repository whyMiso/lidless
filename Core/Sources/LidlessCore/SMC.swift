import Foundation
import CSMC

// MARK: - FourCC

public enum FourCC {
    public static func code(_ s: String) -> UInt32 {
        var bytes = Array(s.utf8.prefix(4))
        while bytes.count < 4 { bytes.append(0x20) }
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    public static func string(_ v: UInt32) -> String {
        let bytes = [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        return String(decoding: bytes.map { (0x20...0x7E).contains($0) ? $0 : 0x3F }, as: UTF8.self)
    }
}

// MARK: - Errors / values

public enum SMCError: Error, CustomStringConvertible, Equatable {
    case openFailed(Int32)
    case keyNotFound(String)
    case ioKit(key: String, code: Int32)
    case firmware(key: String, result: UInt8)
    case unsupportedType(key: String, type: String)
    case sizeMismatch(key: String, expected: Int, got: Int)

    public var description: String {
        switch self {
        case .openFailed(let c): return "Could not open AppleSMC (0x\(String(UInt32(bitPattern: c), radix: 16)))"
        case .keyNotFound(let k): return "SMC key '\(k)' not found"
        case .ioKit(let k, let c):
            let hex = String(UInt32(bitPattern: c), radix: 16)
            let hint = (c == Int32(bitPattern: 0xE00002C1) || c == Int32(bitPattern: 0xE00002C2)) ? " (needs root)" : ""
            return "IOKit error 0x\(hex) on '\(k)'\(hint)"
        case .firmware(let k, let r): return "SMC rejected '\(k)' (result 0x\(String(r, radix: 16)))"
        case .unsupportedType(let k, let t): return "Unsupported SMC type '\(t)' for '\(k)'"
        case .sizeMismatch(let k, let e, let g): return "Size mismatch on '\(k)': expected \(e), got \(g)"
        }
    }
}

public struct SMCKeyInfo: Equatable {
    public let size: Int
    public let type: String   // four characters, may include trailing space ("ui8 ")
}

public struct SMCValue: CustomStringConvertible {
    public let key: String
    public let info: SMCKeyInfo
    public let bytes: [UInt8]

    public var doubleValue: Double? { SMCCodec.decode(type: info.type, bytes: bytes) }

    public var description: String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let decoded = doubleValue.map { v -> String in
            v.rounded() == v && abs(v) < 1e12 ? String(Int64(v)) : String(format: "%.3f", v)
        } ?? "-"
        return "\(key)  [\(info.type)] size=\(info.size)  \(decoded)  (0x\(hex))"
    }
}

// MARK: - Codec (pure; unit-tested)

/// Decodes/encodes SMC values according to the type the SMC itself reports for a key.
/// - `flt ` is native (little-endian) IEEE754 on Apple Silicon.
/// - `fpXY`/`spXY` are big-endian fixed point with X integer bits and Y fraction bits (hex digits),
///   e.g. `fpe2` = 14.2 unsigned (Intel fan RPM), `sp78` = signed 7.8 (Intel temperatures).
/// - `ui*`/`si*` are big-endian integers.
public enum SMCCodec {
    public static func decode(type rawType: String, bytes: [UInt8]) -> Double? {
        let type = rawType.trimmingCharacters(in: .whitespaces)
        switch type {
        case "flt":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let f = Double(Float(bitPattern: bits))
            return f.isFinite ? f : nil
        case "flag":
            return bytes.first.map { $0 != 0 ? 1 : 0 }
        case "ui8", "ui16", "ui32", "ui64":
            let n = intWidth(type)
            guard bytes.count >= n else { return nil }
            return Double(bigEndian(bytes, n))
        case "si8", "si16", "si32", "si64":
            let n = intWidth(type)
            guard bytes.count >= n else { return nil }
            let u = bigEndian(bytes, n)
            let shift = UInt64(64 - n * 8)
            return Double(Int64(bitPattern: u << shift) >> Int64(shift))
        default:
            if let (signed, frac) = fixedPoint(type), bytes.count >= 2 {
                let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
                let scale = Double(1 << frac)
                return signed ? Double(Int16(bitPattern: raw)) / scale : Double(raw) / scale
            }
            return nil
        }
    }

    public static func encode(type rawType: String, value: Double, size: Int) -> [UInt8]? {
        let type = rawType.trimmingCharacters(in: .whitespaces)
        switch type {
        case "flt":
            guard size == 4 else { return nil }
            let bits = Float(value).bitPattern
            return [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24 & 0xFF)]
        case "flag":
            return [value != 0 ? 1 : 0] + Array(repeating: 0, count: max(0, size - 1))
        case "ui8", "ui16", "ui32", "ui64", "si8", "si16", "si32", "si64":
            let n = intWidth(type)
            guard n == size else { return nil }
            let v: UInt64 = type.hasPrefix("si") ? UInt64(bitPattern: Int64(value.rounded())) : UInt64(max(0, value.rounded()))
            return (0..<n).map { UInt8(truncatingIfNeeded: v >> UInt64((n - 1 - $0) * 8)) }
        default:
            guard let (signed, frac) = fixedPoint(type), size == 2 else { return nil }
            let scaled = (value * Double(1 << frac)).rounded()
            let raw: UInt16 = signed
                ? UInt16(bitPattern: Int16(clamping: Int(scaled)))
                : UInt16(clamping: max(0, Int(scaled)))
            return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        }
    }

    static func intWidth(_ type: String) -> Int {
        switch type.dropFirst(2) { case "8": return 1; case "16": return 2; case "32": return 4; default: return 8 }
    }

    static func bigEndian(_ bytes: [UInt8], _ n: Int) -> UInt64 {
        bytes.prefix(n).reduce(0) { ($0 << 8) | UInt64($1) }
    }

    /// "fpe2" -> (false, 2), "sp78" -> (true, 8). Only 16-bit layouts are supported.
    static func fixedPoint(_ type: String) -> (signed: Bool, frac: Int)? {
        guard type.count == 4, type.hasPrefix("fp") || type.hasPrefix("sp") else { return nil }
        let chars = Array(type)
        guard let i = Int(String(chars[2]), radix: 16), let f = Int(String(chars[3]), radix: 16) else { return nil }
        let signed = type.hasPrefix("sp")
        guard i + f + (signed ? 1 : 0) == 16 else { return nil }
        return (signed, f)
    }
}

// MARK: - Connection

/// Thread-safe wrapper over an AppleSMC user-client connection.
/// Reads work unprivileged; writes require root (only the helper writes).
public final class SMC: @unchecked Sendable {
    private let conn: io_connect_t
    private let lock = NSLock()
    private var infoCache: [UInt32: SMCKeyInfo] = [:]

    public init() throws {
        var c: io_connect_t = 0
        let kr = lsmc_open(&c)
        guard kr == KERN_SUCCESS else { throw SMCError.openFailed(kr) }
        conn = c
    }

    deinit { lsmc_close(conn) }

    public func keyInfo(_ key: String) throws -> SMCKeyInfo {
        let code = FourCC.code(key)
        lock.lock(); defer { lock.unlock() }
        if let cached = infoCache[code] { return cached }
        var size: UInt32 = 0, type: UInt32 = 0, attr: UInt8 = 0, result: UInt8 = 0
        let kr = lsmc_key_info(conn, code, &size, &type, &attr, &result)
        guard kr == KERN_SUCCESS else { throw SMCError.ioKit(key: key, code: kr) }
        guard result == 0, size > 0 else {
            if result == UInt8(LSMC_RESULT_KEY_NOTFOUND) || size == 0 { throw SMCError.keyNotFound(key) }
            throw SMCError.firmware(key: key, result: result)
        }
        let info = SMCKeyInfo(size: Int(size), type: FourCC.string(type))
        infoCache[code] = info
        return info
    }

    public func exists(_ key: String) -> Bool { (try? keyInfo(key)) != nil }

    public func read(_ key: String) throws -> SMCValue {
        let info = try keyInfo(key)
        var buf = [UInt8](repeating: 0, count: 32)
        var result: UInt8 = 0
        lock.lock()
        let kr = lsmc_read(conn, FourCC.code(key), UInt32(info.size), &buf, &result)
        lock.unlock()
        guard kr == KERN_SUCCESS else { throw SMCError.ioKit(key: key, code: kr) }
        guard result == 0 else { throw SMCError.firmware(key: key, result: result) }
        return SMCValue(key: key, info: info, bytes: Array(buf.prefix(info.size)))
    }

    public func readDouble(_ key: String) -> Double? { (try? read(key))?.doubleValue }

    /// Writes raw bytes. Succeeds only if both IOKit and the SMC firmware report success.
    public func write(_ key: String, bytes: [UInt8]) throws {
        let info = try keyInfo(key)
        guard bytes.count == info.size else { throw SMCError.sizeMismatch(key: key, expected: info.size, got: bytes.count) }
        var result: UInt8 = 0
        lock.lock()
        let kr = bytes.withUnsafeBufferPointer { lsmc_write(conn, FourCC.code(key), UInt32(info.size), $0.baseAddress, &result) }
        lock.unlock()
        guard kr == KERN_SUCCESS else { throw SMCError.ioKit(key: key, code: kr) }
        guard result == 0 else { throw SMCError.firmware(key: key, result: result) }
    }

    /// Encodes `value` using the type the SMC reports for `key`, then writes it.
    public func write(_ key: String, value: Double) throws {
        let info = try keyInfo(key)
        guard let bytes = SMCCodec.encode(type: info.type, value: value, size: info.size) else {
            throw SMCError.unsupportedType(key: key, type: info.type)
        }
        try write(key, bytes: bytes)
    }

    /// Enumerates every key the SMC exposes (thousands on Apple Silicon).
    public func allKeys() throws -> [String] {
        guard let count = readDouble("#KEY") else { throw SMCError.keyNotFound("#KEY") }
        var keys: [String] = []
        keys.reserveCapacity(Int(count))
        for i in 0..<UInt32(count) {
            var code: UInt32 = 0, result: UInt8 = 0
            lock.lock()
            let kr = lsmc_key_at_index(conn, i, &code, &result)
            lock.unlock()
            if kr == KERN_SUCCESS, result == 0 { keys.append(FourCC.string(code)) }
        }
        return keys
    }
}
