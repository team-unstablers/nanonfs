import Foundation
import NIOCore

// RFC 7530 §5 — File Attributes (FATTR4).
//
// Attributes are addressed by integer numbers grouped into a `bitmap4`:
//
//     typedef uint32_t bitmap4<>;
//
// Each 32-bit word covers attributes [w*32, w*32+31]; bit i (LSB-first)
// in word w means attribute number (w*32 + i) is present. The values for
// the selected attributes are then concatenated, in increasing attribute
// number order, and emitted as a single XDR variable-opaque (`attrlist4`):
//
//     struct fattr4 {
//         bitmap4   attrmask;
//         attrlist4 attr_vals;
//     };
//
// nanonfs treats the wire side of FATTR4 as pure data shuffling here —
// higher layers (`opGetattr`) translate `NFSStat` into the per-attribute
// values.

/// Numeric identifiers (RFC 7530 §5.6/5.7). Mandatory ones are listed first.
enum FATTR4: UInt32, CaseIterable {
    case supportedAttrs   = 0
    case type             = 1
    case fhExpireType     = 2
    case change           = 3
    case size             = 4
    case linkSupport      = 5
    case symlinkSupport   = 6
    case namedAttr        = 7
    case fsid             = 8
    case uniqueHandles    = 9
    case leaseTime        = 10
    case rdattrError      = 11
    case acl              = 12
    case aclSupport       = 13
    case archive          = 14
    case canSetTime       = 15
    case caseInsensitive  = 16
    case casePreserving   = 17
    case chownRestricted  = 18
    case fileHandle       = 19
    case fileID           = 20
    case filesAvail       = 21
    case filesFree        = 22
    case filesTotal       = 23
    case fsLocations      = 24
    case hidden           = 25
    case homogeneous      = 26
    case maxFileSize      = 27
    case maxLink          = 28
    case maxName          = 29
    case maxRead          = 30
    case maxWrite         = 31
    case mimetype         = 32
    case mode             = 33
    case noTrunc          = 34
    case numLinks         = 35
    case owner            = 36
    case ownerGroup       = 37
    case quotaAvailHard   = 38
    case quotaAvailSoft   = 39
    case quotaUsed        = 40
    case rawDev           = 41
    case spaceAvail       = 42
    case spaceFree        = 43
    case spaceTotal       = 44
    case spaceUsed        = 45
    case system           = 46
    case timeAccess       = 47
    case timeAccessSet    = 48
    case timeBackup       = 49
    case timeCreate       = 50
    case timeDelta        = 51
    case timeMetadata     = 52
    case timeModify       = 53
    case timeModifySet    = 54
    case mountedOnFileID  = 55
}

// MARK: - bitmap4

/// Bitmap of FATTR4 attribute numbers, used as both request masks and
/// response presence indicators.
struct AttrBitmap: Sendable, Equatable {
    /// Each entry holds 32 bits; the value at index `w` covers attrs
    /// [w*32, w*32+31] with bit `i` (1 << i) standing for attr (w*32 + i).
    var words: [UInt32]

    init(words: [UInt32] = []) {
        self.words = words
    }

    init<S: Sequence>(_ attrs: S) where S.Element == FATTR4 {
        var w: [UInt32] = []
        for a in attrs {
            let idx = Int(a.rawValue / 32)
            let bit = UInt32(1) << UInt32(a.rawValue % 32)
            while w.count <= idx { w.append(0) }
            w[idx] |= bit
        }
        // Trim trailing zero words.
        while let last = w.last, last == 0 { w.removeLast() }
        self.words = w
    }

    func contains(_ attr: FATTR4) -> Bool {
        let idx = Int(attr.rawValue / 32)
        guard idx < words.count else { return false }
        let bit = UInt32(1) << UInt32(attr.rawValue % 32)
        return (words[idx] & bit) != 0
    }

    /// Iterate attributes in increasing numeric order — matches the order
    /// in which their values must appear on the wire.
    func iterateInOrder(_ body: (FATTR4) -> Void) {
        for (w, word) in words.enumerated() {
            guard word != 0 else { continue }
            for bit in 0..<32 where (word & (UInt32(1) << UInt32(bit))) != 0 {
                let raw = UInt32(w * 32 + bit)
                if let attr = FATTR4(rawValue: raw) {
                    body(attr)
                }
            }
        }
    }

    func encode(into enc: inout XDREncoder) {
        enc.writeUInt32(UInt32(words.count))
        for w in words { enc.writeUInt32(w) }
    }

    static func decode(from dec: inout XDRDecoder) throws -> AttrBitmap {
        let count = try dec.readUInt32()
        guard count <= 64 else {
            // 64*32 = 2048 attrs — well over anything NFSv4.0 defines.
            throw XDRError.lengthExceedsLimit(declared: count, limit: 64)
        }
        var words: [UInt32] = []
        words.reserveCapacity(Int(count))
        for _ in 0..<count {
            words.append(try dec.readUInt32())
        }
        return AttrBitmap(words: words)
    }
}

// MARK: - Server-wide constants

enum FATTRConfig {
    /// nanonfs's lease time (RFC 7530 §5.8.1.11 — LEASE_TIME, in seconds). The
    /// client renews via RENEW within this window or its state is reaped.
    static let leaseSeconds: UInt32 = 60

    /// Static (file-handle, fsid) treatments — values surfaced via FATTR4.
    static let fhExpireType: UInt32 = 0           // FH4_PERSISTENT
    static let fsidMajor:    UInt64 = 0x6E_6E_66_73_00_00_00_01 // "nnfs\0\0\0\1"
    static let fsidMinor:    UInt64 = 1
    static let acl:          UInt32 = 0           // no ACL types supported
    static let maxFileSize:  UInt64 = .max
    static let maxLink:      UInt32 = 0xFFFF
    static let maxName:      UInt32 = 255
    static let maxRead:      UInt64 = 1024 * 1024 // 1 MiB
    static let maxWrite:     UInt64 = 1024 * 1024 // 1 MiB
    static let timeDelta = NFSTime(seconds: 0, nseconds: 1)

    /// Synthetic free / total space reported via FATTR4. We do not track
    /// actual host usage — the value just has to be large enough that
    /// macOS Finder does not pre-emptively refuse copies with "not enough
    /// space" (it samples space_avail before writing). 1 TiB is comfortable.
    static let spaceTotalBytes: UInt64 = 1 << 40
    static let spaceFreeBytes:  UInt64 = 1 << 40

    /// All attributes nanonfs is willing to serve. Any GETATTR mask outside
    /// this set is silently dropped from the response (RFC 7530 §16.7 —
    /// servers MAY omit unsupported attributes).
    static let supported: AttrBitmap = AttrBitmap([
        .supportedAttrs, .type, .fhExpireType, .change, .size,
        .linkSupport, .symlinkSupport, .namedAttr, .fsid,
        .uniqueHandles, .leaseTime, .rdattrError, .aclSupport,
        .canSetTime, .caseInsensitive, .casePreserving, .chownRestricted,
        .fileHandle, .fileID, .homogeneous, .maxFileSize, .maxLink,
        .maxName, .maxRead, .maxWrite, .mode, .noTrunc, .numLinks,
        .owner, .ownerGroup, .rawDev,
        .spaceAvail, .spaceFree, .spaceTotal, .spaceUsed,
        .filesAvail, .filesFree, .filesTotal,
        .timeAccess, .timeDelta, .timeMetadata, .timeModify,
        .mountedOnFileID,
    ])

    /// Synthetic inode-count answers for `files_*` attrs. Same rationale as
    /// space_*: keep clients from pre-emptively refusing operations.
    static let filesTotal: UInt64 = 1 << 32
    static let filesFree:  UInt64 = 1 << 32
}

// MARK: - Encoding NFSStat into a FATTR4 attrlist4

/// Encode the requested-and-supported subset of attributes for `stat` into
/// `attr_vals`, returning the actually-emitted bitmap so the caller can
/// produce the on-wire `fattr4 { attrmask, attr_vals }`.
///
/// `fileHandle` is required if the request mask asks for FATTR4_FILEHANDLE.
func encodeFattr4(stat: NFSStat,
                  fileHandle: NFSFileHandle,
                  request: AttrBitmap) -> (mask: AttrBitmap, attrVals: ByteBuffer) {
    var values = XDREncoder()
    var emitted: [FATTR4] = []

    request.iterateInOrder { attr in
        guard FATTRConfig.supported.contains(attr) else { return }
        switch attr {
        case .supportedAttrs:
            FATTRConfig.supported.encode(into: &values)
        case .type:
            values.writeUInt32(stat.type.rawValue)
        case .fhExpireType:
            values.writeUInt32(FATTRConfig.fhExpireType)
        case .change:
            // RFC 7530 §5.8.1.4 (change attr) / §2.1 changeid4: monotonically-increasing.
            // We synthesize from mtime since we don't track per-file change
            // counters yet — sufficient for clients that compare equality.
            let chg = UInt64(bitPattern: stat.mtime.seconds) &* 1_000_000_000
                + UInt64(stat.mtime.nseconds)
            values.writeUInt64(chg)
        case .size:
            values.writeUInt64(stat.size)
        case .linkSupport:
            values.writeBool(true)
        case .symlinkSupport:
            values.writeBool(true)
        case .namedAttr:
            values.writeBool(false)
        case .fsid:
            values.writeUInt64(FATTRConfig.fsidMajor)
            values.writeUInt64(FATTRConfig.fsidMinor)
        case .uniqueHandles:
            values.writeBool(true)
        case .leaseTime:
            values.writeUInt32(FATTRConfig.leaseSeconds)
        case .rdattrError:
            values.writeUInt32(NFSStatus.ok.rawValue)
        case .aclSupport:
            values.writeUInt32(FATTRConfig.acl)
        case .canSetTime:
            values.writeBool(true)
        case .caseInsensitive:
            values.writeBool(false)
        case .casePreserving:
            values.writeBool(true)
        case .chownRestricted:
            values.writeBool(true)
        case .fileHandle:
            values.writeVariableOpaque(fileHandle.bytes)
        case .fileID:
            values.writeUInt64(stat.fileid)
        case .homogeneous:
            values.writeBool(true)
        case .maxFileSize:
            values.writeUInt64(FATTRConfig.maxFileSize)
        case .maxLink:
            values.writeUInt32(FATTRConfig.maxLink)
        case .maxName:
            values.writeUInt32(FATTRConfig.maxName)
        case .maxRead:
            values.writeUInt64(FATTRConfig.maxRead)
        case .maxWrite:
            values.writeUInt64(FATTRConfig.maxWrite)
        case .mode:
            values.writeUInt32(stat.mode & 0xFFF)
        case .noTrunc:
            values.writeBool(true)
        case .numLinks:
            values.writeUInt32(stat.nlink)
        case .owner:
            // RFC 7530 §5.9: utf8str_mixed, 보통 "user@domain". 다만 도메인이
            // client 의 default_nfs4domain 과 mismatch 면 macOS 가 owner 를
            // nobody 로 떨어뜨려 git 등의 owner-check 가 깨진다. 도메인 없는
            // 순수 숫자 문자열을 보내면 macOS NFS client 가 곧장 numeric uid
            // 로 해석하므로 (idmapper bypass), 이쪽이 안전하다.
            values.writeString("\(stat.uid)")
        case .ownerGroup:
            values.writeString("\(stat.gid)")
        case .rawDev:
            let dev = stat.rdev ?? .init(major: 0, minor: 0)
            values.writeUInt32(dev.major)
            values.writeUInt32(dev.minor)
        case .spaceUsed:
            values.writeUInt64(stat.used)
        case .spaceAvail:
            values.writeUInt64(FATTRConfig.spaceFreeBytes)
        case .spaceFree:
            values.writeUInt64(FATTRConfig.spaceFreeBytes)
        case .spaceTotal:
            values.writeUInt64(FATTRConfig.spaceTotalBytes)
        case .filesAvail:
            values.writeUInt64(FATTRConfig.filesFree)
        case .filesFree:
            values.writeUInt64(FATTRConfig.filesFree)
        case .filesTotal:
            values.writeUInt64(FATTRConfig.filesTotal)
        case .timeAccess:
            encodeNFSTime(stat.atime, into: &values)
        case .timeDelta:
            encodeNFSTime(FATTRConfig.timeDelta, into: &values)
        case .timeMetadata:
            encodeNFSTime(stat.ctime, into: &values)
        case .timeModify:
            encodeNFSTime(stat.mtime, into: &values)
        case .mountedOnFileID:
            values.writeUInt64(stat.fileid)
        default:
            return
        }
        emitted.append(attr)
    }

    return (AttrBitmap(emitted), values.buffer)
}

/// Encode an `nfstime4` (RFC 7530 §2.2.1): int64 seconds + uint32 nseconds.
func encodeNFSTime(_ t: NFSTime, into enc: inout XDREncoder) {
    enc.writeInt64(t.seconds)
    enc.writeUInt32(t.nseconds)
}

/// Decode an `nfstime4` from the wire.
func decodeNFSTime(from dec: inout XDRDecoder) throws -> NFSTime {
    let s = try dec.readInt64()
    let ns = try dec.readUInt32()
    return NFSTime(seconds: s, nseconds: ns)
}

// MARK: - GETATTR result framing

/// Produce the wire bytes for a `GETATTR4resok` body (an `fattr4`):
/// `bitmap4 attrmask` followed by `opaque attr_vals<>`.
func encodeGetattrResult(stat: NFSStat,
                         fileHandle: NFSFileHandle,
                         request: AttrBitmap) -> ByteBuffer {
    let (mask, attrVals) = encodeFattr4(stat: stat, fileHandle: fileHandle, request: request)
    var out = XDREncoder()
    mask.encode(into: &out)
    out.writeVariableOpaque(attrVals)
    return out.buffer
}
