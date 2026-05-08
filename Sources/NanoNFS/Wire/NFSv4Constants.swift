import Foundation

// RFC 7530 §14.4 / §16 — operation opcodes (`nfs_opnum4`).
enum NFSOp: UInt32 {
    case access            = 3
    case close             = 4
    case commit            = 5
    case create            = 6
    case delegpurge        = 7
    case delegreturn       = 8
    case getattr           = 9
    case getfh             = 10
    case link              = 11
    case lock              = 12
    case lockt             = 13
    case locku             = 14
    case lookup            = 15
    case lookupp           = 16
    case nverify           = 17
    case open              = 18
    case openattr          = 19
    case openConfirm       = 20
    case openDowngrade     = 21
    case putfh             = 22
    case putpubfh          = 23
    case putrootfh         = 24
    case read              = 25
    case readdir           = 26
    case readlink          = 27
    case remove            = 28
    case rename            = 29
    case renew             = 30
    case restorefh         = 31
    case savefh            = 32
    case secinfo           = 33
    case setattr           = 34
    case setclientid       = 35
    case setclientidConfirm = 36
    case verify            = 37
    case write             = 38
    case releaseLockowner  = 39
    case illegal           = 10044
}

// RFC 7530 §13 — `nfsstat4`. Only the values nanonfs ever produces are listed.
enum NFSStatus: UInt32 {
    case ok                = 0
    case perm              = 1
    case noent             = 2
    case io                = 5
    case nxio              = 6
    case access            = 13
    case exist             = 17
    case xdev              = 18
    case notdir            = 20
    case isdir             = 21
    case inval             = 22
    case fbig              = 27
    case nospc             = 28
    case rofs              = 30
    case mlink             = 31
    case nametoolong       = 63
    case notempty          = 66
    case dquot             = 69
    case stale             = 70
    case badhandle         = 10001
    case badCookie         = 10003
    case notsupp           = 10004
    case toosmall          = 10005
    case serverfault       = 10006
    case badtype           = 10007
    case delay             = 10008
    case denied            = 10010
    case grace             = 10013
    case fhexpired         = 10014
    case shareDenied       = 10015
    case wrongsec          = 10016
    case clidInUse         = 10017
    case resource          = 10018
    case moved             = 10019
    case nofilehandle      = 10020
    case minorVersMismatch = 10021
    case staleClientid     = 10022
    case staleStateid      = 10023
    case oldStateid        = 10024
    case badStateid        = 10025
    case badSeqid          = 10026
    case notSame           = 10027
    case lockRange         = 10028
    case symlink           = 10029
    case restorefh         = 10030
    case leaseMoved        = 10031
    case attrnotsupp       = 10032
    case noGrace           = 10033
    case reclaimBad        = 10034
    case reclaimConflict   = 10035
    case badxdr            = 10036
    case lockNotGranted    = 10037
    case lockOldStateid    = 10038
    case openMode          = 10039
    case badowner          = 10040
    case badchar           = 10041
    case badname           = 10042
    case badRange          = 10043
    case opIllegal         = 10044
    case deadlock          = 10045
    case fileOpen          = 10046
    case admRevoked        = 10047
    case cbPathDown        = 10048
}

extension NFSError {
    /// Mapping defined by RFC 7530 §13.1.
    var asStatus: NFSStatus {
        switch self {
        case .permission:     return .perm
        case .noEntry:        return .noent
        case .io:             return .io
        case .noSuchDevice:   return .nxio
        case .accessDenied:   return .access
        case .exists:         return .exist
        case .crossDevice:    return .xdev
        case .notDirectory:   return .notdir
        case .isDirectory:    return .isdir
        case .invalid:        return .inval
        case .fileTooBig:     return .fbig
        case .noSpace:        return .nospc
        case .readOnly:       return .rofs
        case .tooManyLinks:   return .mlink
        case .nameTooLong:    return .nametoolong
        case .notEmpty:       return .notempty
        case .dirQuota:       return .dquot
        case .stale:          return .stale
        case .badHandle:      return .badhandle
        case .notSupported:   return .notsupp
        case .fileBusy:       return .fileOpen
        case .shareDenied:    return .shareDenied
        case .lockDenied:     return .denied
        case .lockRangeOverlap: return .lockRange
        case .staleStateid:   return .staleStateid
        case .oldStateid:     return .oldStateid
        case .badStateid:     return .badStateid
        case .wrongType:      return .badtype
        case .serverFault:    return .serverfault
        }
    }
}
