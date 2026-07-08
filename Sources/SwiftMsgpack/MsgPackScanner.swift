import Foundation

enum MsgPackValueLiteralType {
    case `nil`
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case float32(Float)
    case float64(Double)
    case str(UnsafeBufferPointer<UInt8>)
    case bin(Data)
}

extension MsgPackValueLiteralType {
    var debugDataTypeDescription: String {
        switch self {
        case .nil:
            return "nil"
        case .bool:
            return "bool"
        case .int:
            return "Int64"
        case .uint:
            return "UInt64"
        case .float32:
            return "float32"
        case .float64:
            return "float64"
        case .str:
            return "str"
        case .bin:
            return "bin"
        }
    }
}

/// A scanned MessagePack value. A struct rather than an indirect enum so the
/// per-value byte span travels inline with the payload: building the value
/// tree allocates only the container arrays, never a box per value.
struct MsgPackValue {
    enum Kind {
        case none
        case literal(MsgPackValueLiteralType)
        case ext(Int8, Data)
        case array([MsgPackValue])
        case map([MsgPackValue])
        case lazyArray(LazyArrayCursor)
        case lazyMap(LazyMapCursor)
    }

    var kind: Kind
    /// Byte span of this value in the source buffer; `count == 0` means the
    /// span is unknown (nothing was consumed producing this value).
    var from: Int = 0
    var count: Int = 0

    static var none: MsgPackValue { MsgPackValue(kind: .none) }
}

extension MsgPackValue {
    func rawData(from source: Data) -> Data? {
        guard count > 0 else { return nil }
        let start = source.startIndex + from
        return source.subdata(in: start ..< (start + count))
    }
}

extension MsgPackValue {
    func asArray() -> [MsgPackValue] {
        switch kind {
        case .none:
            return []
        case .literal, .ext:
            return [self]
        case let .array(a), let .map(a):
            return a
        case let .lazyArray(c):
            return c.elements()
        case let .lazyMap(c):
            return c.entries()
        }
    }

    func asDictionary() -> [(MsgPackValue, MsgPackValue)] {
        switch kind {
        case .none, .literal, .ext:
            return []
        case let .array(a):
            if a.count % 2 != 0 {
                return []
            }
            let n = a.count / 2
            var d = [(MsgPackValue, MsgPackValue)]()
            d.reserveCapacity(n)
            for i in 0 ..< n {
                let key = a[i * 2]
                let value = a[i * 2 + 1]
                d.append((key, value))
            }
            return d
        case let .map(a):
            let n = a.count / 2
            var d = [(MsgPackValue, MsgPackValue)]()
            d.reserveCapacity(n)
            for i in 0 ..< n {
                let key = a[i * 2]
                let value = a[i * 2 + 1]
                d.append((key, value))
            }
            return d
        case let .lazyArray(c):
            let a = c.elements()
            if a.count % 2 != 0 {
                return []
            }
            let n = a.count / 2
            var d = [(MsgPackValue, MsgPackValue)]()
            d.reserveCapacity(n)
            for i in 0 ..< n {
                d.append((a[i * 2], a[i * 2 + 1]))
            }
            return d
        case let .lazyMap(c):
            let a = c.entries()
            let n = a.count / 2
            var d = [(MsgPackValue, MsgPackValue)]()
            d.reserveCapacity(n)
            for i in 0 ..< n {
                d.append((a[i * 2], a[i * 2 + 1]))
            }
            return d
        }
    }
}

extension MsgPackValue {
    var debugDataTypeDescription: String {
        switch kind {
        case .none:
            return "none"
        case let .literal(v):
            return v.debugDataTypeDescription
        case .ext:
            return "a extension"
        case .array, .lazyArray:
            return "an array"
        case .map, .lazyMap:
            return "a map"
        }
    }
}

enum MsgPackOpCode {
    case uint(UInt8)
    case int(UInt8)
    case str(UInt8)
    case bin(UInt8)
    case array(UInt8)
    case map(UInt8)
    case ext(UInt8)
    case simple(UInt8)
    case neverUsed
    case end

    private static let table: [MsgPackOpCode] = {
        var t = [MsgPackOpCode](repeating: .neverUsed, count: 256)
        for i in 0 ... 255 {
            t[i] = MsgPackOpCode._build(UInt8(i))
        }
        return t
    }()

    init(ch c: UInt8) {
        self = MsgPackOpCode.table[Int(c)]
    }

    private static func _build(_ c: UInt8) -> MsgPackOpCode {
        if c <= 0xBF || c >= 0xE0 {
            if c & 0xE0 == 0xE0 {
                return .int(c)
            } else if c & 0xA0 == 0xA0 {
                return .str(c - 0xA0)
            } else if c & 0x90 == 0x90 {
                return .array(c - 0x90)
            } else if c & 0x80 == 0x80 {
                return .map(c - 0x80)
            } else if c & 0x80 == 0 {
                return .uint(c)
            } else {
                return .neverUsed
            }
        } else {
            switch c {
            case 0xC1:
                return .neverUsed
            case 0xC4 ... 0xC6:
                return .bin(c - 0x44)
            case 0xDC, 0xDD:
                return .array(c - 0x5B)
            case 0xDE, 0xDF:
                return .map(c - 0x5D)
            case 0xC7 ... 0xC9:
                return .ext(c - 0x47)
            case 0xCC ... 0xCF:
                return .uint(c - 0x4C)
            case 0xD0 ... 0xD3:
                return .int(c - 0x50)
            case 0xD9 ... 0xDB:
                return .str(c - 0x59)
            case 0xD4 ... 0xD8:
                return .ext(1 << (c - 0xD4))
            default:
                return .simple(c)
            }
        }
    }
}

class MsgPackScanner {
    private static let maxNestingDepth = 512

    private let start: UnsafeRawPointer
    private var ptr: UnsafeRawPointer
    private let count: Int
    private var depth = 0
    private(set) var corrupt = false

    init(ptr: UnsafeRawPointer, count: Int) {
        start = ptr
        self.ptr = ptr
        self.count = count
    }

    private func advanced(by n: Int) {
        ptr = ptr.advanced(by: n)
    }

    private var isAtEnd: Bool {
        start.distance(to: ptr) >= count
    }

    private var remaining: Int {
        count - start.distance(to: ptr)
    }

    private func markCorrupt() {
        corrupt = true
        ptr = start.advanced(by: count)
    }

    private func readUInt8() -> UInt8 {
        guard remaining >= 1 else {
            markCorrupt()
            return 0
        }
        defer {
            advanced(by: 1)
        }
        return ptr.load(as: UInt8.self)
    }

    private func readInt8() -> Int8 {
        guard remaining >= 1 else {
            markCorrupt()
            return 0
        }
        defer {
            advanced(by: 1)
        }
        return ptr.load(as: Int8.self)
    }

    private func readUnaligned<T: FixedWidthInteger>(as: T.Type) -> T {
        guard remaining >= MemoryLayout<T>.size else {
            markCorrupt()
            return 0
        }
        defer {
            advanced(by: MemoryLayout<T>.size)
        }
        return ptr.loadUnaligned(as: T.self)
    }

    private func readBuffer(_ n: Int) -> UnsafeBufferPointer<UInt8> {
        guard n >= 0, n <= remaining else {
            markCorrupt()
            return UnsafeBufferPointer<UInt8>(start: nil, count: 0)
        }
        defer {
            advanced(by: n)
        }
        return ptr.withMemoryRebound(to: UInt8.self, capacity: n) {
            UnsafeBufferPointer<UInt8>(start: $0, count: n)
        }
    }

    func scan() -> MsgPackValue {
        let begin = start.distance(to: ptr)
        let kind = scanInner()
        let end = start.distance(to: ptr)
        return MsgPackValue(kind: kind, from: begin, count: max(0, end - begin))
    }

    private func scanInner() -> MsgPackValue.Kind {
        switch readOpCode() {
        case .end, .neverUsed:
            .none
        case let .uint(c):
            scanUInt(c)
        case let .int(c):
            scanInt(c)
        case let .str(c):
            scanString(c)
        case let .bin(c):
            scanBinary(c)
        case let .ext(c):
            scanExtension(c)
        case let .array(c):
            scanArray(c)
        case let .map(c):
            scanMap(c)
        case let .simple(c):
            scanSimple(c)
        }
    }

    private func scanUInt(_ c: UInt8) -> MsgPackValue.Kind {
        .literal(.uint(_scanUInt(c)))
    }

    private func _scanUInt(_ c: UInt8) -> UInt64 {
        switch c {
        case 0x80:
            UInt64(readUInt8())
        case 0x81:
            UInt64(readUnaligned(as: UInt16.self).bigEndian)
        case 0x82:
            UInt64(readUnaligned(as: UInt32.self).bigEndian)
        case 0x83:
            readUnaligned(as: UInt64.self).bigEndian
        default:
            UInt64(c)
        }
    }

    // A container/blob claiming more elements/bytes than there are bytes
    // left in the input can never be valid: every element takes at least
    // one byte. Rejecting here bounds both reads and reserveCapacity.
    private func getLength(_ c: UInt8) -> Int {
        let v = _scanUInt(c)
        guard v <= UInt64(remaining) else {
            markCorrupt()
            return 0
        }
        return Int(v)
    }

    private func scanInt(_ c: UInt8) -> MsgPackValue.Kind {
        switch c {
        case 0x80:
            .literal(.int(Int64(readInt8())))
        case 0x81:
            .literal(.int(Int64(readUnaligned(as: Int16.self).bigEndian)))
        case 0x82:
            .literal(.int(Int64(readUnaligned(as: Int32.self).bigEndian)))
        case 0x83:
            .literal(.int(readUnaligned(as: Int64.self).bigEndian))
        default:
            .literal(.int(Int64(Int8(bitPattern: c))))
        }
    }

    private func scanString(_ c: UInt8) -> MsgPackValue.Kind {
        .literal(.str(readBuffer(getLength(c))))
    }

    private func scanBinary(_ c: UInt8) -> MsgPackValue.Kind {
        .literal(.bin(.init(buffer: readBuffer(getLength(c)))))
    }

    private func scanExtension(_ c: UInt8) -> MsgPackValue.Kind {
        let n = getLength(c)
        let typeNo = Int8(bitPattern: readUInt8())
        return .ext(typeNo, .init(buffer: readBuffer(n)))
    }

    private func scanSimple(_ c: UInt8) -> MsgPackValue.Kind {
        switch c {
        case 0xC0:
            .literal(.nil)
        case 0xC2:
            .literal(.bool(false))
        case 0xC3:
            .literal(.bool(true))
        case 0xCA:
            .literal(.float32(.init(bitPattern: readUnaligned(as: UInt32.self).bigEndian)))
        case 0xCB:
            .literal(.float64(.init(bitPattern: readUnaligned(as: UInt64.self).bigEndian)))
        default:
            .none
        }
    }

    private func enterNesting() -> Bool {
        if depth >= Self.maxNestingDepth {
            markCorrupt()
            return false
        }
        depth += 1
        return true
    }

    private func scanArray(_ c: UInt8) -> MsgPackValue.Kind {
        let n = getLength(c)
        guard !corrupt, enterNesting() else { return .none }
        defer { depth -= 1 }
        var a: [MsgPackValue] = []
        a.reserveCapacity(n)
        for _ in 0 ..< n {
            if corrupt { break }
            a.append(scan())
        }
        return .array(a)
    }

    private func scanMap(_ c: UInt8) -> MsgPackValue.Kind {
        let n = getLength(c)
        guard !corrupt, enterNesting() else { return .none }
        defer { depth -= 1 }
        var a: [MsgPackValue] = []
        a.reserveCapacity(n * 2)
        for _ in 0 ..< n {
            if corrupt { break }
            a.append(scan())
            a.append(scan())
        }
        return .map(a)
    }

    private func readOpCode() -> MsgPackOpCode {
        !isAtEnd ? MsgPackOpCode(ch: readUInt8()) : .end
    }
}

extension MsgPackScanner {
    var currentPointer: UnsafeRawPointer { ptr }

    func seek(to p: UnsafeRawPointer) {
        ptr = p
    }

    func scanLazy() -> MsgPackValue {
        let begin = start.distance(to: ptr)
        let kind = scanLazyInner()
        let end = start.distance(to: ptr)
        return MsgPackValue(kind: kind, from: begin, count: max(0, end - begin))
    }

    private func scanLazyInner() -> MsgPackValue.Kind {
        switch readOpCode() {
        case .end, .neverUsed:
            return .none
        case let .uint(c):
            return scanUInt(c)
        case let .int(c):
            return scanInt(c)
        case let .str(c):
            return scanString(c)
        case let .bin(c):
            return scanBinary(c)
        case let .ext(c):
            return scanExtension(c)
        case let .array(c):
            let n = getLength(c)
            guard !corrupt, enterNesting() else { return .none }
            defer { depth -= 1 }
            let start = ptr
            var positions: [UnsafeRawPointer] = []
            positions.reserveCapacity(n)
            for _ in 0 ..< n {
                if corrupt { return .none }
                positions.append(ptr)
                skipOne()
            }
            return .lazyArray(LazyArrayCursor(scanner: self, start: start, count: n, positions: positions))
        case let .map(c):
            let n = getLength(c)
            guard !corrupt, enterNesting() else { return .none }
            defer { depth -= 1 }
            let start = ptr
            var positions: [UnsafeRawPointer] = []
            positions.reserveCapacity(n)
            for _ in 0 ..< n {
                if corrupt { return .none }
                positions.append(ptr)
                skipOne()
                skipOne()
            }
            return .lazyMap(LazyMapCursor(scanner: self, start: start, pairCount: n, positions: positions))
        case let .simple(c):
            return scanSimple(c)
        }
    }

    private func skipBytes(_ n: Int) {
        guard n >= 0, n <= remaining else {
            markCorrupt()
            return
        }
        advanced(by: n)
    }

    func skipOne() {
        switch readOpCode() {
        case .end, .neverUsed:
            return
        case let .uint(c):
            _ = _scanUInt(c)
        case let .int(c):
            _skipInt(c)
        case let .str(c):
            skipBytes(getLength(c))
        case let .bin(c):
            skipBytes(getLength(c))
        case let .ext(c):
            let n = getLength(c)
            skipBytes(1 + n)
        case let .array(c):
            let n = getLength(c)
            guard !corrupt, enterNesting() else { return }
            defer { depth -= 1 }
            for _ in 0 ..< n {
                if corrupt { return }
                skipOne()
            }
        case let .map(c):
            let n = getLength(c)
            guard !corrupt, enterNesting() else { return }
            defer { depth -= 1 }
            for _ in 0 ..< n {
                if corrupt { return }
                skipOne()
                skipOne()
            }
        case let .simple(c):
            _skipSimple(c)
        }
    }

    private func _skipInt(_ c: UInt8) {
        switch c {
        case 0x80: skipBytes(1)
        case 0x81: skipBytes(2)
        case 0x82: skipBytes(4)
        case 0x83: skipBytes(8)
        default: break
        }
    }

    private func _skipSimple(_ c: UInt8) {
        switch c {
        case 0xCA: skipBytes(4)
        case 0xCB: skipBytes(8)
        default: break
        }
    }
}
