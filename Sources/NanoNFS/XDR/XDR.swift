import Foundation
import NIOCore
import NIOFoundationCompat

// RFC 4506 XDR primitives.
//
// This file is intentionally NFS-agnostic: it only knows how to put/take
// fixed- and variable-length integers, opaque byte runs, and 4-byte aligned
// padding. Higher layers (RPC, Wire) compose these into NFSv4 structures.

enum XDRError: Error, Equatable {
    /// Underlying buffer ran out before a complete value could be read.
    case truncated
    /// A length prefix exceeded the caller-supplied limit (defence against
    /// hostile/buggy peers — RFC 5531 §11 / RFC 7530 §3.1).
    case lengthExceedsLimit(declared: UInt32, limit: UInt32)
    /// A length-prefixed value used a 4-byte boundary that does not match the
    /// declared length (RFC 4506 §4.10 / §4.11).
    case malformedPadding
    /// A boolean was encoded as a value that is neither 0 nor 1.
    case invalidBoolean(UInt32)
    /// String bytes were not valid UTF-8.
    case invalidUTF8
}

/// Number of pad bytes required to grow `length` up to the next multiple of 4.
@inline(__always)
func xdrPadCount(for length: Int) -> Int {
    let rem = length & 0x3
    return rem == 0 ? 0 : (4 - rem)
}

// MARK: - Encoder

struct XDREncoder {
    var buffer: ByteBuffer

    init(buffer: ByteBuffer = ByteBuffer()) {
        self.buffer = buffer
    }

    // MARK: integers

    /// RFC 4506 §4.1 — signed integer, 32-bit two's complement, big-endian.
    mutating func writeInt32(_ v: Int32) {
        buffer.writeInteger(v, endianness: .big, as: Int32.self)
    }

    /// RFC 4506 §4.2 — unsigned integer, 32-bit big-endian.
    mutating func writeUInt32(_ v: UInt32) {
        buffer.writeInteger(v, endianness: .big, as: UInt32.self)
    }

    /// RFC 4506 §4.5 — signed hyper, 64-bit big-endian.
    mutating func writeInt64(_ v: Int64) {
        buffer.writeInteger(v, endianness: .big, as: Int64.self)
    }

    /// RFC 4506 §4.5 — unsigned hyper, 64-bit big-endian.
    mutating func writeUInt64(_ v: UInt64) {
        buffer.writeInteger(v, endianness: .big, as: UInt64.self)
    }

    /// RFC 4506 §4.4 — boolean, encoded as the integer 0 or 1.
    mutating func writeBool(_ v: Bool) {
        writeUInt32(v ? 1 : 0)
    }

    // MARK: opaque

    /// RFC 4506 §4.9 — fixed-length opaque, padded to 4-byte boundary with zeros.
    mutating func writeFixedOpaque(_ bytes: some Collection<UInt8>) {
        buffer.writeBytes(bytes)
        let pad = xdrPadCount(for: bytes.count)
        if pad > 0 {
            buffer.writeRepeatingByte(0, count: pad)
        }
    }

    mutating func writeFixedOpaque(_ data: Data) {
        buffer.writeBytes(data)
        let pad = xdrPadCount(for: data.count)
        if pad > 0 {
            buffer.writeRepeatingByte(0, count: pad)
        }
    }

    /// RFC 4506 §4.10 — variable-length opaque: length (UInt32) + bytes + zero pad.
    mutating func writeVariableOpaque(_ data: Data) {
        precondition(data.count <= UInt32.max, "XDR variable opaque exceeds UInt32.max")
        writeUInt32(UInt32(data.count))
        writeFixedOpaque(data)
    }

    mutating func writeVariableOpaque(_ bytes: some Collection<UInt8>) {
        precondition(bytes.count <= Int(UInt32.max), "XDR variable opaque exceeds UInt32.max")
        writeUInt32(UInt32(bytes.count))
        writeFixedOpaque(bytes)
    }

    /// RFC 4506 §4.11 — string is a variable-length opaque of UTF-8 bytes.
    mutating func writeString(_ s: String) {
        writeVariableOpaque(Data(s.utf8))
    }

    /// Reserve a UInt32 slot at the current write position and return its
    /// absolute offset. Useful for "fill in length later" patterns (e.g. RPC
    /// record-mark, COMPOUND op array length).
    @discardableResult
    mutating func placeholderUInt32() -> Int {
        let at = buffer.writerIndex
        writeUInt32(0)
        return at
    }

    /// Overwrite a previously reserved UInt32 placeholder.
    mutating func setUInt32(at offset: Int, _ value: UInt32) {
        buffer.setInteger(value, at: offset, endianness: .big, as: UInt32.self)
    }
}

// MARK: - Decoder

struct XDRDecoder {
    var buffer: ByteBuffer

    init(_ buffer: ByteBuffer) {
        self.buffer = buffer
    }

    // MARK: integers

    mutating func readInt32() throws -> Int32 {
        guard let v = buffer.readInteger(endianness: .big, as: Int32.self) else {
            throw XDRError.truncated
        }
        return v
    }

    mutating func readUInt32() throws -> UInt32 {
        guard let v = buffer.readInteger(endianness: .big, as: UInt32.self) else {
            throw XDRError.truncated
        }
        return v
    }

    mutating func readInt64() throws -> Int64 {
        guard let v = buffer.readInteger(endianness: .big, as: Int64.self) else {
            throw XDRError.truncated
        }
        return v
    }

    mutating func readUInt64() throws -> UInt64 {
        guard let v = buffer.readInteger(endianness: .big, as: UInt64.self) else {
            throw XDRError.truncated
        }
        return v
    }

    mutating func readBool() throws -> Bool {
        let raw = try readUInt32()
        switch raw {
        case 0: return false
        case 1: return true
        default: throw XDRError.invalidBoolean(raw)
        }
    }

    // MARK: opaque

    /// Read exactly `count` bytes followed by 4-byte alignment padding.
    mutating func readFixedOpaque(count: Int) throws -> ByteBuffer {
        guard let slice = buffer.readSlice(length: count) else {
            throw XDRError.truncated
        }
        let pad = xdrPadCount(for: count)
        if pad > 0 {
            guard buffer.readSlice(length: pad) != nil else {
                throw XDRError.truncated
            }
        }
        return slice
    }

    mutating func readFixedOpaqueData(count: Int) throws -> Data {
        var slice = try readFixedOpaque(count: count)
        return slice.readData(length: count) ?? Data()
    }

    mutating func readVariableOpaque(maxLength: UInt32 = .max) throws -> ByteBuffer {
        let len = try readUInt32()
        guard len <= maxLength else {
            throw XDRError.lengthExceedsLimit(declared: len, limit: maxLength)
        }
        return try readFixedOpaque(count: Int(len))
    }

    mutating func readVariableOpaqueData(maxLength: UInt32 = .max) throws -> Data {
        let len = try readUInt32()
        guard len <= maxLength else {
            throw XDRError.lengthExceedsLimit(declared: len, limit: maxLength)
        }
        return try readFixedOpaqueData(count: Int(len))
    }

    mutating func readString(maxLength: UInt32 = .max) throws -> String {
        let bytes = try readVariableOpaqueData(maxLength: maxLength)
        guard let s = String(data: bytes, encoding: .utf8) else {
            throw XDRError.invalidUTF8
        }
        return s
    }

    /// Number of unconsumed bytes still present in the underlying buffer.
    var bytesRemaining: Int { buffer.readableBytes }
}
