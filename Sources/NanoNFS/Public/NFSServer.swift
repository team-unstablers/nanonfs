import Foundation

/// FUSE-like Swift façade over the NFSv4 wire protocol.
///
/// Every method must be implemented by the user — there are intentionally no
/// default implementations. Operations that the user does not wish to support
/// should throw `NFSError.notSupported` (or `.readOnly`, `.permission`, …) so
/// that the corresponding NFS4ERR_* status reaches the client.
///
/// Concurrency: the dispatcher does **not** serialize calls. Implementations
/// should be `actor`s (or otherwise `Sendable` and thread-safe by construction).
public protocol NFSServer: Sendable {

    // MARK: Root
    func root() async throws -> NFSFileHandle

    // MARK: Metadata
    func access(handle: NFSFileHandle, mask: NFSAccess) async throws -> NFSAccess
    func getattr(handle: NFSFileHandle) async throws -> NFSStat
    func setattr(handle: NFSFileHandle,
                 stateid: NFSStateID?,
                 patch: NFSAttributesPatch) async throws -> NFSStat

    // MARK: Directory
    func lookup(parent: NFSFileHandle, name: String) async throws -> NFSFileHandle
    func lookupParent(of handle: NFSFileHandle) async throws -> NFSFileHandle
    func readdir(handle: NFSFileHandle,
                 cookie: UInt64,
                 cookieVerifier: UInt64,
                 maxEntries: Int) async throws -> NFSDirList

    // MARK: Create / remove / move
    func create(parent: NFSFileHandle, name: String,
                type: NFSObjectType,
                attrs: NFSAttributesPatch) async throws -> NFSFileHandle
    func remove(parent: NFSFileHandle, name: String) async throws
    func rename(srcParent: NFSFileHandle, srcName: String,
                dstParent: NFSFileHandle, dstName: String) async throws
    func link(target: NFSFileHandle,
              parent: NFSFileHandle, name: String) async throws
    func readlink(handle: NFSFileHandle) async throws -> String

    // MARK: OPEN / CLOSE (stateful)
    func open(parent: NFSFileHandle, name: String,
              share: NFSShareAccess, deny: NFSShareDeny,
              owner: NFSOpenOwner,
              wantDelegation: NFSDelegationHint,
              create: NFSCreateMode) async throws -> (handle: NFSFileHandle,
                                                       result: NFSOpenResult)
    func openConfirm(handle: NFSFileHandle,
                     stateid: NFSStateID, seqid: UInt32) async throws -> NFSStateID
    func openDowngrade(handle: NFSFileHandle,
                       stateid: NFSStateID,
                       share: NFSShareAccess,
                       deny: NFSShareDeny) async throws -> NFSStateID
    func close(handle: NFSFileHandle, stateid: NFSStateID) async throws

    // MARK: I/O
    func read(handle: NFSFileHandle,
              stateid: NFSStateID,
              offset: UInt64, count: Int) async throws -> NFSReadResult
    func write(handle: NFSFileHandle,
               stateid: NFSStateID,
               offset: UInt64,
               stability: NFSWriteStability,
               data: Data) async throws -> NFSWriteResult
    func commit(handle: NFSFileHandle,
                offset: UInt64, count: UInt64) async throws -> UInt64

    // MARK: Locking
    func lock(handle: NFSFileHandle,
              type: NFSLockType,
              range: NFSLockRange,
              owner: NFSLockOwner,
              reclaim: Bool,
              stateid: NFSStateID) async throws -> NFSStateID
    func lockTest(handle: NFSFileHandle,
                  type: NFSLockType,
                  range: NFSLockRange,
                  owner: NFSLockOwner) async throws -> NFSLockTestResult
    func unlock(handle: NFSFileHandle,
                range: NFSLockRange,
                stateid: NFSStateID) async throws -> NFSStateID
}
