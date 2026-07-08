import Foundation

private protocol _MsgPackDictionaryEncodableMarker {}

extension Dictionary: _MsgPackDictionaryEncodableMarker where Key: Encodable, Value: Encodable {}

public protocol MsgPackEncodable: Encodable {
    func encodeMsgPack() throws -> [UInt8]
    var type: Int8 { get }
}

open class MsgPackEncoder {
    public struct OutputOption: OptionSet, Sendable {
        public let rawValue: UInt

        public init(rawValue: UInt) {
            self.rawValue = rawValue
        }

        public static let str8FormatSupport = OutputOption(rawValue: 1 << 0)
    }

    let options: OutputOption

    open var userInfo: [CodingUserInfoKey: Any] = [:]

    public init(options: OutputOption = [.str8FormatSupport]) {
        self.options = options
    }

    open func encode<T: Encodable>(_ value: T) throws -> Data {
        let buffer = MsgPackWriteBuffer()
        let start = buffer.count
        try buffer.writeValue(value, options: options, userInfo: userInfo, codingPath: [], tail: .none)
        if buffer.count == start {
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: [], debugDescription: "Top-level \(T.self) did not encode any values."))
        }
        return buffer.finish()
    }

    /// Appends the MessagePack encoding of `value` to `out`, without
    /// allocating an intermediate `Data` per call. Intended for batch
    /// producers that concatenate many records into one contiguous buffer.
    ///
    /// On error `out` is left exactly as it was. The buffer is taken over by
    /// value-swap (no copy), so passing the same array across calls reuses
    /// its capacity.
    open func encode<T: Encodable>(_ value: T, into out: inout [UInt8]) throws {
        let buffer = MsgPackWriteBuffer(taking: &out)
        defer { buffer.release(into: &out) }
        let start = buffer.count
        do {
            try buffer.writeValue(value, options: options, userInfo: userInfo, codingPath: [], tail: .none)
        } catch {
            buffer.truncate(to: start)
            throw error
        }
        if buffer.count == start {
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: [], debugDescription: "Top-level \(T.self) did not encode any values."))
        }
    }

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
    open func encode<T: EncodableWithConfiguration>(_ value: T, configuration: T.EncodingConfiguration) throws -> Data {
        let buffer = MsgPackWriteBuffer()
        let start = buffer.count
        try buffer.writeValue(value, configuration: configuration, options: options, userInfo: userInfo, codingPath: [], tail: .none)
        if buffer.count == start {
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: [], debugDescription: "Top-level \(T.self) did not encode any values."))
        }
        return buffer.finish()
    }

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
    open func encode<T, C>(_ value: T, configuration: C.Type) throws -> Data where T: EncodableWithConfiguration, C: EncodingConfigurationProviding, T.EncodingConfiguration == C.EncodingConfiguration {
        try encode(value, configuration: C.encodingConfiguration)
    }
}

// MARK: - Streaming write buffer

/// A single growable contiguous byte buffer that the encoder writes MessagePack
/// directly into — no intermediate value tree. Container headers use the
/// minimal MessagePack size class; when a container crosses a size-class
/// boundary (16 or 65536 entries) the header is grown in place with a one-time
/// `memmove` and all still-open container header offsets are fixed up.
final class MsgPackWriteBuffer {
    private(set) var bytes: [UInt8]
    private var openHeaders: [ContainerHeader] = []
    /// A single encoder instance reused for every nested value within one
    /// top-level encode call. Safe because Codable encoding is strictly
    /// depth-first and synchronous, and every `writeValue` resets the
    /// encoder's `codingPath`/`mapHint` before handing it to `encode(to:)`.
    private var reusableEncoder: _MsgPackEncoder?

    init(minimumCapacity: Int = 256) {
        bytes = []
        bytes.reserveCapacity(minimumCapacity)
    }

    /// Takes over the caller's buffer by swap (no copy); pair with
    /// `release(into:)` to hand it back.
    init(taking out: inout [UInt8]) {
        bytes = []
        swap(&bytes, &out)
    }

    var count: Int { bytes.count }

    func finish() -> Data {
        reusableEncoder = nil
        return Data(bytes)
    }

    func truncate(to n: Int) {
        bytes.removeLast(bytes.count - n)
        openHeaders.removeAll()
    }

    func release(into out: inout [UInt8]) {
        reusableEncoder = nil
        swap(&bytes, &out)
    }

    // MARK: primitive writes

    @inline(__always) func writeByte(_ b: UInt8) { bytes.append(b) }

    @inline(__always) func writeRawBytes<S: Sequence>(_ s: S) where S.Element == UInt8 {
        bytes.append(contentsOf: s)
    }

    @inline(__always) private func appendBE<T: FixedWidthInteger>(_ v: T) {
        withUnsafeBytes(of: v.bigEndian) { bytes.append(contentsOf: $0) }
    }

    @inline(__always) private func patchBE<T: FixedWidthInteger>(_ v: T, at index: Int) {
        var i = index
        withUnsafeBytes(of: v.bigEndian) { raw in
            for b in raw {
                bytes[i] = b
                i += 1
            }
        }
    }

    // MARK: leaf encoders (byte formats identical to v1.3.0)

    func writeNil() { bytes.append(0xC0) }

    func writeBool(_ v: Bool) { bytes.append(v ? 0xC3 : 0xC2) }

    func writeFloat(_ v: Float) {
        bytes.append(0xCA)
        appendBE(v.bitPattern)
    }

    func writeDouble(_ v: Double) {
        bytes.append(0xCB)
        appendBE(v.bitPattern)
    }

    func writeInt<T: SignedInteger & FixedWidthInteger>(_ value: T, codingPath: [CodingKey], additionalKey: CodingKey?) throws {
        if Int.fixMin <= value, value <= Int.fixMax {
            bytes.append(UInt8(bitPattern: Int8(value)))
            return
        }
        if Int8.min <= value, value <= Int8.max {
            bytes.append(0xD0)
            bytes.append(UInt8(bitPattern: Int8(value)))
            return
        }
        if Int16.min <= value, value <= Int16.max {
            bytes.append(0xD1)
            appendBE(Int16(value))
            return
        }
        if Int32.min <= value, value <= Int32.max {
            bytes.append(0xD2)
            appendBE(Int32(value))
            return
        }
        if Int64.min <= value, value <= Int64.max {
            bytes.append(0xD3)
            appendBE(Int64(value))
            return
        }
        throw EncodingError.invalidValue(value, .init(
            codingPath: codingPath.appending(additionalKey),
            debugDescription: "Unable to encode \(T.self).\(value) directly in MessagePack."
        ))
    }

    func writeUInt<T: UnsignedInteger & FixedWidthInteger>(_ value: T, codingPath: [CodingKey], additionalKey: CodingKey?) throws {
        if value <= Int.fixMax {
            bytes.append(UInt8(value))
            return
        }
        if value <= UInt8.max {
            bytes.append(0xCC)
            bytes.append(UInt8(value))
            return
        }
        if value <= UInt16.max {
            bytes.append(0xCD)
            appendBE(UInt16(value))
            return
        }
        if value <= UInt32.max {
            bytes.append(0xCE)
            appendBE(UInt32(value))
            return
        }
        if value <= UInt64.max {
            bytes.append(0xCF)
            appendBE(UInt64(value))
            return
        }
        throw EncodingError.invalidValue(value, .init(
            codingPath: codingPath.appending(additionalKey),
            debugDescription: "Unable to encode \(T.self).\(value) directly in MessagePack."
        ))
    }

    func writeString(_ value: String, codingPath: [CodingKey], additionalKey: CodingKey?, options: MsgPackEncoder.OutputOption) throws {
        guard writeRaw(value.utf8, str8: options.contains(.str8FormatSupport)) else {
            throw EncodingError.invalidValue(value, .init(
                codingPath: codingPath.appending(additionalKey),
                debugDescription: "Unable to encode String.\(value) directly in MessagePack."
            ))
        }
    }

    /// Writes a str-family header + raw UTF-8/byte payload. Returns false when
    /// the payload is too large to represent.
    @discardableResult
    private func writeRaw<C: Collection>(_ value: C, str8: Bool) -> Bool where C.Element == UInt8 {
        let n = value.count
        if n <= UInt.maxUint5 {
            bytes.append(UInt8(0xA0 + n))
        } else if n <= UInt16.max {
            if str8, n <= UInt8.max {
                bytes.append(0xD9)
                bytes.append(UInt8(n))
            } else {
                bytes.append(0xDA)
                appendBE(UInt16(n))
            }
        } else if n <= UInt32.max {
            bytes.append(0xDB)
            appendBE(UInt32(n))
        } else {
            return false
        }
        bytes.append(contentsOf: value)
        return true
    }

    func writeData(_ data: Data, codingPath: [CodingKey], additionalKey: CodingKey?, options: MsgPackEncoder.OutputOption) throws {
        if options.contains(.str8FormatSupport) {
            let n = data.count
            if n <= UInt32.max {
                if n <= UInt8.max {
                    bytes.append(0xC4)
                    bytes.append(UInt8(n))
                } else if n <= UInt16.max {
                    bytes.append(0xC5)
                    appendBE(UInt16(n))
                } else {
                    bytes.append(0xC6)
                    appendBE(UInt32(n))
                }
                bytes.append(contentsOf: data)
                return
            }
        } else if writeRaw(data, str8: false) {
            return
        }
        throw EncodingError.invalidValue(data, .init(
            codingPath: codingPath.appending(additionalKey),
            debugDescription: "Unable to encode Data.\(data) directly in MessagePack."
        ))
    }

    func writeMsgPackRawValue(_ raw: MsgPackRawValue, codingPath: [CodingKey], additionalKey: CodingKey?) throws {
        guard !raw.data.isEmpty else {
            throw EncodingError.invalidValue(raw, .init(
                codingPath: codingPath.appending(additionalKey),
                debugDescription: "MsgPackRawValue has empty data."
            ))
        }
        bytes.append(contentsOf: raw.data)
    }

    func writeExt(_ encodable: MsgPackEncodable, codingPath: [CodingKey], additionalKey: CodingKey?) throws {
        let data = try encodable.encodeMsgPack()
        let n = data.count
        switch n {
        case 1: bytes.append(0xD4)
        case 2: bytes.append(0xD5)
        case 4: bytes.append(0xD6)
        case 8: bytes.append(0xD7)
        case 16: bytes.append(0xD8)
        default:
            if n <= UInt8.max {
                bytes.append(0xC7)
                bytes.append(UInt8(n))
            } else if n <= UInt16.max {
                bytes.append(0xC8)
                appendBE(UInt16(n))
            } else if n <= UInt32.max {
                bytes.append(0xC9)
                appendBE(UInt32(n))
            } else {
                throw EncodingError.invalidValue(encodable, .init(
                    codingPath: codingPath.appending(additionalKey),
                    debugDescription: "Unable to encode \(Swift.type(of: encodable)).\(encodable) directly in MessagePack."
                ))
            }
        }
        bytes.append(UInt8(bitPattern: encodable.type))
        bytes.append(contentsOf: data)
    }

    // MARK: containers

    /// Opens a container, writing a minimal (fixmap/fixarray, 1-byte) header
    /// placeholder, and returns a reference used to grow/patch its count.
    func openContainer(isMap: Bool, divisor: Int) -> ContainerHeader {
        let header = ContainerHeader(offset: bytes.count, isMap: isMap, divisor: divisor)
        bytes.append(isMap ? 0x80 : 0x90)
        openHeaders.append(header)
        return header
    }

    /// Records one more entry in `header` (a pair for maps, an element for
    /// arrays) and updates the on-wire count, growing the header size class in
    /// place if necessary.
    func addEntry(to header: ContainerHeader) {
        header.entryCount += 1
        patchHeader(header)
    }

    private func patchHeader(_ header: ContainerHeader) {
        let count = header.entryCount / header.divisor
        let off = header.offset
        let cur = bytes[off]
        let oldWidth: Int
        if cur == 0xDE || cur == 0xDC {
            oldWidth = 3
        } else if cur == 0xDF || cur == 0xDD {
            oldWidth = 5
        } else {
            oldWidth = 1
        }
        let newWidth = count <= Int(UInt.maxUint4) ? 1 : (count <= Int(UInt16.max) ? 3 : 5)
        if newWidth > oldWidth {
            grow(headerAt: off, oldWidth: oldWidth, newWidth: newWidth)
        }
        switch newWidth {
        case 1:
            bytes[off] = (header.isMap ? 0x80 : 0x90) | UInt8(count)
        case 3:
            bytes[off] = header.isMap ? 0xDE : 0xDC
            patchBE(UInt16(count), at: off + 1)
        default:
            bytes[off] = header.isMap ? 0xDF : 0xDD
            patchBE(UInt32(count), at: off + 1)
        }
    }

    private func grow(headerAt off: Int, oldWidth: Int, newWidth: Int) {
        let insertPos = off + oldWidth
        let k = newWidth - oldWidth
        bytes.insert(contentsOf: repeatElement(0, count: k), at: insertPos)
        for header in openHeaders where header.offset >= insertPos {
            header.offset += k
        }
    }

    // MARK: value dispatch

    func writeValue<E: Encodable>(_ value: E, options: MsgPackEncoder.OutputOption, userInfo: [CodingUserInfoKey: Any], codingPath: [CodingKey], tail: MsgPackPathTail) throws {
        switch value {
        case let raw as MsgPackRawValue:
            try writeMsgPackRawValue(raw, codingPath: codingPath, additionalKey: tail.codingKey)
            return
        case let data as Data:
            try writeData(data, codingPath: codingPath, additionalKey: tail.codingKey, options: options)
            return
        case let msgPack as MsgPackEncodable:
            try writeExt(msgPack, codingPath: codingPath, additionalKey: tail.codingKey)
            return
        default:
            break
        }
        let encoder = reuseEncoder(options: options, userInfo: userInfo, basePath: codingPath, tail: tail, mapHint: isDictionary(value))
        try value.encode(to: encoder)
    }

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
    func writeValue<E: EncodableWithConfiguration>(_ value: E, configuration: E.EncodingConfiguration, options: MsgPackEncoder.OutputOption, userInfo: [CodingUserInfoKey: Any], codingPath: [CodingKey], tail: MsgPackPathTail) throws {
        switch value {
        case let raw as MsgPackRawValue:
            try writeMsgPackRawValue(raw, codingPath: codingPath, additionalKey: tail.codingKey)
            return
        case let data as Data:
            try writeData(data, codingPath: codingPath, additionalKey: tail.codingKey, options: options)
            return
        case let msgPack as MsgPackEncodable:
            try writeExt(msgPack, codingPath: codingPath, additionalKey: tail.codingKey)
            return
        default:
            break
        }
        let encoder = reuseEncoder(options: options, userInfo: userInfo, basePath: codingPath, tail: tail, mapHint: isDictionary(value))
        try value.encode(to: encoder, configuration: configuration)
    }

    private func reuseEncoder(options: MsgPackEncoder.OutputOption, userInfo: [CodingUserInfoKey: Any], basePath: [CodingKey], tail: MsgPackPathTail, mapHint: Bool) -> _MsgPackEncoder {
        if let encoder = reusableEncoder {
            encoder.basePath = basePath
            encoder.tail = tail
            encoder.mapHint = mapHint
            return encoder
        }
        let encoder = _MsgPackEncoder(buffer: self, options: options, userInfo: userInfo, basePath: basePath, tail: tail, mapHint: mapHint)
        reusableEncoder = encoder
        return encoder
    }

    private func isDictionary(_ value: Any) -> Bool {
        if value is _MsgPackDictionaryEncodableMarker { return true }
        if let any = value as? AnyCodable, any.base is _MsgPackDictionaryEncodableMarker { return true }
        return false
    }
}

/// Reference to an open container's header position and running entry count.
/// A class so container structs can share and mutate it by reference.
final class ContainerHeader {
    var offset: Int
    var entryCount: Int = 0
    let isMap: Bool
    /// On-wire count = `entryCount / divisor`. `1` for arrays and keyed maps,
    /// `2` for a Swift dictionary that encodes as an alternating key/value
    /// unkeyed container but must be emitted as a map.
    let divisor: Int

    init(offset: Int, isMap: Bool, divisor: Int) {
        self.offset = offset
        self.isMap = isMap
        self.divisor = divisor
    }
}

// MARK: - Encoder

private final class _MsgPackEncoder: Encoder {
    unowned let buffer: MsgPackWriteBuffer
    let options: MsgPackEncoder.OutputOption
    var userInfo: [CodingUserInfoKey: Any]
    /// The nested coding path is `basePath` + `tail`, materialised only when
    /// something actually reads `codingPath` — the hot path never allocates
    /// the appended array.
    var basePath: [CodingKey]
    var tail: MsgPackPathTail
    var codingPath: [CodingKey] { tail.appended(to: basePath) }
    /// When set, an unkeyed container opened by this encoder is emitted as a
    /// map (used for dictionaries with non-string/int keys).
    var mapHint: Bool

    init(buffer: MsgPackWriteBuffer, options: MsgPackEncoder.OutputOption, userInfo: [CodingUserInfoKey: Any], basePath: [CodingKey], tail: MsgPackPathTail, mapHint: Bool) {
        self.buffer = buffer
        self.options = options
        self.userInfo = userInfo
        self.basePath = basePath
        self.tail = tail
        self.mapHint = mapHint
    }

    func container<Key>(keyedBy _: Key.Type) -> KeyedEncodingContainer<Key> where Key: CodingKey {
        let header = buffer.openContainer(isMap: true, divisor: 1)
        return KeyedEncodingContainer(MsgPackKeyedEncodingContainer(encoder: self, header: header, codingPath: codingPath))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        let header = buffer.openContainer(isMap: mapHint, divisor: mapHint ? 2 : 1)
        return MsgPackUnkeyedEncodingContainer(encoder: self, header: header, codingPath: codingPath)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        MsgPackSingleValueEncodingContainer(encoder: self)
    }
}

// MARK: - Single value container

private struct MsgPackSingleValueEncodingContainer: SingleValueEncodingContainer {
    let encoder: _MsgPackEncoder
    /// Computed on demand: the container is consumed synchronously before the
    /// reused encoder's path can change, and leaf writes only read the path
    /// on their error exits.
    var codingPath: [CodingKey] { encoder.codingPath }

    private var buffer: MsgPackWriteBuffer { encoder.buffer }
    private var basePath: [CodingKey] { encoder.basePath }
    private var tailKey: CodingKey? { encoder.tail.codingKey }

    func encodeNil() throws { buffer.writeNil() }
    func encode(_ value: Bool) throws { buffer.writeBool(value) }
    func encode(_ value: String) throws { try buffer.writeString(value, codingPath: basePath, additionalKey: tailKey, options: encoder.options) }
    func encode(_ value: Double) throws { buffer.writeDouble(value) }
    func encode(_ value: Float) throws { buffer.writeFloat(value) }
    func encode(_ value: Int) throws { try buffer.writeInt(value, codingPath: basePath, additionalKey: tailKey) }
    func encode(_ value: Int8) throws { try buffer.writeInt(value, codingPath: basePath, additionalKey: tailKey) }
    func encode(_ value: Int16) throws { try buffer.writeInt(value, codingPath: basePath, additionalKey: tailKey) }
    func encode(_ value: Int32) throws { try buffer.writeInt(value, codingPath: basePath, additionalKey: tailKey) }
    func encode(_ value: Int64) throws { try buffer.writeInt(value, codingPath: basePath, additionalKey: tailKey) }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    func encode(_ value: Int128) throws { try buffer.writeInt(value, codingPath: basePath, additionalKey: tailKey) }

    func encode(_ value: UInt) throws { try buffer.writeUInt(value, codingPath: basePath, additionalKey: tailKey) }
    func encode(_ value: UInt8) throws { try buffer.writeUInt(value, codingPath: basePath, additionalKey: tailKey) }
    func encode(_ value: UInt16) throws { try buffer.writeUInt(value, codingPath: basePath, additionalKey: tailKey) }
    func encode(_ value: UInt32) throws { try buffer.writeUInt(value, codingPath: basePath, additionalKey: tailKey) }
    func encode(_ value: UInt64) throws { try buffer.writeUInt(value, codingPath: basePath, additionalKey: tailKey) }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    func encode(_ value: UInt128) throws { try buffer.writeUInt(value, codingPath: basePath, additionalKey: tailKey) }

    func encode<T>(_ value: T) throws where T: Encodable {
        try buffer.writeValue(value, options: encoder.options, userInfo: encoder.userInfo, codingPath: basePath, tail: encoder.tail)
    }
}

// MARK: - Unkeyed container

private struct MsgPackUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    let encoder: _MsgPackEncoder
    let header: ContainerHeader
    let codingPath: [CodingKey]

    private var buffer: MsgPackWriteBuffer { encoder.buffer }
    var count: Int { header.entryCount }

    func encodeNil() throws { buffer.addEntry(to: header); buffer.writeNil() }
    func encode(_ value: Bool) throws { buffer.addEntry(to: header); buffer.writeBool(value) }
    func encode(_ value: String) throws { buffer.addEntry(to: header); try buffer.writeString(value, codingPath: codingPath, additionalKey: nil, options: encoder.options) }
    func encode(_ value: Double) throws { buffer.addEntry(to: header); buffer.writeDouble(value) }
    func encode(_ value: Float) throws { buffer.addEntry(to: header); buffer.writeFloat(value) }
    func encode(_ value: Int) throws { buffer.addEntry(to: header); try buffer.writeInt(value, codingPath: codingPath, additionalKey: nil) }
    func encode(_ value: Int8) throws { buffer.addEntry(to: header); try buffer.writeInt(value, codingPath: codingPath, additionalKey: nil) }
    func encode(_ value: Int16) throws { buffer.addEntry(to: header); try buffer.writeInt(value, codingPath: codingPath, additionalKey: nil) }
    func encode(_ value: Int32) throws { buffer.addEntry(to: header); try buffer.writeInt(value, codingPath: codingPath, additionalKey: nil) }
    func encode(_ value: Int64) throws { buffer.addEntry(to: header); try buffer.writeInt(value, codingPath: codingPath, additionalKey: nil) }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    func encode(_ value: Int128) throws { buffer.addEntry(to: header); try buffer.writeInt(value, codingPath: codingPath, additionalKey: nil) }

    func encode(_ value: UInt) throws { buffer.addEntry(to: header); try buffer.writeUInt(value, codingPath: codingPath, additionalKey: nil) }
    func encode(_ value: UInt8) throws { buffer.addEntry(to: header); try buffer.writeUInt(value, codingPath: codingPath, additionalKey: nil) }
    func encode(_ value: UInt16) throws { buffer.addEntry(to: header); try buffer.writeUInt(value, codingPath: codingPath, additionalKey: nil) }
    func encode(_ value: UInt32) throws { buffer.addEntry(to: header); try buffer.writeUInt(value, codingPath: codingPath, additionalKey: nil) }
    func encode(_ value: UInt64) throws { buffer.addEntry(to: header); try buffer.writeUInt(value, codingPath: codingPath, additionalKey: nil) }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    func encode(_ value: UInt128) throws { buffer.addEntry(to: header); try buffer.writeUInt(value, codingPath: codingPath, additionalKey: nil) }

    func encode<T>(_ value: T) throws where T: Encodable {
        let index = count
        buffer.addEntry(to: header)
        let start = buffer.count
        try buffer.writeValue(value, options: encoder.options, userInfo: encoder.userInfo, codingPath: codingPath, tail: .index(index))
        if buffer.count == start { buffer.writeNil() }
    }

    func nestedContainer<NestedKey>(keyedBy _: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        let newPath = codingPath + [MsgPackKey(index: count)]
        buffer.addEntry(to: header)
        let child = buffer.openContainer(isMap: true, divisor: 1)
        return KeyedEncodingContainer(MsgPackKeyedEncodingContainer(encoder: encoder, header: child, codingPath: newPath))
    }

    func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let newPath = codingPath + [MsgPackKey(index: count)]
        buffer.addEntry(to: header)
        let child = buffer.openContainer(isMap: false, divisor: 1)
        return MsgPackUnkeyedEncodingContainer(encoder: encoder, header: child, codingPath: newPath)
    }

    func superEncoder() -> Encoder {
        buffer.addEntry(to: header)
        return _superEncoder(index: count - 1)
    }

    private func _superEncoder(index: Int) -> Encoder {
        _MsgPackEncoder(buffer: buffer, options: encoder.options, userInfo: encoder.userInfo, basePath: codingPath, tail: .index(index), mapHint: false)
    }
}

// MARK: - Keyed container

private struct MsgPackKeyedEncodingContainer<K: CodingKey>: KeyedEncodingContainerProtocol {
    typealias Key = K

    let encoder: _MsgPackEncoder
    let header: ContainerHeader
    let codingPath: [CodingKey]

    private var buffer: MsgPackWriteBuffer { encoder.buffer }

    @inline(__always)
    private func writeKey(_ key: Key) throws {
        buffer.addEntry(to: header)
        try buffer.writeString(key.stringValue, codingPath: codingPath, additionalKey: key, options: encoder.options)
    }

    func encodeNil(forKey key: Key) throws { try writeKey(key); buffer.writeNil() }
    func encode(_ value: Bool, forKey key: Key) throws { try writeKey(key); buffer.writeBool(value) }
    func encode(_ value: String, forKey key: Key) throws { try writeKey(key); try buffer.writeString(value, codingPath: codingPath, additionalKey: key, options: encoder.options) }
    func encode(_ value: Double, forKey key: Key) throws { try writeKey(key); buffer.writeDouble(value) }
    func encode(_ value: Float, forKey key: Key) throws { try writeKey(key); buffer.writeFloat(value) }
    func encode(_ value: Int, forKey key: Key) throws { try writeKey(key); try buffer.writeInt(value, codingPath: codingPath, additionalKey: key) }
    func encode(_ value: Int8, forKey key: Key) throws { try writeKey(key); try buffer.writeInt(value, codingPath: codingPath, additionalKey: key) }
    func encode(_ value: Int16, forKey key: Key) throws { try writeKey(key); try buffer.writeInt(value, codingPath: codingPath, additionalKey: key) }
    func encode(_ value: Int32, forKey key: Key) throws { try writeKey(key); try buffer.writeInt(value, codingPath: codingPath, additionalKey: key) }
    func encode(_ value: Int64, forKey key: Key) throws { try writeKey(key); try buffer.writeInt(value, codingPath: codingPath, additionalKey: key) }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    func encode(_ value: Int128, forKey key: Key) throws { try writeKey(key); try buffer.writeInt(value, codingPath: codingPath, additionalKey: key) }

    func encode(_ value: UInt, forKey key: Key) throws { try writeKey(key); try buffer.writeUInt(value, codingPath: codingPath, additionalKey: key) }
    func encode(_ value: UInt8, forKey key: Key) throws { try writeKey(key); try buffer.writeUInt(value, codingPath: codingPath, additionalKey: key) }
    func encode(_ value: UInt16, forKey key: Key) throws { try writeKey(key); try buffer.writeUInt(value, codingPath: codingPath, additionalKey: key) }
    func encode(_ value: UInt32, forKey key: Key) throws { try writeKey(key); try buffer.writeUInt(value, codingPath: codingPath, additionalKey: key) }
    func encode(_ value: UInt64, forKey key: Key) throws { try writeKey(key); try buffer.writeUInt(value, codingPath: codingPath, additionalKey: key) }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    func encode(_ value: UInt128, forKey key: Key) throws { try writeKey(key); try buffer.writeUInt(value, codingPath: codingPath, additionalKey: key) }

    func encode<T>(_ value: T, forKey key: Key) throws where T: Encodable {
        try writeKey(key)
        let start = buffer.count
        try buffer.writeValue(value, options: encoder.options, userInfo: encoder.userInfo, codingPath: codingPath, tail: .key(key))
        if buffer.count == start { buffer.writeNil() }
    }

    func nestedContainer<NestedKey>(keyedBy _: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        let newPath = codingPath + [key]
        try? writeKey(key)
        let child = buffer.openContainer(isMap: true, divisor: 1)
        return KeyedEncodingContainer(MsgPackKeyedEncodingContainer<NestedKey>(encoder: encoder, header: child, codingPath: newPath))
    }

    func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let newPath = codingPath + [key]
        try? writeKey(key)
        let child = buffer.openContainer(isMap: false, divisor: 1)
        return MsgPackUnkeyedEncodingContainer(encoder: encoder, header: child, codingPath: newPath)
    }

    func superEncoder() -> Encoder {
        superEncoderImpl(key: MsgPackKey.super)
    }

    func superEncoder(forKey key: Key) -> Encoder {
        superEncoderImpl(key: key)
    }

    private func superEncoderImpl(key: CodingKey) -> Encoder {
        try? writeKey2(key)
        return _MsgPackEncoder(buffer: buffer, options: encoder.options, userInfo: encoder.userInfo, basePath: codingPath, tail: .key(key), mapHint: false)
    }

    @inline(__always)
    private func writeKey2(_ key: CodingKey) throws {
        buffer.addEntry(to: header)
        try buffer.writeString(key.stringValue, codingPath: codingPath, additionalKey: key, options: encoder.options)
    }
}

// MARK: - Support

/// The last component of a nested coding path, kept unmaterialised so hot
/// paths never build the appended `[CodingKey]` array (or the "Index N" key)
/// unless an error context or a `codingPath` read actually needs it.
enum MsgPackPathTail {
    case none
    case key(CodingKey)
    case index(Int)

    var codingKey: CodingKey? {
        switch self {
        case .none: return nil
        case let .key(k): return k
        case let .index(i): return MsgPackKey(index: i)
        }
    }

    func appended(to base: [CodingKey]) -> [CodingKey] {
        guard let key = codingKey else { return base }
        return base + [key]
    }
}

struct MsgPackKey: CodingKey {
    public var stringValue: String
    public var intValue: Int?

    public init(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    public init?(intValue: Int) {
        stringValue = intValue.description
        self.intValue = intValue
    }

    init(index: Int) {
        stringValue = "Index \(index)"
        intValue = index
    }

    static let `super`: MsgPackKey = .init(stringValue: "super")
}

extension FixedWidthInteger {
    func appendBigEndian(to buffer: inout [UInt8]) {
        withUnsafeBytes(of: bigEndian) { ptr in
            buffer.append(contentsOf: ptr)
        }
    }
}

private extension [CodingKey] {
    func appending(_ key: CodingKey?) -> [CodingKey] {
        guard let key = key else { return self }
        return self + [key]
    }
}

private extension Int {
    static let fixMax = 0x7F
    static let fixMin = -0x20
}

extension UInt {
    static let maxUint4 = 1 << 4 - 1
    static let maxUint5 = 1 << 5 - 1
}
