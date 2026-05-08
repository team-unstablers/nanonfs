import Foundation

// MARK: - Access (RFC 7530 §16.1 ACCESS)

public struct NFSAccess: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let read    = NFSAccess(rawValue: 0x0001) // ACCESS4_READ
    public static let lookup  = NFSAccess(rawValue: 0x0002) // ACCESS4_LOOKUP
    public static let modify  = NFSAccess(rawValue: 0x0004) // ACCESS4_MODIFY
    public static let extend  = NFSAccess(rawValue: 0x0008) // ACCESS4_EXTEND
    public static let delete  = NFSAccess(rawValue: 0x0010) // ACCESS4_DELETE
    public static let execute = NFSAccess(rawValue: 0x0020) // ACCESS4_EXECUTE
}

// MARK: - Share Access / Deny (RFC 7530 §16.16 OPEN)

public struct NFSShareAccess: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let read  = NFSShareAccess(rawValue: 0x01) // OPEN4_SHARE_ACCESS_READ
    public static let write = NFSShareAccess(rawValue: 0x02) // OPEN4_SHARE_ACCESS_WRITE
    public static let both: NFSShareAccess = [.read, .write]
}

public struct NFSShareDeny: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let none  = NFSShareDeny([])
    public static let read  = NFSShareDeny(rawValue: 0x01) // OPEN4_SHARE_DENY_READ
    public static let write = NFSShareDeny(rawValue: 0x02) // OPEN4_SHARE_DENY_WRITE
    public static let both: NFSShareDeny = [.read, .write]
}

// MARK: - Delegation hint

public enum NFSDelegationHint: Sendable, Hashable {
    case none
    case read
    case write
    case any
}

// MARK: - Open / Lock owner (RFC 7530 §2.2.13 open_owner4 / §2.2.14 lock_owner4)

public struct NFSOpenOwner: Hashable, Sendable {
    public var clientid: UInt64
    /// `opaque<NFS4_OPAQUE_LIMIT>` per RFC 7530 §2.2.13 (NFS4_OPAQUE_LIMIT = 1024 in RFC 7531).
    public var owner: Data

    public init(clientid: UInt64, owner: Data) {
        self.clientid = clientid
        self.owner = owner
    }
}

public struct NFSLockOwner: Hashable, Sendable {
    public var clientid: UInt64
    public var owner: Data

    public init(clientid: UInt64, owner: Data) {
        self.clientid = clientid
        self.owner = owner
    }
}

// MARK: - Lock (RFC 7530 §16.10 LOCK)

public enum NFSLockType: Sendable, Hashable {
    case readShared              // READ_LT
    case writeExclusive          // WRITE_LT
    case readSharedBlocking      // READW_LT
    case writeExclusiveBlocking  // WRITEW_LT
}

public struct NFSLockRange: Sendable, Hashable {
    public var offset: UInt64
    /// `0xFFFF_FFFF_FFFF_FFFF` (NFS4_UINT64_MAX) means "to EOF" per RFC 7530 §16.10.4.
    public var length: UInt64

    public init(offset: UInt64, length: UInt64) {
        self.offset = offset
        self.length = length
    }
}

// MARK: - Write stability (RFC 7530 §16.36 WRITE)

public enum NFSWriteStability: UInt32, Sendable, Hashable {
    case unstable = 0
    case dataSync = 1
    case fileSync = 2
}
