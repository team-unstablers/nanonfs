import Foundation

// ONC RPC v2 (RFC 5531) and NFSv4 program constants.

enum RPC {
    /// rpc_msg.rpcvers — RFC 5531 §9 mandates the value 2.
    static let version: UInt32 = 2
}

enum RPCMessageType: UInt32 {
    case call  = 0
    case reply = 1
}

enum RPCReplyStatus: UInt32 {
    case msgAccepted = 0
    case msgDenied   = 1
}

/// RFC 5531 §9 — accept_stat.
enum RPCAcceptStatus: UInt32 {
    case success      = 0
    case progUnavail  = 1
    case progMismatch = 2
    case procUnavail  = 3
    case garbageArgs  = 4
    case systemErr    = 5
}

/// RFC 5531 §9 — reject_stat.
enum RPCRejectStatus: UInt32 {
    case rpcMismatch = 0
    case authError   = 1
}

/// RFC 5531 §9 — auth_stat. Subset we actually use is documented inline.
enum RPCAuthStatus: UInt32 {
    case ok            = 0
    case badcred       = 1
    case rejectedcred  = 2
    case badverf       = 3
    case rejectedverf  = 4
    case tooweak       = 5
    case invalidresp   = 6
    case failed        = 7
    // RPCSEC_GSS-specific values 13-17 deliberately omitted; we reject GSS
    // before reaching them.
}

/// Authentication flavors (RFC 5531 §8.2).
enum RPCAuthFlavor: UInt32 {
    case none      = 0  // AUTH_NONE
    case sys       = 1  // AUTH_SYS / AUTH_UNIX
    case short     = 2  // AUTH_SHORT (legacy, unused here)
    case rpcsecGSS = 6  // RPCSEC_GSS
}

/// NFSv4 program identification (RFC 7530 §3.1 + §14; program number 100003 is
/// IANA-registered, the version-4 protocol is defined in §14-§16).
enum NFSProgram {
    static let number:  UInt32 = 100_003
    static let version: UInt32 = 4
}

/// NFSv4 procedures (RFC 7530 §15).
enum NFSProcedure: UInt32 {
    case null     = 0   // NFSPROC4_NULL
    case compound = 1   // NFSPROC4_COMPOUND
}

/// NFSv4 program callback identification (RFC 7530 §14 + §16.33 — the callback
/// program number is per-client and is announced via SETCLIENTID).
enum NFSCallbackProgram {
    static let version: UInt32 = 1
    // Program number is per-client (chosen via SETCLIENTID).
}
