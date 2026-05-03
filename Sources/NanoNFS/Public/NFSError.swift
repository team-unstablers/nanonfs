import Foundation

/// User-facing error type. The Wire layer maps each case to the corresponding
/// NFS4ERR_* status (RFC 7530 §13.1). Anything else thrown from a `NFSServer`
/// method becomes `NFS4ERR_SERVERFAULT` and is logged at `warning`.
public enum NFSError: Error, Sendable {
    case permission           // NFS4ERR_PERM         = 1
    case noEntry              // NFS4ERR_NOENT        = 2
    case io                   // NFS4ERR_IO           = 5
    case noSuchDevice         // NFS4ERR_NXIO         = 6
    case accessDenied         // NFS4ERR_ACCESS       = 13
    case exists               // NFS4ERR_EXIST        = 17
    case crossDevice          // NFS4ERR_XDEV         = 18
    case notDirectory         // NFS4ERR_NOTDIR       = 20
    case isDirectory          // NFS4ERR_ISDIR        = 21
    case invalid              // NFS4ERR_INVAL        = 22
    case fileTooBig           // NFS4ERR_FBIG         = 27
    case noSpace              // NFS4ERR_NOSPC        = 28
    case readOnly             // NFS4ERR_ROFS         = 30
    case tooManyLinks         // NFS4ERR_MLINK        = 31
    case nameTooLong          // NFS4ERR_NAMETOOLONG  = 63
    case notEmpty             // NFS4ERR_NOTEMPTY     = 66
    case dirQuota             // NFS4ERR_DQUOT        = 69
    case stale                // NFS4ERR_STALE        = 70
    case badHandle            // NFS4ERR_BADHANDLE    = 10001
    case notSupported         // NFS4ERR_NOTSUPP      = 10004
    case fileBusy             // NFS4ERR_FILE_OPEN    = 10046
    case shareDenied          // NFS4ERR_SHARE_DENIED = 10015
    case lockDenied(conflict: NFSLockRange,
                    type: NFSLockType,
                    owner: NFSLockOwner)        // NFS4ERR_DENIED       = 10010
    case lockRangeOverlap                       // NFS4ERR_LOCK_RANGE   = 10028
    case staleStateid                           // NFS4ERR_STALE_STATEID = 10023
    case oldStateid                             // NFS4ERR_OLD_STATEID  = 10024
    case badStateid                             // NFS4ERR_BAD_STATEID  = 10025
    case wrongType                              // NFS4ERR_WRONG_TYPE   = 10083 (RFC 7530 §13.1.1)
    case serverFault                            // NFS4ERR_SERVERFAULT  = 10006
}
