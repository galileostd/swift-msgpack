import Foundation

private protocol _MsgPackDictionaryDecodableMarker {}

extension Dictionary: _MsgPackDictionaryDecodableMarker where Key: Encodable, Value: Decodable {}

private protocol _MsgPackArrayDecodableMarker {}

extension Array: _MsgPackArrayDecodableMarker where Element: Decodable {}

open class MsgPackDecoder {
    /// Options that control how ``MsgPackDecoder`` materialises the
    /// root MessagePack value before handing it to the Codable
    /// machinery. Bit positions are stable; new options are added
    /// only by appending higher bits.
    public struct DecodingOption: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }

        /// Skip eager construction of the full `MsgPackValue` tree.
        /// Containers are recorded as cursors and materialised on
        /// demand as the Codable path walks into them. Produces a
        /// result bit-identical to the eager path.
        ///
        /// See the README "Performance" section for guidance on when
        /// this helps and when the eager default is preferable.
        ///
        /// - Important: The lazy IR borrows the lifetime of the
        ///   `Data` passed to ``decode(_:from:)``. Do not retain the
        ///   decoder or container objects past the call — the cursors
        ///   hold raw pointers that are only valid while the decode
        ///   call is on the stack. ``MsgPackDecoder`` is not
        ///   `Sendable`; do not share a single decoder across threads.
        public static let lazyScan = DecodingOption(rawValue: 1 << 0)
    }

    let options: DecodingOption

    open var userInfo: [CodingUserInfoKey: Any] = [:]

    public init() {
        options = []
    }

    public init(options: DecodingOption) {
        self.options = options
    }

    private func scanRoot(_ scanner: MsgPackScanner) -> MsgPackValue {
        if options.contains(.lazyScan) {
            return scanner.scanLazy()
        }
        return scanner.scan()
    }

    open func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try data.withUnsafeBytes { rawBuffer in
            try decodeCore(type, base: rawBuffer.baseAddress, count: rawBuffer.count, source: data) {
                try $0.unwrap(as: T.self)
            }
        }
    }

    /// Decodes a value directly from a raw byte buffer, without wrapping it
    /// in `Data`. Intended for batch consumers that read many records into
    /// one contiguous block and decode each record in place from a rebased
    /// slice of that block.
    ///
    /// - Important: `buffer` must stay valid for the duration of the call.
    ///   Nothing derived from it is retained past the return: a decoded
    ///   `MsgPackRawValue`/`Data` field copies its bytes out.
    open func decode<T: Decodable>(_ type: T.Type, from buffer: UnsafeRawBufferPointer) throws -> T {
        try decodeCore(type, base: buffer.baseAddress, count: buffer.count, source: borrowedData(buffer)) {
            try $0.unwrap(as: T.self)
        }
    }

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
    open func decode<T: DecodableWithConfiguration>(_ type: T.Type, from data: Data, configuration: T.DecodingConfiguration) throws -> T {
        try data.withUnsafeBytes { rawBuffer in
            try decodeCore(type, base: rawBuffer.baseAddress, count: rawBuffer.count, source: data) {
                try $0.unwrap(as: T.self, configuration: configuration)
            }
        }
    }

    /// Buffer-based variant of ``decode(_:from:configuration:)``. See
    /// ``decode(_:from:)-swift.method`` for the lifetime contract.
    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
    open func decode<T: DecodableWithConfiguration>(_ type: T.Type, from buffer: UnsafeRawBufferPointer, configuration: T.DecodingConfiguration) throws -> T {
        try decodeCore(type, base: buffer.baseAddress, count: buffer.count, source: borrowedData(buffer)) {
            try $0.unwrap(as: T.self, configuration: configuration)
        }
    }

    /// A no-copy `Data` view of `buffer`, used only as the slicing source for
    /// `MsgPackRawValue` fields. It never outlives the decode call.
    private func borrowedData(_ buffer: UnsafeRawBufferPointer) -> Data {
        guard let base = buffer.baseAddress, !buffer.isEmpty else { return Data() }
        return Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: buffer.count, deallocator: .none)
    }

    private func decodeCore<T>(_ type: T.Type, base: UnsafeRawPointer?, count: Int, source: Data, _ unwrap: (_MsgPackDecoder) throws -> T) throws -> T {
        let value: MsgPackValue
        if let base, count > 0 {
            let scanner: MsgPackScanner = .init(ptr: base, count: count)
            value = scanRoot(scanner)
            if scanner.corrupt {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "The given data is not valid MessagePack: truncated or malformed input."
                ))
            }
        } else {
            value = .none
        }
        let decoder: _MsgPackDecoder = .init(from: value, sourceData: source, userInfo: userInfo)
        do {
            return try unwrap(decoder)
        } catch {
            if let error = error as? MsgPackDecodingError {
                throw error.asDecodingError(type, codingPath: [])
            }
            throw error
        }
    }

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
    open func decode<T, C>(_ type: T.Type, from data: Data, configuration: C.Type) throws -> T where T: DecodableWithConfiguration, C: DecodingConfigurationProviding, T.DecodingConfiguration == C.DecodingConfiguration {
        try decode(type, from: data, configuration: C.decodingConfiguration)
    }
}

public protocol MsgPackDecodable: Decodable {
    var type: Int8 { get }
    init(msgPack data: Data) throws
}

public typealias MsgPackCodable = MsgPackDecodable & MsgPackEncodable

class _MsgPackDecoder: Decoder {
    var codingPath: [CodingKey]
    var value: MsgPackValue
    let sourceData: Data
    var userInfo: [CodingUserInfoKey: Any]

    var rawData: Data? {
        value.rawData(from: sourceData)
    }

    init(from value: MsgPackValue, sourceData: Data, userInfo: [CodingUserInfoKey: Any] = [:], at codingPath: [CodingKey] = []) {
        self.sourceData = sourceData
        self.userInfo = userInfo
        self.value = value
        self.codingPath = codingPath
    }

    func container<Key>(keyedBy _: Key.Type) throws -> KeyedDecodingContainer<Key> where Key: CodingKey {
        switch value.kind {
        case .map, .lazyMap: break
        default:
            throw DecodingError.typeMismatch([String: Any].self, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Expected to decode \([String: Any].self) but found \(value.debugDataTypeDescription) instead."
            ))
        }
        return KeyedDecodingContainer(MsgPackKeyedDecodingContainer<Key>(referencing: self, container: value))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        switch value.kind {
        case .array, .map, .none, .lazyArray, .lazyMap: break
        default:
            throw DecodingError.typeMismatch([Any].self, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Expected to decode \([Any].self) but found \(value.debugDataTypeDescription) instead."
            ))
        }

        return MsgPackUnkeyedDecodingContainer(referencing: self, container: value)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        _MsgPackSingleValueDecodingContainer(decoder: self, codingPath: codingPath, value: value)
    }
}

private extension _MsgPackDecoder {
    func valueNotFound<T>(_ type: T.Type) -> DecodingError {
        DecodingError.valueNotFound(type, DecodingError.Context(
            codingPath: codingPath,
            debugDescription: "Cannot get value of type \(type) -- found nil value instead."
        ))
    }

    func numberDoesNotFit<T, V>(_ v: V, in type: T.Type) -> DecodingError {
        DecodingError.dataCorrupted(DecodingError.Context(
            codingPath: codingPath,
            debugDescription: "Parsed MessagePack number \(v) does not fit in \(type)."
        ))
    }

    func unbox(_ value: MsgPackValue, as type: Bool.Type) throws -> Bool {
        if case let .literal(value) = value.kind {
            switch value {
            case let .bool(v): return v
            case .nil:
                throw valueNotFound(type)
            default:
                break
            }
        }

        throw DecodingError.typeMismatch(type, DecodingError.Context(
            codingPath: codingPath,
            debugDescription: "Expected to decode \(type) but found \(value.debugDataTypeDescription) instead."
        ))
    }

    func unbox(_ value: MsgPackValue, as type: String.Type) throws -> String {
        if case let .literal(value) = value.kind {
            switch value {
            case let .str(v):
                guard let s = String._tryFromUTF8(v) else {
                    throw DecodingError.dataCorrupted(DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "The given string is not valid UTF-8."
                    ))
                }
                return s
            case .nil:
                throw valueNotFound(type)
            default:
                break
            }
        }

        throw DecodingError.typeMismatch(type, DecodingError.Context(
            codingPath: codingPath,
            debugDescription: "Expected to decode \(type) but found \(value.debugDataTypeDescription) instead."
        ))
    }

    func unboxFloat32(_ value: MsgPackValue) throws -> Float {
        if case let .literal(f) = value.kind {
            switch f {
            case let .float32(v):
                return v
            case let .float64(v):
                return Float(v)
            case let .int(v):
                return Float(v)
            case let .uint(v):
                return Float(v)
            case .nil:
                throw valueNotFound(Float.self)
            default:
                break
            }
        }

        throw DecodingError.typeMismatch(Float.self, DecodingError.Context(
            codingPath: codingPath,
            debugDescription: "Expected to decode \(Float.self) but found \(value.debugDataTypeDescription) instead."
        ))
    }

    func unboxFloat64(_ value: MsgPackValue) throws -> Double {
        if case let .literal(f) = value.kind {
            switch f {
            case let .float32(v):
                return Double(v)
            case let .float64(v):
                return v
            case let .int(v):
                return Double(v)
            case let .uint(v):
                return Double(v)
            case .nil:
                throw valueNotFound(Double.self)
            default:
                break
            }
        }

        throw DecodingError.typeMismatch(Double.self, DecodingError.Context(
            codingPath: codingPath,
            debugDescription: "Expected to decode \(Double.self) but found \(value.debugDataTypeDescription) instead."
        ))
    }

    func unboxInt<T: SignedInteger & FixedWidthInteger>(_ value: MsgPackValue) throws -> T {
        if case let .literal(vv) = value.kind {
            switch vv {
            case let .uint(v):
                guard let n = T(exactly: v) else {
                    throw numberDoesNotFit(v, in: T.self)
                }
                return n
            case let .int(v):
                guard let n = T(exactly: v) else {
                    throw numberDoesNotFit(v, in: T.self)
                }
                return n
            case .nil:
                throw valueNotFound(T.self)
            default:
                break
            }
        }

        throw DecodingError.typeMismatch(T.self, DecodingError.Context(
            codingPath: codingPath,
            debugDescription: "Expected to decode \(T.self) but found \(value.debugDataTypeDescription) instead."
        ))
    }

    func unboxUInt<T: UnsignedInteger & FixedWidthInteger>(_ value: MsgPackValue) throws -> T {
        if case let .literal(literal) = value.kind {
            switch literal {
            case let .uint(v):
                guard let n = T(exactly: v) else {
                    throw numberDoesNotFit(v, in: T.self)
                }
                return n
            case let .int(v):
                guard let n = T(exactly: v) else {
                    throw numberDoesNotFit(v, in: T.self)
                }
                return n
            case .nil:
                throw valueNotFound(T.self)
            default:
                break
            }
        }

        throw DecodingError.typeMismatch(T.self, DecodingError.Context(
            codingPath: codingPath,
            debugDescription: "Expected to decode \(T.self) but found \(value.debugDataTypeDescription) instead."
        ))
    }
}

extension _MsgPackDecoder {
    func unwrap<T: Decodable>(as type: T.Type) throws -> T {
        if type == MsgPackRawValue.self {
            guard let d = rawData else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: codingPath,
                    debugDescription: "MsgPackRawValue requires MsgPackDecoder."
                ))
            }
            return MsgPackRawValue(d) as! T
        }
        if type == Data.self || type == NSData.self {
            return try unwrapData() as! T
        }
        if let type = type as? MsgPackDecodable.Type {
            let value = try unwrapMsgPackDecodable(as: type)
            return value as! T
        }
        if T.self is _MsgPackDictionaryDecodableMarker.Type {
            try checkDictionay(as: T.self)
        }
        if T.self is _MsgPackArrayDecodableMarker.Type {
            try checkArray(as: T.self)
        }
        return try T(from: self)
    }

    func unwrap<T: DecodableWithConfiguration>(as type: T.Type, configuration: T.DecodingConfiguration) throws -> T {
        try type.init(from: self, configuration: configuration)
    }

    func unwrapData() throws -> Data {
        switch value.kind {
        case let .literal(.bin(v)):
            v
        case let .literal(.str(v)):
            .init(buffer: v)
        default:
            throw DecodingError.typeMismatch(Data.self, DecodingError.Context(codingPath: codingPath, debugDescription: ""))
        }
    }

    func unwrapMsgPackDecodable(as type: MsgPackDecodable.Type) throws -> MsgPackDecodable {
        guard case let .ext(typeNo, data) = value.kind else {
            throw DecodingError.typeMismatch(MsgPackDecodable.self, DecodingError.Context(codingPath: codingPath, debugDescription: ""))
        }
        let value = try type.init(msgPack: data)
        guard value.type == typeNo else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: codingPath, debugDescription: "extension type number mismatch: expected: \(value.type) got: \(typeNo)"))
        }
        return value
    }

    private func checkDictionay<T: Decodable>(as _: T.Type) throws {
        guard (T.self as? (_MsgPackDictionaryDecodableMarker & Decodable).Type) != nil else {
            preconditionFailure("Must only be called of T implements _MsgPackDictionaryDecodableMarker")
        }
        switch value.kind {
        case .map, .lazyMap: break
        default:
            throw DecodingError.typeMismatch(T.self, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Expected to decode \(T.self) but found \(value.debugDataTypeDescription) instead."
            ))
        }
    }

    private func checkArray<T: Decodable>(as _: T.Type) throws {
        guard (T.self as? (_MsgPackArrayDecodableMarker & Decodable).Type) != nil else {
            preconditionFailure("Must only be called of T implements _MsgPackArrayDecodableMarker")
        }
        switch value.kind {
        case .array, .lazyArray: break
        default:
            throw DecodingError.typeMismatch([MsgPackValue].self, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Expected to decode \([MsgPackValue].self) but found \(value.debugDataTypeDescription) instead."
            ))
        }
    }
}

private struct _MsgPackSingleValueDecodingContainer: SingleValueDecodingContainer {
    let decoder: _MsgPackDecoder
    let codingPath: [CodingKey]
    let value: MsgPackValue

    init(decoder: _MsgPackDecoder, codingPath: [CodingKey], value: MsgPackValue) {
        self.decoder = decoder
        self.codingPath = codingPath
        self.value = value
    }

    func decodeNil() -> Bool {
        if case .literal(.nil) = value.kind {
            return true
        } else {
            return false
        }
    }

    func decode(_: Bool.Type) throws -> Bool {
        try decoder.unbox(value, as: Bool.self)
    }

    func decode(_ type: String.Type) throws -> String {
        try decoder.unbox(value, as: type)
    }

    func decode(_: Double.Type) throws -> Double {
        try decoder.unboxFloat64(value)
    }

    func decode(_: Float.Type) throws -> Float {
        try decoder.unboxFloat32(value)
    }

    func decode(_: Int.Type) throws -> Int {
        try decoder.unboxInt(value)
    }

    func decode(_: Int8.Type) throws -> Int8 {
        try decoder.unboxInt(value)
    }

    func decode(_: Int16.Type) throws -> Int16 {
        try decoder.unboxInt(value)
    }

    func decode(_: Int32.Type) throws -> Int32 {
        try decoder.unboxInt(value)
    }

    func decode(_: Int64.Type) throws -> Int64 {
        try decoder.unboxInt(value)
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    func decode(_: Int128.Type) throws -> Int128 {
        try decoder.unboxInt(value)
    }

    func decode(_: UInt.Type) throws -> UInt {
        try decoder.unboxUInt(value)
    }

    func decode(_: UInt8.Type) throws -> UInt8 {
        try decoder.unboxUInt(value)
    }

    func decode(_: UInt16.Type) throws -> UInt16 {
        try decoder.unboxUInt(value)
    }

    func decode(_: UInt32.Type) throws -> UInt32 {
        try decoder.unboxUInt(value)
    }

    func decode(_: UInt64.Type) throws -> UInt64 {
        try decoder.unboxUInt(value)
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    func decode(_: UInt128.Type) throws -> UInt128 {
        try decoder.unboxUInt(value)
    }

    func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
        try decoder.unwrap(as: type)
    }
}

private struct MsgPackUnkeyedDecodingContainer: UnkeyedDecodingContainer {
    private enum Source {
        case eager([MsgPackValue])
        case lazy(LazyArrayCursor)

        var count: Int {
            switch self {
            case let .eager(arr): return arr.count
            case let .lazy(c): return c.count
            }
        }

        func element(at index: Int) -> MsgPackValue {
            switch self {
            case let .eager(arr): return arr[index]
            case let .lazy(c): return c.element(at: index)
            }
        }
    }

    private let decoder: _MsgPackDecoder
    private(set) var codingPath: [CodingKey]
    public private(set) var currentIndex: Int
    private var source: Source

    init(referencing decoder: _MsgPackDecoder, container: MsgPackValue) {
        self.decoder = decoder
        codingPath = decoder.codingPath
        currentIndex = 0
        if case let .lazyArray(c) = container.kind {
            source = .lazy(c)
        } else {
            source = .eager(container.asArray())
        }
    }

    var count: Int? {
        source.count
    }

    var isAtEnd: Bool {
        currentIndex >= count!
    }

    mutating func decodeNil() throws -> Bool {
        let value = try getNextValue(ofType: Never.self).kind
        if case .literal(.nil) = value {
            currentIndex += 1
            return true
        }
        return false
    }

    mutating func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
        let decoder = try decoderForNextElement(ofType: UnkeyedDecodingContainer.self)
        let container: KeyedDecodingContainer = try decoder.container(keyedBy: type)
        currentIndex += 1
        return container
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        let decoder = try decoderForNextElement(ofType: UnkeyedDecodingContainer.self)
        let container: UnkeyedDecodingContainer = try decoder.unkeyedContainer()
        currentIndex += 1
        return container
    }

    mutating func superDecoder() throws -> Decoder {
        let decoder = try decoderForNextElement(ofType: Decoder.self)
        currentIndex += 1
        return decoder
    }

    mutating func decode(_: Bool.Type) throws -> Bool {
        let value = try getNextValue(ofType: String.self)
        currentIndex += 1
        return try decoder.unbox(value, as: Bool.self)
    }

    mutating func decode(_: String.Type) throws -> String {
        let value = try getNextValue(ofType: String.self)
        currentIndex += 1
        return try decoder.unbox(value, as: String.self)
    }

    mutating func decode(_: Double.Type) throws -> Double {
        try decodeFloat64()
    }

    mutating func decode(_: Float.Type) throws -> Float {
        try decodeFloat32()
    }

    mutating func decode(_: Int.Type) throws -> Int {
        try decodeInt()
    }

    mutating func decode(_: Int8.Type) throws -> Int8 {
        try decodeInt()
    }

    mutating func decode(_: Int16.Type) throws -> Int16 {
        try decodeInt()
    }

    mutating func decode(_: Int32.Type) throws -> Int32 {
        try decodeInt()
    }

    mutating func decode(_: Int64.Type) throws -> Int64 {
        try decodeInt()
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    mutating func decode(_: Int128.Type) throws -> Int128 {
        try decodeInt()
    }

    mutating func decode(_: UInt.Type) throws -> UInt {
        try decodeUInt()
    }

    mutating func decode(_: UInt8.Type) throws -> UInt8 {
        try decodeUInt()
    }

    mutating func decode(_: UInt16.Type) throws -> UInt16 {
        try decodeUInt()
    }

    mutating func decode(_: UInt32.Type) throws -> UInt32 {
        try decodeUInt()
    }

    mutating func decode(_: UInt64.Type) throws -> UInt64 {
        try decodeUInt()
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    mutating func decode(_: UInt128.Type) throws -> UInt128 {
        try decodeUInt()
    }

    mutating func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
        let newDecoder: _MsgPackDecoder = try decoderForNextElement(ofType: T.self)
        do {
            let result: T = try newDecoder.unwrap(as: T.self)
            currentIndex += 1
            return result
        } catch {
            if let error = error as? MsgPackDecodingError {
                throw error.asDecodingError(type, codingPath: codingPath)
            }
            throw error
        }
    }

    private mutating func decoderForNextElement<T>(ofType _: T.Type) throws -> _MsgPackDecoder {
        let value = try getNextValue(ofType: T.self)
        let newPath = codingPath + [MsgPackKey(index: currentIndex)]
        return _MsgPackDecoder(from: value, sourceData: decoder.sourceData, userInfo: decoder.userInfo, at: newPath)
    }

    @inline(__always)
    private func getNextValue<T>(ofType _: T.Type) throws -> MsgPackValue {
        guard !isAtEnd else {
            let message: String
            if T.self == MsgPackUnkeyedDecodingContainer.self {
                message = "Cannot get nested unkeyed container -- unkeyed container is at end."
            } else if T.self == Decoder.self {
                message = "Cannot get superDecoder() -- unkeyed container is at end."
            } else {
                message = "Unkeyed container is at end."
            }

            var path = codingPath
            path.append(MsgPackKey(index: currentIndex))

            throw DecodingError.valueNotFound(
                T.self,
                .init(codingPath: path,
                      debugDescription: message,
                      underlyingError: nil)
            )
        }
        return source.element(at: currentIndex)
    }

    @inline(__always)
    private mutating func decodeUInt<T: UnsignedInteger & FixedWidthInteger>() throws -> T {
        defer {
            currentIndex += 1
        }
        let value = try getNextValue(ofType: T.self)
        return try decoder.unboxUInt(value)
    }

    @inline(__always)
    private mutating func decodeInt<T: SignedInteger & FixedWidthInteger>() throws -> T {
        defer {
            currentIndex += 1
        }
        let value = try getNextValue(ofType: T.self)
        return try decoder.unboxInt(value)
    }

    @inline(__always)
    private mutating func decodeFloat32() throws -> Float {
        let value = try getNextValue(ofType: Float.self)
        let result = try decoder.unboxFloat32(value)
        currentIndex += 1
        return result
    }

    @inline(__always)
    private mutating func decodeFloat64() throws -> Double {
        let value = try getNextValue(ofType: Double.self)
        let result = try decoder.unboxFloat64(value)
        currentIndex += 1
        return result
    }
}

/// Key lookup over an eagerly-scanned map without allocating a `String` per
/// on-wire key. Declaration-order lookups are matched by raw UTF-8 byte
/// comparison against a monotonic cursor (repeat lookups of the same key —
/// the `decodeIfPresent` pattern — re-scan only the already-visited prefix).
/// The first lookup that would make the linear phase expensive builds a
/// keep-first `String` index once, restoring the old dictionary behaviour.
final class EagerMapCursor {
    /// Beyond this many visited pairs, a linear re-scan stops being cheaper
    /// than materialising the key index.
    private static let indexThreshold = 32

    private let flat: [MsgPackValue]
    private let pairCount: Int
    private var cursor = 0
    private var index: [String: Int]?

    init(container: MsgPackValue) {
        switch container.kind {
        case let .array(a), let .map(a):
            flat = a
        default:
            let pairs = container.asDictionary()
            var f: [MsgPackValue] = []
            f.reserveCapacity(pairs.count * 2)
            for (k, v) in pairs {
                f.append(k)
                f.append(v)
            }
            flat = f
        }
        pairCount = flat.count / 2
    }

    func value(forStringKey key: String) -> MsgPackValue? {
        if let index {
            guard let i = index[key] else { return nil }
            return flat[i * 2 + 1]
        }
        if cursor > Self.indexThreshold {
            guard let i = ensureIndex()[key] else { return nil }
            return flat[i * 2 + 1]
        }
        // 1. Already-visited pairs (repeat lookups, out-of-order keys).
        for i in 0 ..< cursor where flat[i * 2].matchesKeyBytes(key) {
            return flat[i * 2 + 1]
        }
        // 2. Walk forward; declaration-order decoding matches immediately.
        while cursor < pairCount {
            let i = cursor
            cursor += 1
            if flat[i * 2].matchesKeyBytes(key) {
                return flat[i * 2 + 1]
            }
        }
        return nil
    }

    func allStringKeys() -> [String] {
        Array(ensureIndex().keys)
    }

    func contains(stringKey key: String) -> Bool {
        value(forStringKey: key) != nil
    }

    private func ensureIndex() -> [String: Int] {
        if let index { return index }
        var d = [String: Int](minimumCapacity: pairCount)
        for i in 0 ..< pairCount {
            if case let .literal(.str(buf)) = flat[i * 2].kind, let s = String._tryFromUTF8(buf), d[s] == nil {
                d[s] = i
            }
        }
        index = d
        return d
    }
}

private struct MsgPackKeyedDecodingContainer<K: CodingKey>: KeyedDecodingContainerProtocol {
    typealias Key = K

    private enum Source {
        case eager(EagerMapCursor)
        case lazy(LazyMapCursor)

        func value(forStringKey key: String) -> MsgPackValue? {
            switch self {
            case let .eager(c): return c.value(forStringKey: key)
            case let .lazy(c): return c.value(forStringKey: key)
            }
        }

        func allStringKeys() -> [String] {
            switch self {
            case let .eager(c): return c.allStringKeys()
            case let .lazy(c): return c.allStringKeys()
            }
        }

        func contains(stringKey key: String) -> Bool {
            switch self {
            case let .eager(c): return c.contains(stringKey: key)
            case let .lazy(c): return c.contains(stringKey: key)
            }
        }
    }

    private let decoder: _MsgPackDecoder
    private(set) var codingPath: [CodingKey]
    private var source: Source

    init(referencing decoder: _MsgPackDecoder, container: MsgPackValue) {
        self.decoder = decoder
        if case let .lazyMap(c) = container.kind {
            source = .lazy(c)
        } else {
            source = .eager(EagerMapCursor(container: container))
        }
        codingPath = decoder.codingPath
    }

    var allKeys: [Key] {
        source.allStringKeys().compactMap { Key(stringValue: $0) }
    }

    func contains(_ key: Key) -> Bool {
        source.contains(stringKey: key.stringValue)
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        if case .literal(.nil) = try getValue(forKey: key).kind {
            return true
        } else {
            return false
        }
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        let value = try getValue(forKey: key)
        return try decoder.unbox(value, as: type)
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        let value = try getValue(forKey: key)
        return try decoder.unbox(value, as: type)
    }

    func decode(_: Double.Type, forKey key: Key) throws -> Double {
        try decodeFloat64(key: key)
    }

    func decode(_: Float.Type, forKey key: Key) throws -> Float {
        try decodeFloat32(key: key)
    }

    func decode(_: Int.Type, forKey key: Key) throws -> Int {
        try decodeInt(key: key)
    }

    func decode(_: Int8.Type, forKey key: Key) throws -> Int8 {
        try decodeInt(key: key)
    }

    func decode(_: Int16.Type, forKey key: Key) throws -> Int16 {
        try decodeInt(key: key)
    }

    func decode(_: Int32.Type, forKey key: Key) throws -> Int32 {
        try decodeInt(key: key)
    }

    func decode(_: Int64.Type, forKey key: Key) throws -> Int64 {
        try decodeInt(key: key)
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    func decode(_: Int128.Type, forKey key: Key) throws -> Int128 {
        try decodeInt(key: key)
    }

    func decode(_: UInt.Type, forKey key: Key) throws -> UInt {
        try decodeUInt(key: key)
    }

    func decode(_: UInt8.Type, forKey key: Key) throws -> UInt8 {
        try decodeUInt(key: key)
    }

    func decode(_: UInt16.Type, forKey key: Key) throws -> UInt16 {
        try decodeUInt(key: key)
    }

    func decode(_: UInt32.Type, forKey key: Key) throws -> UInt32 {
        try decodeUInt(key: key)
    }

    func decode(_: UInt64.Type, forKey key: Key) throws -> UInt64 {
        try decodeUInt(key: key)
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    func decode(_: UInt128.Type, forKey key: Key) throws -> UInt128 {
        try decodeUInt(key: key)
    }

    func decode<T>(_ type: T.Type, forKey key: Key) throws -> T where T: Decodable {
        let newDecoder: _MsgPackDecoder = try decoderForKey(key)
        do {
            return try newDecoder.unwrap(as: T.self)
        } catch {
            if let error = error as? MsgPackDecodingError {
                throw error.asDecodingError(type, codingPath: codingPath)
            }
            throw error
        }
    }

    func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
        try decoderForKey(key).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        try decoderForKey(key).unkeyedContainer()
    }

    func superDecoder() throws -> Decoder {
        try decoderForKey(MsgPackKey.super)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        try decoderForKey(key)
    }

    private func decoderForKey<LocalKey: CodingKey>(_ key: LocalKey) throws -> _MsgPackDecoder {
        let value = try getValue(forKey: key)
        let newPath: [CodingKey] = codingPath + [key]
        return _MsgPackDecoder(from: value, sourceData: decoder.sourceData, userInfo: decoder.userInfo, at: newPath)
    }

    @inline(__always)
    private func getValue<LocalKey: CodingKey>(forKey key: LocalKey) throws -> MsgPackValue {
        guard let value = source.value(forStringKey: key.stringValue) else {
            let context = DecodingError.Context(codingPath: codingPath, debugDescription: "No value assosiated with key \(key) (\"\(key.stringValue)\"")
            throw DecodingError.keyNotFound(key, context)
        }
        return value
    }

    @inline(__always)
    private func decodeFloat32(key: K) throws -> Float {
        let value = try getValue(forKey: key)
        return try decoder.unboxFloat32(value)
    }

    @inline(__always)
    private func decodeFloat64(key: K) throws -> Double {
        let value = try getValue(forKey: key)
        return try decoder.unboxFloat64(value)
    }

    @inline(__always)
    private func decodeInt<T: SignedInteger & FixedWidthInteger>(key: K) throws -> T {
        let value = try getValue(forKey: key)
        do {
            return try decoder.unboxInt(value)
        } catch {
            if let error = error as? MsgPackDecodingError {
                throw error.asDecodingError(T.self, codingPath: codingPath)
            }
            throw error
        }
    }

    @inline(__always)
    private func decodeUInt<T: UnsignedInteger & FixedWidthInteger>(key: K) throws -> T {
        let value = try getValue(forKey: key)
        do {
            return try decoder.unboxUInt(value)
        } catch {
            if let error = error as? MsgPackDecodingError {
                throw error.asDecodingError(T.self, codingPath: codingPath)
            }
            throw error
        }
    }
}

protocol DataNumber {
    func appendBytes(to buffer: inout [UInt8])
}

extension Float: DataNumber {
    func appendBytes(to buffer: inout [UInt8]) {
        withUnsafeBytes(of: bitPattern.bigEndian) {
            buffer.append(contentsOf: $0)
        }
    }
}

extension Double: DataNumber {
    func appendBytes(to buffer: inout [UInt8]) {
        withUnsafeBytes(of: bitPattern.bigEndian) {
            buffer.append(contentsOf: $0)
        }
    }
}

enum MsgPackDecodingError: Error {
    case dataCorrupted
}

extension MsgPackDecodingError {
    func asDecodingError<T>(_ type: T.Type, codingPath: [CodingKey]) -> DecodingError {
        switch self {
        case .dataCorrupted:
            let context = DecodingError.Context(codingPath: codingPath, debugDescription: "Expected to decode \(type) but it failed")
            return DecodingError.dataCorrupted(context)
        }
    }
}
