import Foundation
import Logging
import NIOCore

// One RPC connection's worth of state and per-request handling. The session
// is created per accepted child channel and lives until the channel closes.

/// Decode an RPC call, validate its RPC-layer prerequisites (program, version,
/// auth flavor), and run the resulting NFSv4 procedure (NULL or COMPOUND).
/// Returns the bytes for the RPC reply body (still without record-mark
/// framing).
func handleSingleRpcMessage(
    _ message: ByteBuffer,
    dispatcher: CompoundDispatcher,
    logger: Logger
) async -> ByteBuffer {
    let header: RPCCallHeader
    var argsDec: XDRDecoder
    do {
        let parsed = try RPCCallHeader.decode(from: message)
        header = parsed.header
        argsDec = parsed.argsDecoder
    } catch RPCDecodeError.rpcVersionMismatch {
        // We can't even read xid reliably here, but the spec wants us to
        // signal RPC_MISMATCH. Try to extract xid first.
        var probe = XDRDecoder(message)
        let xid = (try? probe.readUInt32()) ?? 0
        return rpcEncodeRpcMismatch(xid: xid)
    } catch {
        // Anything else: the message is so malformed we can't form a useful
        // reply. Drop the connection by throwing in the caller, but here we
        // synthesize a denied reply so the caller can decide.
        logger.warning("RPC decode failed: \(error)")
        return rpcEncodeAuthError(xid: 0, status: .failed)
    }

    // RFC 5531 §9 — program identification.
    guard header.program == NFSProgram.number else {
        logger.info("RPC: prog \(header.program) unavailable")
        return rpcEncodeAcceptError(xid: header.xid, status: .progUnavail)
    }
    guard header.version == NFSProgram.version else {
        logger.info("RPC: prog vers \(header.version) mismatch (need \(NFSProgram.version))")
        return rpcEncodeAcceptError(xid: header.xid,
                                    status: .progMismatch,
                                    progMismatchLow: NFSProgram.version,
                                    progMismatchHigh: NFSProgram.version)
    }

    // RFC 7530 §3.2 + nanonfs scope: AUTH_SYS only. AUTH_NONE is allowed
    // for the NULL procedure (servers SHOULD accept it for ping); GSS we
    // reject outright.
    let flavor = header.credential.flavor
    let isNull = (header.procedure == NFSProcedure.null.rawValue)
    if flavor == RPCAuthFlavor.rpcsecGSS.rawValue {
        return rpcEncodeAuthError(xid: header.xid, status: .tooweak)
    }
    if flavor != RPCAuthFlavor.sys.rawValue && !(isNull && flavor == RPCAuthFlavor.none.rawValue) {
        return rpcEncodeAuthError(xid: header.xid, status: .tooweak)
    }
    if flavor == RPCAuthFlavor.sys.rawValue {
        // Best-effort parse so we surface obvious malformation early.
        if (try? AuthSysCredential.decode(from: header.credential.body)) == nil {
            return rpcEncodeAuthError(xid: header.xid, status: .badcred)
        }
    }

    switch NFSProcedure(rawValue: header.procedure) {
    case .null:
        // RFC 7530 §15.1 — NULL has no args and no results.
        return rpcEncodeAcceptedReply(xid: header.xid, results: ByteBuffer())

    case .compound:
        // The remainder of the message (after the verifier) is COMPOUND4args.
        let compoundArgs = argsDec.buffer
        let compoundRes  = await dispatcher.dispatch(args: compoundArgs)
        return rpcEncodeAcceptedReply(xid: header.xid, results: compoundRes)

    case .none:
        return rpcEncodeAcceptError(xid: header.xid, status: .procUnavail)
    }
}
