import Foundation
import NIOCore

// RFC 5531 §9 — rpc_msg structure (XDR).
//
// struct rpc_msg {
//     unsigned int xid;
//     union switch (msg_type mtype) {
//         case CALL:  call_body  cbody;
//         case REPLY: reply_body rbody;
//     } body;
// };

/// `opaque_auth` (RFC 5531 §8.2). Body is XDR variable-opaque ≤ 400 bytes.
struct RPCOpaqueAuth: Sendable, Hashable {
    var flavor: UInt32
    var body: Data

    static let none = RPCOpaqueAuth(flavor: RPCAuthFlavor.none.rawValue, body: Data())
    /// Maximum `opaque_auth.body` length per RFC 5531 §8.2.
    static let maxBodyLength: UInt32 = 400
}

/// AUTH_SYS credential body (RFC 5531 Appendix A.1).
///
/// struct authsys_parms {
///     unsigned int  stamp;
///     string        machinename<255>;
///     unsigned int  uid;
///     unsigned int  gid;
///     unsigned int  gids<16>;
/// };
struct AuthSysCredential: Sendable, Hashable {
    var stamp: UInt32
    var machineName: String
    var uid: UInt32
    var gid: UInt32
    var gids: [UInt32]

    static let maxMachineNameLength: UInt32 = 255
    static let maxAuxGroupCount:     UInt32 = 16
}

/// A single decoded RPC call. The args (everything after the verifier) is
/// kept as a ByteBuffer so the dispatcher can XDR-decode procedure-specific
/// bodies without re-buffering.
struct RPCCallHeader: Sendable {
    var xid: UInt32
    var rpcversion: UInt32
    var program: UInt32
    var version: UInt32
    var procedure: UInt32
    var credential: RPCOpaqueAuth
    var verifier: RPCOpaqueAuth
}

/// Reasons we might fail to even *parse* an RPC call. These are RPC-layer
/// rejections, distinct from NFS-layer NFS4ERR_* codes.
enum RPCDecodeError: Error, Equatable {
    case truncated
    case notACall(messageType: UInt32)
    case rpcVersionMismatch(saw: UInt32)
    case authBodyTooLong(UInt32)
}

// MARK: - Decoding

extension RPCCallHeader {
    /// Decode `rpc_msg` up through the verifier. Returns the parsed header
    /// plus a decoder positioned at the start of procedure args.
    static func decode(from buffer: ByteBuffer) throws -> (header: RPCCallHeader,
                                                            argsDecoder: XDRDecoder) {
        var dec = XDRDecoder(buffer)
        let xid = try dec.readUInt32()
        let mtype = try dec.readUInt32()
        guard mtype == RPCMessageType.call.rawValue else {
            throw RPCDecodeError.notACall(messageType: mtype)
        }
        let rpcvers = try dec.readUInt32()
        guard rpcvers == RPC.version else {
            throw RPCDecodeError.rpcVersionMismatch(saw: rpcvers)
        }
        let prog = try dec.readUInt32()
        let vers = try dec.readUInt32()
        let proc = try dec.readUInt32()

        let cred = try RPCOpaqueAuth.decode(from: &dec)
        let verf = try RPCOpaqueAuth.decode(from: &dec)

        let header = RPCCallHeader(
            xid: xid,
            rpcversion: rpcvers,
            program: prog,
            version: vers,
            procedure: proc,
            credential: cred,
            verifier: verf
        )
        return (header, dec)
    }
}

extension RPCOpaqueAuth {
    static func decode(from dec: inout XDRDecoder) throws -> RPCOpaqueAuth {
        let flavor = try dec.readUInt32()
        let body = try dec.readVariableOpaqueData(maxLength: RPCOpaqueAuth.maxBodyLength)
        return RPCOpaqueAuth(flavor: flavor, body: body)
    }
}

extension AuthSysCredential {
    /// Parse the AUTH_SYS body bytes (the contents of `RPCOpaqueAuth.body`
    /// when `flavor == AUTH_SYS`).
    static func decode(from body: Data) throws -> AuthSysCredential {
        var buffer = ByteBuffer()
        buffer.writeBytes(body)
        var dec = XDRDecoder(buffer)
        let stamp = try dec.readUInt32()
        let machine = try dec.readString(maxLength: AuthSysCredential.maxMachineNameLength)
        let uid = try dec.readUInt32()
        let gid = try dec.readUInt32()
        let n = try dec.readUInt32()
        guard n <= AuthSysCredential.maxAuxGroupCount else {
            throw XDRError.lengthExceedsLimit(declared: n,
                                              limit: AuthSysCredential.maxAuxGroupCount)
        }
        var gids: [UInt32] = []
        gids.reserveCapacity(Int(n))
        for _ in 0..<n {
            gids.append(try dec.readUInt32())
        }
        return AuthSysCredential(
            stamp: stamp,
            machineName: machine,
            uid: uid,
            gid: gid,
            gids: gids
        )
    }
}

// MARK: - Encoding
//
// All `rpcEncode*` functions return a ByteBuffer whose first four bytes are
// the RFC 5531 §11 record-mark header (last-fragment + body length). The
// header is written in-place at the end of encoding via the placeholder
// pattern, so the returned buffer is ready to be sent on the wire without an
// extra wrap step.

/// Build a successful (MSG_ACCEPTED, SUCCESS) reply with `body` as the
/// procedure-specific results. The verifier is AUTH_NONE, which is what
/// AUTH_SYS expects for replies (RFC 5531 §8.2).
func rpcEncodeAcceptedReply(xid: UInt32,
                            verifier: RPCOpaqueAuth = .none,
                            results: ByteBuffer) -> ByteBuffer {
    var enc = XDREncoder()
    enc.buffer.reserveCapacity(results.readableBytes + 64)
    let frameAt = enc.placeholderUInt32()
    enc.writeUInt32(xid)
    enc.writeUInt32(RPCMessageType.reply.rawValue)
    enc.writeUInt32(RPCReplyStatus.msgAccepted.rawValue)
    encodeOpaqueAuth(verifier, into: &enc)
    enc.writeUInt32(RPCAcceptStatus.success.rawValue)
    var body = results
    enc.buffer.writeBuffer(&body)
    finishRecordMark(at: frameAt, in: &enc)
    return enc.buffer
}

/// Build a non-success accepted reply (e.g. PROG_UNAVAIL).
func rpcEncodeAcceptError(xid: UInt32,
                          status: RPCAcceptStatus,
                          progMismatchLow: UInt32 = 0,
                          progMismatchHigh: UInt32 = 0,
                          verifier: RPCOpaqueAuth = .none) -> ByteBuffer {
    var enc = XDREncoder()
    let frameAt = enc.placeholderUInt32()
    enc.writeUInt32(xid)
    enc.writeUInt32(RPCMessageType.reply.rawValue)
    enc.writeUInt32(RPCReplyStatus.msgAccepted.rawValue)
    encodeOpaqueAuth(verifier, into: &enc)
    enc.writeUInt32(status.rawValue)
    if status == .progMismatch {
        enc.writeUInt32(progMismatchLow)
        enc.writeUInt32(progMismatchHigh)
    }
    finishRecordMark(at: frameAt, in: &enc)
    return enc.buffer
}

/// Build a denied reply with AUTH_ERROR + the specified `auth_stat`.
func rpcEncodeAuthError(xid: UInt32, status: RPCAuthStatus) -> ByteBuffer {
    var enc = XDREncoder()
    let frameAt = enc.placeholderUInt32()
    enc.writeUInt32(xid)
    enc.writeUInt32(RPCMessageType.reply.rawValue)
    enc.writeUInt32(RPCReplyStatus.msgDenied.rawValue)
    enc.writeUInt32(RPCRejectStatus.authError.rawValue)
    enc.writeUInt32(status.rawValue)
    finishRecordMark(at: frameAt, in: &enc)
    return enc.buffer
}

/// Build a denied reply with RPC_MISMATCH (low/high RPC versions supported).
func rpcEncodeRpcMismatch(xid: UInt32, low: UInt32 = 2, high: UInt32 = 2) -> ByteBuffer {
    var enc = XDREncoder()
    let frameAt = enc.placeholderUInt32()
    enc.writeUInt32(xid)
    enc.writeUInt32(RPCMessageType.reply.rawValue)
    enc.writeUInt32(RPCReplyStatus.msgDenied.rawValue)
    enc.writeUInt32(RPCRejectStatus.rpcMismatch.rawValue)
    enc.writeUInt32(low)
    enc.writeUInt32(high)
    finishRecordMark(at: frameAt, in: &enc)
    return enc.buffer
}

/// Patch the four-byte record-mark placeholder at `offset` with the
/// last-fragment flag plus the body length that follows it.
private func finishRecordMark(at offset: Int, in enc: inout XDREncoder) {
    let bodyLength = enc.buffer.readableBytes - offset - 4
    let header = RPCRecordMarking.lastFragmentFlag | UInt32(bodyLength)
    enc.setUInt32(at: offset, header)
}

private func encodeOpaqueAuth(_ auth: RPCOpaqueAuth, into enc: inout XDREncoder) {
    enc.writeUInt32(auth.flavor)
    enc.writeVariableOpaque(auth.body)
}

/// Encode an AUTH_SYS credential's body (the bytes that go inside an
/// `RPCOpaqueAuth.body` when flavor == AUTH_SYS). Mostly useful for tests.
func encodeAuthSysBody(_ cred: AuthSysCredential) -> Data {
    var enc = XDREncoder()
    enc.writeUInt32(cred.stamp)
    enc.writeString(cred.machineName)
    enc.writeUInt32(cred.uid)
    enc.writeUInt32(cred.gid)
    enc.writeUInt32(UInt32(cred.gids.count))
    for g in cred.gids { enc.writeUInt32(g) }
    return Data(enc.buffer.readableBytesView)
}

/// Encode a complete RPC call (mostly for tests / callback channel later).
func encodeRpcCall(xid: UInt32,
                   program: UInt32,
                   version: UInt32,
                   procedure: UInt32,
                   credential: RPCOpaqueAuth,
                   verifier: RPCOpaqueAuth = .none,
                   args: ByteBuffer = ByteBuffer()) -> ByteBuffer {
    var enc = XDREncoder()
    enc.writeUInt32(xid)
    enc.writeUInt32(RPCMessageType.call.rawValue)
    enc.writeUInt32(RPC.version)
    enc.writeUInt32(program)
    enc.writeUInt32(version)
    enc.writeUInt32(procedure)
    encodeOpaqueAuth(credential, into: &enc)
    encodeOpaqueAuth(verifier, into: &enc)
    var argsCopy = args
    enc.buffer.writeBuffer(&argsCopy)
    return enc.buffer
}
