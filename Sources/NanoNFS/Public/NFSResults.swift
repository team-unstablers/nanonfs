import Foundation

// MARK: - I/O results

public struct NFSReadResult: Sendable {
    public var data: Data
    public var eof: Bool

    public init(data: Data, eof: Bool) {
        self.data = data
        self.eof = eof
    }
}

public struct NFSWriteResult: Sendable {
    public var count: Int
    public var committed: NFSWriteStability
    public var writeVerifier: UInt64

    public init(count: Int, committed: NFSWriteStability, writeVerifier: UInt64) {
        self.count = count
        self.committed = committed
        self.writeVerifier = writeVerifier
    }
}

// MARK: - OPEN result (RFC 7530 §16.16)

public struct NFSOpenFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// OPEN4_RESULT_CONFIRM
    public static let confirmRequired = NFSOpenFlags(rawValue: 0x0002)
    /// OPEN4_RESULT_LOCKTYPE_POSIX
    public static let lockTypePosix   = NFSOpenFlags(rawValue: 0x0004)
}

public enum NFSDelegationGrant: Sendable {
    case none
    case read(stateid: NFSStateID, recall: Bool)
    case write(stateid: NFSStateID, recall: Bool, spaceLimit: UInt64)
}

public struct NFSOpenResult: Sendable {
    public var stateid: NFSStateID
    public var rflags: NFSOpenFlags
    public var delegation: NFSDelegationGrant

    public init(stateid: NFSStateID, rflags: NFSOpenFlags, delegation: NFSDelegationGrant) {
        self.stateid = stateid
        self.rflags = rflags
        self.delegation = delegation
    }
}

// MARK: - Directory listing (RFC 7530 §16.24 READDIR)

public struct NFSDirEntry: Sendable {
    public var fileid: UInt64
    public var name: String
    /// Pre-computed attrs to satisfy the GETATTR-in-READDIR request mask.
    /// If `nil`, the dispatcher calls `getattr(handle:)` per entry.
    public var attrs: NFSStat?

    public init(fileid: UInt64, name: String, attrs: NFSStat? = nil) {
        self.fileid = fileid
        self.name = name
        self.attrs = attrs
    }
}

public struct NFSDirList: Sendable {
    public var entries: [NFSDirEntry]
    /// `nil` means "this is the last batch — set EOF and stop calling".
    public var nextCookie: UInt64?
    public var verifier: UInt64
    public var eof: Bool

    public init(entries: [NFSDirEntry], nextCookie: UInt64?, verifier: UInt64, eof: Bool) {
        self.entries = entries
        self.nextCookie = nextCookie
        self.verifier = verifier
        self.eof = eof
    }
}

// MARK: - LOCKT result (RFC 7530 §16.11 LOCKT)

public struct NFSLockTestResult: Sendable {
    public enum Outcome: Sendable {
        case granted
        case denied(conflict: NFSLockRange, type: NFSLockType, owner: NFSLockOwner)
    }
    public var outcome: Outcome

    public init(outcome: Outcome) {
        self.outcome = outcome
    }
}

// MARK: - CREATE / OPEN modes (RFC 7530 §16.16)

public enum NFSCreateMode: Sendable {
    case open                                    // OPEN4_NOCREATE
    case create(NFSAttributesPatch)              // UNCHECKED4
    case createExclusive(verifier: UInt64)       // EXCLUSIVE4
}
