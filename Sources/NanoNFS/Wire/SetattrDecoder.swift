import Foundation
import NIOCore

// RFC 7530 §16.32 SETATTR — translates a fattr4 (bitmap + attrlist4) into
// an `NFSAttributesPatch`. Only writeable attributes are honoured; values
// for other attributes are decoded so we can complain about them
// specifically (NFS4ERR_INVAL vs NFS4ERR_ATTRNOTSUPP).

enum SetattrDecodeError: Error, Equatable {
    /// An attribute the spec declares as readonly was set (NFS4ERR_INVAL).
    case readonlyAttr(FATTR4)
    /// An attribute we accept structurally but cannot satisfy (NFS4ERR_ATTRNOTSUPP).
    case unsupportedAttr(FATTR4)
    /// `OWNER` / `OWNER_GROUP` not in the form `"<digits>@<domain>"`.
    case invalidOwnerString(String)
}

struct SetattrDecoded: Sendable {
    /// Fields the user is asked to update.
    var patch: NFSAttributesPatch
    /// Bitmap of attributes that were actually consumed. Returned to client
    /// as `SETATTR4res.attrsset` once the user's callback succeeds.
    var attrsSet: AttrBitmap
}

/// Decode the bitmap + attrlist4 of a SETATTR call. Throws if any attribute
/// is read-only or unsupported, so callers can surface the right NFS4ERR_.
func decodeSetattrPatch(from dec: inout XDRDecoder) throws -> SetattrDecoded {
    let bitmap = try AttrBitmap.decode(from: &dec)
    var attrBytes = try dec.readVariableOpaqueData()
    var values = ByteBuffer()
    values.writeBytes(attrBytes)
    var v = XDRDecoder(values)
    attrBytes.removeAll(keepingCapacity: false)

    var patch = NFSAttributesPatch()
    var emitted: [FATTR4] = []

    var thrown: Error?
    bitmap.iterateInOrder { attr in
        if thrown != nil { return }
        do {
            switch attr {
            case .mode:
                patch.mode = try v.readUInt32() & 0xFFF
            case .owner:
                let s = try v.readString(maxLength: 1024)
                // macOS clients with idmapd active send "username@domain"
                // rather than "<uid>@domain". We have no idmapper, so we
                // silently skip owner changes we cannot interpret rather
                // than failing the whole CREATE/SETATTR.
                if let uid = try? parseOwnerNumeric(s) {
                    patch.uid = uid
                } else {
                    return  // skip this attr; do NOT add to emitted
                }
            case .ownerGroup:
                let s = try v.readString(maxLength: 1024)
                if let gid = try? parseOwnerNumeric(s) {
                    patch.gid = gid
                } else {
                    return
                }
            case .size:
                patch.size = try v.readUInt64()
            case .timeAccessSet:
                patch.atime = try decodeSetTime(&v)
            case .timeModifySet:
                patch.mtime = try decodeSetTime(&v)
            case .acl, .archive, .hidden, .system, .mimetype:
                throw SetattrDecodeError.unsupportedAttr(attr)
            default:
                throw SetattrDecodeError.readonlyAttr(attr)
            }
            emitted.append(attr)
        } catch {
            thrown = error
        }
    }
    if let e = thrown { throw e }
    return SetattrDecoded(patch: patch, attrsSet: AttrBitmap(emitted))
}

/// `settime4` (RFC 7530 §2.2.3):
///   union switch (time_how4 set_it) {
///     case SET_TO_SERVER_TIME: void;
///     case SET_TO_CLIENT_TIME: nfstime4 time;
///   }
private func decodeSetTime(_ v: inout XDRDecoder) throws -> NFSTime {
    let how = try v.readUInt32()
    switch how {
    case 0: // SET_TO_SERVER_TIME
        return .now()
    case 1: // SET_TO_CLIENT_TIME
        return try decodeNFSTime(from: &v)
    default:
        throw XDRError.invalidBoolean(how)
    }
}

private func parseOwnerNumeric(_ s: String) throws -> UInt32 {
    // Accept either "1234@anything" or plain "1234".
    let head = s.split(separator: "@").first.map(String.init) ?? s
    guard let n = UInt32(head) else {
        throw SetattrDecodeError.invalidOwnerString(s)
    }
    return n
}
