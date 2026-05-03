import Foundation
import NIOCore

// RFC 5531 §11 — record marking standard (used over TCP).
//
// Each record fragment is prefixed with a 32-bit record-mark in big-endian
// byte order:
//
//     bit 31 (0x8000_0000) — last-fragment flag
//     bits 30..0           — fragment length (in bytes, ≤ 2^31-1)
//
// A complete RPC message is one or more concatenated fragments, ending with
// the fragment that has the last-fragment flag set. The fragments together
// (without their headers) form the XDR-encoded `rpc_msg`.

enum RPCRecordMarking {
    static let lastFragmentFlag: UInt32 = 0x8000_0000
    static let lengthMask:       UInt32 = 0x7FFF_FFFF

    /// Maximum length we are willing to accept for a single fragment. NFSv4
    /// over TCP usually fits in well under 1 MiB; even very large WRITE/READ
    /// payloads are split. This guard exists to deny obviously hostile peers
    /// that claim e.g. 2 GiB.
    static let defaultMaxFragmentLength: UInt32 = 16 * 1024 * 1024 // 16 MiB
}

/// Wraps a fully-formed RPC message body in a single last-fragment record
/// mark and returns the resulting buffer.
func rpcWrapSingleFragment(_ payload: ByteBuffer) -> ByteBuffer {
    var out = ByteBuffer()
    out.reserveCapacity(payload.readableBytes + 4)
    let header = RPCRecordMarking.lastFragmentFlag | UInt32(payload.readableBytes)
    out.writeInteger(header, endianness: .big, as: UInt32.self)
    var body = payload
    out.writeBuffer(&body)
    return out
}

/// Streaming decoder for RPC record marking (RFC 5531 §11). Feed bytes in,
/// pull fully-assembled messages out. Holds intermediate fragments in an
/// internal accumulator until a last-fragment is observed.
struct RPCRecordMarkingDecoder {
    private var pendingFragments = ByteBuffer()
    let maxFragmentLength: UInt32

    init(maxFragmentLength: UInt32 = RPCRecordMarking.defaultMaxFragmentLength) {
        self.maxFragmentLength = maxFragmentLength
    }

    enum Step {
        case needMore
        case message(ByteBuffer)   // a single, complete RPC message
        case error(RPCFramingError)
    }

    enum DecodeError: Error, Equatable {
        case fragmentTooLarge(declared: UInt32, limit: UInt32)
    }

    /// Pull at most one message out of `input`. The decoder advances
    /// `input.readerIndex` over whatever it consumes; partial fragments are
    /// preserved in internal state for the next call.
    mutating func step(consuming input: inout ByteBuffer) -> Step {
        // Need at least 4 bytes for a record-mark header.
        guard input.readableBytes >= 4 else { return .needMore }

        // Peek the header without consuming until we know the body is also there.
        guard let headerVal = input.getInteger(at: input.readerIndex,
                                               endianness: .big,
                                               as: UInt32.self) else {
            return .needMore
        }
        let last = (headerVal & RPCRecordMarking.lastFragmentFlag) != 0
        let length = headerVal & RPCRecordMarking.lengthMask
        if length > maxFragmentLength {
            return .error(.fragmentTooLarge(declared: length, limit: maxFragmentLength))
        }
        // Header + body must both be present.
        guard input.readableBytes >= 4 + Int(length) else { return .needMore }

        // Consume the header.
        input.moveReaderIndex(forwardBy: 4)
        if length > 0 {
            guard var slice = input.readSlice(length: Int(length)) else {
                // Should not happen — we just verified availability.
                return .error(.truncatedFragment)
            }
            pendingFragments.writeBuffer(&slice)
        }

        if last {
            let assembled = pendingFragments
            pendingFragments = ByteBuffer()
            return .message(assembled)
        } else {
            return .needMore
        }
    }
}

enum RPCFramingError: Error, Equatable {
    case fragmentTooLarge(declared: UInt32, limit: UInt32)
    case truncatedFragment
}
