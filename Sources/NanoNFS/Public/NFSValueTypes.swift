import Foundation

// MARK: - File handle (RFC 7530 §2.1 nfs_fh4 / §16.x)

/// NFSv4 variable-length opaque file handle.
/// The server is the sole authority on its contents — clients must treat it as opaque.
public struct NFSFileHandle: Hashable, Sendable {
    /// ≤ NFS4_FHSIZE (128) bytes per RFC 7530 §2.1 (Table 1).
    public var bytes: Data

    public init(_ bytes: Data) {
        self.bytes = bytes
    }
}

// MARK: - State identifier (RFC 7530 §2.2.16 / §9.1.4)

/// NFSv4 stateid: (seqid, other[12]).
public struct NFSStateID: Hashable, Sendable {
    public var seqid: UInt32
    /// Exactly 12 bytes per RFC 7530 §2.2.16 / "NFS4_OTHER_SIZE".
    public var other: Data

    public init(seqid: UInt32, other: Data) {
        self.seqid = seqid
        self.other = other
    }

    /// All-zero stateid (RFC 7530 §9.1.4.3 — "anonymous stateid").
    public static let anonymous = NFSStateID(seqid: 0, other: Data(repeating: 0, count: 12))

    /// All-ones stateid (RFC 7530 §9.1.4.3 — "READ bypass stateid").
    public static let bypass = NFSStateID(seqid: .max, other: Data(repeating: 0xff, count: 12))
}

// MARK: - Time (RFC 7530 §2.2.1 nfstime4)

public struct NFSTime: Hashable, Sendable {
    public var seconds: Int64
    public var nseconds: UInt32

    public init(seconds: Int64, nseconds: UInt32) {
        self.seconds = seconds
        self.nseconds = nseconds
    }

    public static func now() -> NFSTime {
        let t = Date().timeIntervalSince1970
        let secs = Int64(t.rounded(.down))
        let nsecs = UInt32(((t - Double(secs)) * 1_000_000_000).rounded(.down))
        return NFSTime(seconds: secs, nseconds: nsecs)
    }
}

// MARK: - Object type (RFC 7530 §2.1 nfs_ftype4)

public enum NFSObjectType: UInt32, Sendable {
    case regularFile      = 1   // NF4REG
    case directory        = 2   // NF4DIR
    case blockDevice      = 3   // NF4BLK
    case characterDevice  = 4   // NF4CHR
    case symbolicLink     = 5   // NF4LNK
    case socket           = 6   // NF4SOCK
    case fifo             = 7   // NF4FIFO
    case attributeDirectory = 8 // NF4ATTRDIR
    case namedAttribute   = 9   // NF4NAMEDATTR
}

// MARK: - POSIX-like stat (FATTR4 mapping target)

public struct NFSStat: Hashable, Sendable {
    public var type: NFSObjectType
    public var mode: UInt32
    public var nlink: UInt32
    public var uid: UInt32
    public var gid: UInt32
    public var size: UInt64
    public var used: UInt64
    public var fileid: UInt64
    public var atime: NFSTime
    public var mtime: NFSTime
    public var ctime: NFSTime
    public var rdev: RDev?

    public struct RDev: Hashable, Sendable {
        public var major: UInt32
        public var minor: UInt32
        public init(major: UInt32, minor: UInt32) {
            self.major = major
            self.minor = minor
        }
    }

    public init(
        type: NFSObjectType,
        mode: UInt32,
        nlink: UInt32,
        uid: UInt32,
        gid: UInt32,
        size: UInt64,
        used: UInt64,
        fileid: UInt64,
        atime: NFSTime,
        mtime: NFSTime,
        ctime: NFSTime,
        rdev: RDev? = nil
    ) {
        self.type = type
        self.mode = mode
        self.nlink = nlink
        self.uid = uid
        self.gid = gid
        self.size = size
        self.used = used
        self.fileid = fileid
        self.atime = atime
        self.mtime = mtime
        self.ctime = ctime
        self.rdev = rdev
    }
}

// MARK: - SETATTR patch

/// RFC 7530 §16.32 SETATTR — only fields with `.some(_)` are modified.
public struct NFSAttributesPatch: Sendable {
    public var mode: UInt32?
    public var uid: UInt32?
    public var gid: UInt32?
    public var size: UInt64?
    public var atime: NFSTime?
    public var mtime: NFSTime?

    public init(
        mode: UInt32? = nil,
        uid: UInt32? = nil,
        gid: UInt32? = nil,
        size: UInt64? = nil,
        atime: NFSTime? = nil,
        mtime: NFSTime? = nil
    ) {
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.size = size
        self.atime = atime
        self.mtime = mtime
    }
}
