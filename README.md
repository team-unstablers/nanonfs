# nanonfs

A loopback-only NFS server that provides a FUSE-like API — Swift Package.

> Vibe-coded with Claude Code. One of the open-source components of [Noctiluca](https://noctiluca.app), but you may want to validate it for your own use case before relying on it.

> This document is itself the **specification** for nanonfs. All external behavior, public API, and implementation scope take this document as the primary source.
> The wire protocol supported by this package is **NFSv4.0 (RFC 7530)** only. The file `docs/rfc7530.txt` at the package root is the authoritative reference.

---

## 1. Why on earth?

FUSE is not officially supported on macOS.

The alternative, `macFUSE`, requires a kernel extension, which entails invasive changes to the user's environment such as SIP, system extension approval, and secure boot policy. macOS, on the other hand, ships with an NFS client (`mount_nfs`) by default, which allows a user-space process to expose a virtual file system that can be mounted without any kernel extension.

`nanonfs` exploits this fact. That is, you write callbacks like `lookup` / `read` / `write` in Swift, just like FUSE, and those callbacks are exposed as a **loopback NFS server**, mountable by `mount_nfs` on the same machine.

The goals are exactly the following two:

- Provide an NFSv4.0 server as a Swift library that `mount_nfs` can mount **on the same machine**.
- Let users write a virtual file system using **only a FUSE-like callback abstraction**.

Non-goals:

- Replacing a multi-host / production NFS server. **Loopback only.**
- NFSv3, NFSv4.1, pNFS support.
- Kerberos / RPCSEC_GSS.
- ACL / Named Attributes (NFSv4 xattr).

---

## 2. Package / Platform

- Swift Package name (repo directory): `nanonfs`
- Swift module / product name: **`NanoNFS`**
- `swift-tools-version`: `6.2` (requires SE-0450 package traits)
- Target platform: **macOS 14+** (other platforms are not supported)
- Swift Concurrency: **strict concurrency** mode, all public types are `Sendable`
- License: **MIT**

### Dependencies

| Package | Purpose | Always pulled? |
| --- | --- | --- |
| `apple/swift-nio` (`NIOCore`, `NIOFoundationCompat`) | `ByteBuffer` and the encoder primitives that the XDR / RPC / Wire layers are built on | Yes — baseline |
| `apple/swift-nio` (`NIO`, `NIOPosix`) | The default NIO-backed listener (`NFSTransport.nio`) | Only with the `NIO` trait |
| `apple/swift-log` | Logging facade | Yes — baseline |
| `apple/swift-atomics` | Lockless counters such as client / session counters | Yes — baseline |

`NIOCore.ByteBuffer` is the encoding medium across the XDR / RPC / Wire layers, so `NIOCore` (and `NIOFoundationCompat` for `Data` interop) are unconditional baseline dependencies. Trait gating only affects which **listener implementation** gets built — not the encoder path.

Tests are written using **swift-testing** (`@Test`). The `mount_nfs` integration e2e tests assume a macOS environment.

### Package traits

`NanoNFS` exposes two traits that select which TCP listener implementation is built into the library. At least one trait must be enabled, otherwise the package fails to compile.

| Trait | Default | Listener implementation | External dependencies pulled |
| --- | --- | --- | --- |
| `NIO` | enabled | `NFSTransport.nio(eventLoopGroup:)` — `NIOPosix.ServerBootstrap` based | `swift-nio`'s `NIO` and `NIOPosix` products |
| `BSDSocket` | disabled | `NFSTransport.bsdSocket` — pure Swift Concurrency on top of `socket(2)` + `kqueue(2)` + `EVFILT_USER` | none beyond baseline (`Foundation` + `Darwin`) |

To opt out of NIO entirely (e.g. when consuming `NanoNFS` from a host application that does not want a Swift-NIO dependency for the network layer), disable the `NIO` trait and enable `BSDSocket`:

```swift
.package(url: "...", from: "...", traits: ["BSDSocket"])
```

Or, in a `Package.swift` consumer:

```swift
.package(
    url: "https://github.com/.../nanonfs.git",
    from: "0.x.0",
    traits: [
        .trait(name: "BSDSocket"),
        // .default omitted — disables NIO
    ]
)
```

Both traits can be enabled simultaneously. In that case `NFSTransport.default` resolves to `.nio()`; `.bsdSocket` is still available for explicit selection.

### Sources directory layout

```
Sources/NanoNFS/
├── Public/      # Public API (NFSServer, NFSStat, NFSError, NFSServerListener ...)
├── Wire/        # NFSv4 op handling, COMPOUND dispatch, stateid / clientid management
├── RPC/         # ONC RPC (RFC 5531) message encoding, AUTH_SYS parsing
├── XDR/         # XDR (RFC 4506) encoder / decoder
└── Internal/    # Auxiliary utilities (logging, async helpers, file handle mapping, etc.)
```

All imports outside of `Public/` are `internal`. The only surface area the user sees is `Public/`.

---

## 3. SYNOPSIS

```swift
import NanoNFS

actor MyFS: NFSServer {
    func root() async throws -> NFSFileHandle { ... }

    func lookup(parent: NFSFileHandle, name: String) async throws -> NFSFileHandle { ... }
    func getattr(handle: NFSFileHandle) async throws -> NFSStat { ... }
    func read(handle: NFSFileHandle, stateid: NFSStateID,
              offset: UInt64, count: Int) async throws -> NFSReadResult { ... }
    // ... implement all other required NFSServer methods ...
}

let listener = NFSServerListener(
    server: MyFS(),
    bind: .loopback(port: 14049),   // default 127.0.0.1:14049
    transport: .default              // .nio() when the NIO trait is on, .bsdSocket otherwise
)

try await listener.run()
```

Then, in a separate shell:

```sh
sudo mount_nfs -o vers=4,port=14049,mountport=14049,tcp 127.0.0.1:/ /mnt/myfs
```

The library does not help with invoking `mount_nfs` (that is the user's responsibility). However, the `Bind` configuration explicitly prevents binding to external interfaces in order to guarantee the loopback intent.

The transport is pluggable. Picking `.nio()` (the default when the `NIO` trait is on) uses an `NIOPosix.ServerBootstrap`-based listener that lets you optionally inject your own `EventLoopGroup`. Picking `.bsdSocket` uses a pure Swift Concurrency listener built directly on `socket(2)` + `kqueue(2)` and pulls no Swift-NIO product beyond the baseline `NIOCore` (used as the XDR encoding medium). You can also supply a custom transport with `.custom(myImpl)` — see §4.6.

---

## 4. Public API

All signatures in this section are the authoritative public API. If a signature and the actual code diverge, this document is canonical (the implementation must follow).

### 4.1 Identifier / value types

```swift
/// Variable-length opaque NFSv4 file handle. The server issues it and the server interprets it.
public struct NFSFileHandle: Hashable, Sendable {
    public var bytes: Data            // ≤ NFS4_FHSIZE (128) bytes
    public init(_ bytes: Data)
}

/// NFSv4 stateid. (seqid, other[12]).
public struct NFSStateID: Hashable, Sendable {
    public var seqid: UInt32
    public var other: Data            // 12 bytes
    public static let anonymous: NFSStateID
    public static let bypass: NFSStateID
}

/// NFSv4 time type. Seconds + nanoseconds.
public struct NFSTime: Hashable, Sendable {
    public var seconds: Int64
    public var nseconds: UInt32
    public static func now() -> NFSTime
}

/// Object kind (NFSv4 nfs_ftype4).
public enum NFSObjectType: UInt32, Sendable {
    case regularFile = 1, directory, blockDevice, characterDevice,
         symbolicLink, socket, fifo, attributeDirectory, namedAttribute
}

/// FUSE-like POSIX-style stat. Bidirectionally converted with the NFSv4 FATTR4 bitmap inside the library.
public struct NFSStat: Hashable, Sendable {
    public var type: NFSObjectType
    public var mode: UInt32           // POSIX permission bits
    public var nlink: UInt32
    public var uid: UInt32
    public var gid: UInt32
    public var size: UInt64
    public var used: UInt64           // bytes actually used
    public var fileid: UInt64         // inode-like stable identifier
    public var atime: NFSTime
    public var mtime: NFSTime
    public var ctime: NFSTime
    public var rdev: (major: UInt32, minor: UInt32)?
}

/// SETATTR input. Only the `Optional` fields that are set are updated (the Swift reflection of the FATTR4 bitmap).
public struct NFSAttributesPatch: Sendable {
    public var mode: UInt32?
    public var uid: UInt32?
    public var gid: UInt32?
    public var size: UInt64?
    public var atime: NFSTime?        // .some(.now()) is equivalent to SET_TO_SERVER_TIME
    public var mtime: NFSTime?
}
```

### 4.2 Permission / share / lock

```swift
public struct NFSAccess: OptionSet, Sendable {
    public let rawValue: UInt32
    public static let read    = NFSAccess(rawValue: 0x0001)
    public static let lookup  = NFSAccess(rawValue: 0x0002)
    public static let modify  = NFSAccess(rawValue: 0x0004)
    public static let extend  = NFSAccess(rawValue: 0x0008)
    public static let delete  = NFSAccess(rawValue: 0x0010)
    public static let execute = NFSAccess(rawValue: 0x0020)
}

public struct NFSShareAccess: OptionSet, Sendable {
    public let rawValue: UInt32
    public static let read  = NFSShareAccess(rawValue: 0x01)
    public static let write = NFSShareAccess(rawValue: 0x02)
    public static let both: NFSShareAccess = [.read, .write]
}

public struct NFSShareDeny: OptionSet, Sendable {
    public let rawValue: UInt32
    public static let none  = NFSShareDeny([])
    public static let read  = NFSShareDeny(rawValue: 0x01)
    public static let write = NFSShareDeny(rawValue: 0x02)
    public static let both: NFSShareDeny = [.read, .write]
}

public enum NFSDelegationHint: Sendable {
    case none, read, write, any
}

public struct NFSOpenOwner: Hashable, Sendable {
    public var clientid: UInt64
    public var owner: Data            // ≤ 1024 bytes
}

public struct NFSLockOwner: Hashable, Sendable {
    public var clientid: UInt64
    public var owner: Data
}

public enum NFSLockType: Sendable {
    case readShared
    case writeExclusive
    case readSharedBlocking
    case writeExclusiveBlocking
}

public struct NFSLockRange: Sendable {
    public var offset: UInt64
    public var length: UInt64         // 0xFFFFFFFFFFFFFFFF means up to EOF
}

public enum NFSWriteStability: UInt32, Sendable {
    case unstable = 0
    case dataSync = 1
    case fileSync = 2
}
```

### 4.3 Call result types

```swift
public struct NFSReadResult: Sendable {
    public var data: Data
    public var eof: Bool
}

public struct NFSWriteResult: Sendable {
    public var count: Int
    public var committed: NFSWriteStability
    public var writeVerifier: UInt64  // used for COMMIT verification
}

public struct NFSOpenResult: Sendable {
    public var stateid: NFSStateID
    public var rflags: NFSOpenFlags                // whether OPEN_CONFIRM is required, etc.
    public var delegation: NFSDelegationGrant      // setting it to .none is fine
}

public struct NFSOpenFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public static let confirmRequired = NFSOpenFlags(rawValue: 0x0002)
    public static let lockTypePosix   = NFSOpenFlags(rawValue: 0x0004)
}

public enum NFSDelegationGrant: Sendable {
    case none
    case read(stateid: NFSStateID, recall: Bool)
    case write(stateid: NFSStateID, recall: Bool, spaceLimit: UInt64)
}

public struct NFSDirEntry: Sendable {
    public var fileid: UInt64
    public var name: String
    public var attrs: NFSStat?        // for a piggybacked GETATTR response. If nil, the library issues a follow-up call
}

public struct NFSDirList: Sendable {
    public var entries: [NFSDirEntry]
    public var nextCookie: UInt64?    // nil means no more
    public var verifier: UInt64
    public var eof: Bool
}

public struct NFSLockTestResult: Sendable {
    public enum Outcome: Sendable {
        case granted
        case denied(conflict: NFSLockRange, type: NFSLockType, owner: NFSLockOwner)
    }
    public var outcome: Outcome
}
```

### 4.4 Errors

```swift
/// User-facing errors corresponding to NFSv4 NFS4ERR_*. Unmapped throws become NFS4ERR_SERVERFAULT.
public enum NFSError: Error, Sendable {
    case permission           // NFS4ERR_PERM
    case noEntry              // NFS4ERR_NOENT
    case io                   // NFS4ERR_IO
    case noSuchDevice         // NFS4ERR_NXIO
    case accessDenied         // NFS4ERR_ACCESS
    case exists               // NFS4ERR_EXIST
    case crossDevice          // NFS4ERR_XDEV
    case notDirectory         // NFS4ERR_NOTDIR
    case isDirectory          // NFS4ERR_ISDIR
    case invalid              // NFS4ERR_INVAL
    case fileTooBig           // NFS4ERR_FBIG
    case noSpace              // NFS4ERR_NOSPC
    case readOnly             // NFS4ERR_ROFS
    case tooManyLinks         // NFS4ERR_MLINK
    case nameTooLong          // NFS4ERR_NAMETOOLONG
    case notEmpty             // NFS4ERR_NOTEMPTY
    case dirQuota             // NFS4ERR_DQUOT
    case stale                // NFS4ERR_STALE
    case badHandle            // NFS4ERR_BADHANDLE
    case notSupported         // NFS4ERR_NOTSUPP
    case fileBusy             // NFS4ERR_FILE_OPEN
    case shareDenied          // NFS4ERR_SHARE_DENIED
    case lockDenied(conflict: NFSLockRange,
                    type: NFSLockType,
                    owner: NFSLockOwner)        // NFS4ERR_DENIED
    case lockRangeOverlap                       // NFS4ERR_LOCK_RANGE
    case staleStateid                           // NFS4ERR_STALE_STATEID
    case oldStateid                             // NFS4ERR_OLD_STATEID
    case badStateid                             // NFS4ERR_BAD_STATEID
    case wrongType            // NFS4ERR_WRONG_TYPE
    case serverFault          // NFS4ERR_SERVERFAULT
}
```

### 4.5 The `NFSServer` protocol

> **Every method must be implemented by the user (no default implementations).** Unsupported behavior must be explicitly rejected with `throw NFSError.notSupported`, `.readOnly`, etc.
>
> All methods are `async throws`. An `actor` conformer is recommended (the library does not serialize concurrent calls — the user is responsible for ensuring isolation, e.g. via an `actor`).

```swift
public protocol NFSServer: Sendable {

    // MARK: Root
    /// The mount root file handle (used in the response to PUTROOTFH).
    func root() async throws -> NFSFileHandle

    // MARK: Metadata
    func access(handle: NFSFileHandle, mask: NFSAccess) async throws -> NFSAccess
    func getattr(handle: NFSFileHandle) async throws -> NFSStat
    func setattr(handle: NFSFileHandle,
                 stateid: NFSStateID?,            // OPEN stateid when changing size
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
                type: NFSObjectType, attrs: NFSAttributesPatch) async throws -> NFSFileHandle
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
                offset: UInt64, count: UInt64) async throws -> UInt64  // writeVerifier

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

public enum NFSCreateMode: Sendable {
    case open                                    // open only; if it does not exist, noEntry
    case create(NFSAttributesPatch)              // UNCHECKED
    case createExclusive(verifier: UInt64)       // EXCLUSIVE4
}
```

### 4.6 Listener / binding / transport

```swift
public struct NFSBind: Sendable, Equatable {
    /// Allows only 127.0.0.1 / ::1. If an external interface is supplied, it `precondition`s at init time.
    public static func loopback(port: UInt16 = 14049) -> NFSBind
    /// Explicitly binds to an external IP — an escape hatch that breaks the loopback intent.
    /// The library emits a warning log in this mode.
    public static func external(host: String, port: UInt16) -> NFSBind
}

/// The address the transport ended up bound to. Transport-agnostic — does not
/// expose any NIO type. Host is the IPv4 / IPv6 textual representation.
public struct NFSBoundAddress: Sendable, Hashable {
    public let host: String
    public let port: UInt16
    public init(host: String, port: UInt16)
}

public final class NFSServerListener: Sendable {
    public init(server: any NFSServer,
                bind: NFSBind = .loopback(),
                transport: NFSTransport = .default,
                logger: Logger = Logger(label: "nanonfs"))

    /// swift-service-lifecycle style. Returns after a graceful shutdown if the Task is cancelled.
    public func run() async throws

    /// The currently bound (host, port). It has a value once binding is complete inside `run()`.
    public var boundAddress: NFSBoundAddress? { get async }
}
```

- Default port: **14049** (a high port, since the standard NFS port 2049 requires root privileges).
- Default host: **127.0.0.1** only. Anything other than `NFSBind.loopback` requires deliberately using `external(...)`.
- Authentication: only **AUTH_SYS** is accepted. AUTH_NONE / RPCSEC_GSS are rejected with NFS4ERR_WRONGSEC.
- Client lifecycle (`SETCLIENTID` / `RENEW` / lease expiration) is **managed automatically by the library** — it is not exposed to the `NFSServer` implementer.
- Delegation: when the user supplies a `wantDelegation` hint, the library handles issuing and recalling it (CB_RECALL) automatically.

#### Transport selection

```swift
/// Selects which TCP listener implementation `NFSServerListener` uses. Cases
/// are conditionally compiled in based on the package traits enabled at build
/// time (see §2). `Equatable` is intentionally not synthesised because
/// `case custom(any ...)` cannot be compared structurally.
public enum NFSTransport: Sendable {
    #if NIO
    /// Swift-NIO based listener. If `eventLoopGroup` is `nil` the transport
    /// owns and tears down its own single-thread `MultiThreadedEventLoopGroup`.
    /// If you supply one, its lifetime stays your responsibility — the
    /// transport will not shut it down.
    case nio(eventLoopGroup: NFSNIOEventLoopGroupBox? = nil)
    #endif

    #if BSDSOCKET
    /// macOS BSD socket based listener. Pure Swift Concurrency on top of
    /// `socket(2)` + `kqueue(2)` + `EVFILT_USER`. No GCD, no Network.framework.
    case bsdSocket
    #endif

    /// User-supplied implementation.
    case custom(any NFSTransportImplementation)

    /// Resolves to the highest-priority enabled trait at build time.
    /// Priority: `nio` > `bsdSocket`. If neither trait is enabled,
    /// the package fails to compile (`#error`).
    public static var `default`: NFSTransport { get }
}

#if NIO
/// Trait-gated: only present when the `NIO` trait is enabled. Lets users hand
/// in their own NIO `EventLoopGroup` without making `NIOCore.EventLoopGroup`
/// part of the unconditional public API.
public struct NFSNIOEventLoopGroupBox: Sendable {
    public let group: any EventLoopGroup
    public init(_ group: any EventLoopGroup)
}
#endif
```

#### Custom transport (`NFSTransportImplementation`)

A transport is a *listener-level* abstraction: one instance is responsible for `bind` + `accept` loop + per-connection raw byte I/O. Record-mark framing (RFC 5531 §11) and NFSv4 COMPOUND dispatch stay on `NFSServerListener` itself, so the transport only deals with raw TCP bytes.

```swift
public protocol NFSTransportImplementation: Sendable {

    /// Fired once between bind(2) and accept(2). The listener uses it to
    /// publish the actual host/port through `NFSServerListener.boundAddress`.
    typealias BindNotification = @Sendable (NFSBoundAddress) async -> Void

    /// Invoked once per accepted client connection.
    ///   - `inbound`  is the raw TCP byte stream (before record-mark decoding).
    ///   - `outbound` is the raw TCP byte writer (after record-mark encoding).
    /// The transport keeps the connection open until this closure either
    /// returns normally or throws.
    typealias ConnectionHandler = @Sendable (
        _ inbound: NFSAsyncByteStream,
        _ outbound: NFSAsyncByteWriter
    ) async throws -> Void

    /// Bind, accept, dispatch. Returns when the surrounding `Task` is
    /// cancelled (graceful shutdown).
    func serve(
        bind: NFSBind,
        logger: Logger,
        onBind: BindNotification,
        connectionHandler: ConnectionHandler
    ) async throws
}

/// One connection's inbound byte stream. AsyncSequence semantics: terminates
/// on cancellation or peer half-close. Element is `NIOCore.ByteBuffer`, which
/// is part of the unconditional baseline (see §2).
public struct NFSAsyncByteStream: AsyncSequence, Sendable {
    public typealias Element = ByteBuffer
    // ...
}

/// One connection's outbound byte writer. Single-writer.
public struct NFSAsyncByteWriter: Sendable {
    public func write(_ buffer: ByteBuffer) async throws
    public func finish() async  // half-close
}
```

Transport responsibilities at a glance:

| Concern | Owner |
| --- | --- |
| `bind(2)` / `listen(2)` / `accept(2)` loop | transport |
| per-connection raw byte read / write | transport |
| RFC 5531 §11 record-mark framing | `NFSServerListener` (shared) |
| RPC dispatch (`CompoundDispatcher`) | `NFSServerListener` (shared) |
| per-connection in-flight cap | `NFSServerListener` (shared) |

---

## 5. Implementation scope (Phase 1) / Roadmap

### Phase 1 (v0.1 — first working version)

- [ ] NFSv4.0 COMPOUND dispatch
- [ ] AUTH_SYS / loopback binding
- [ ] `PUTROOTFH` / `PUTFH` / `GETFH` / `SAVEFH` / `RESTOREFH`
- [ ] `LOOKUP` / `LOOKUPP` / `ACCESS` / `GETATTR` / `SETATTR`
- [ ] `READDIR` (including cookie / verifier)
- [ ] `READ` / `WRITE` / `COMMIT` (including the stability argument)
- [ ] `CREATE` / `REMOVE` / `RENAME` / `LINK` / `READLINK`
- [ ] `OPEN` / `OPEN_CONFIRM` / `OPEN_DOWNGRADE` / `CLOSE`
- [ ] `LOCK` / `LOCKT` / `LOCKU` / `RELEASE_LOCKOWNER`
- [ ] `SETCLIENTID` / `SETCLIENTID_CONFIRM` / `RENEW` (library-internal)
- [ ] Delegation issuance + `CB_RECALL` (including the callback channel)
- [ ] Bidirectional FATTR4 ↔ `NFSStat` mapping (mandatory + a subset of recommended attributes)

### Explicitly unsupported (for now)

- NFSv3, NFSv4.1+, pNFS
- ACL (NFSv4 ACL, FATTR4_ACL)
- Named Attributes (`OPENATTR`, NFSv4 xattr)
- RPCSEC_GSS / Kerberos
- Multi-host / external exposure (other than the escape hatch)

### Roadmap (Phase 2 and beyond)

- Unicode normalization options for name comparison
- Detection of missing COMMITs / writeVerifier strategy options
- ACL / Named Attributes
- Performance measurement / `ByteBuffer` overloads for READ and WRITE
- Mount helper (a `mount_nfs` subprocess invoker, optional)

---

## 5.5 Demo / manual mount verification

Phase 1's `swift test` verifies — using a mock-based + loopback TCP simulation client — that the RFC 7530 mount sequence (SETCLIENTID → CONFIRM → PUTROOTFH/GETATTR → READDIR → LOOKUP/OPEN/READ) flows through end-to-end with OK status.

Verifying with a real macOS NFS client (`mount_nfs`) requires **a separate demo run plus sudo**. It is not an automated test.

```sh
# 1. Start the demo server (foreground, Ctrl+C to stop).
#    The server binds to 127.0.0.1:14049 (an unprivileged port) and
#    therefore runs fine as an ordinary user — no root required.
swift run NanoNFSDemo

# 2. In another terminal. With the recommended option set below,
#    the entire mount flow runs without sudo when the mount point
#    sits inside your home directory.
mkdir -p ~/nanonfs_test

mount_nfs \
    -o vers=4,port=14049,mountport=14049,tcp,rsize=1048576,wsize=1048576,dsize=1048576,actimeo=30,noatime,async \
    127.0.0.1:/ ~/nanonfs_test

ls ~/nanonfs_test           # hello.txt, readme
cat ~/nanonfs_test/hello.txt

umount ~/nanonfs_test
```

The recommended option set above (`port=$PORT,mountport=$PORT,tcp,rsize=1048576,wsize=1048576,dsize=1048576,actimeo=30,noatime,async`) has been confirmed to mount and unmount cleanly without `sudo` on macOS — both `mount_nfs` and `umount` work as the ordinary user who launched the server, as long as the mount point itself is user-writable.

When `mount_nfs` fails with something like "Operation not supported", the cause is almost always that our server failed to provide some op or FATTR4 attribute the client expects — the log of `swift run NanoNFSDemo` (raise it to `debug` with `LOG_LEVEL=debug swift run NanoNFSDemo`) prints which op returned which status.

---

## 6. Wire mapping (NFSv4 op ↔ NFSServer method)

The library unpacks the COMPOUND sequence inside a single RPC into per-op dispatches and delegates to `NFSServer` methods according to the table below. The `PUTFH` family of ops do not invoke a user method — they only mutate the internal "current file handle" state.

| NFSv4 op | NFSServer method | Notes |
| --- | --- | --- |
| `PUTROOTFH` | `root()` | Sets the result as the current fh |
| `PUTFH` | — | current fh = argument fh (validity is lazily checked via `getattr`) |
| `GETFH` | — | Copies the current fh into the response |
| `SAVEFH` / `RESTOREFH` | — | Internal stack |
| `ACCESS` | `access(handle:mask:)` | |
| `GETATTR` | `getattr(handle:)` | The library converts the FATTR4 bitmap |
| `SETATTR` | `setattr(handle:stateid:patch:)` | A stateid is required when changing size |
| `LOOKUP` | `lookup(parent:name:)` | |
| `LOOKUPP` | `lookupParent(of:)` | |
| `READDIR` | `readdir(handle:cookie:cookieVerifier:maxEntries:)` | |
| `READLINK` | `readlink(handle:)` | |
| `READ` | `read(handle:stateid:offset:count:)` | |
| `WRITE` | `write(handle:stateid:offset:stability:data:)` | |
| `COMMIT` | `commit(handle:offset:count:)` | |
| `CREATE` | `create(parent:name:type:attrs:)` | non-regular files |
| `OPEN` | `open(parent:name:share:deny:owner:wantDelegation:create:)` | regular files |
| `OPEN_CONFIRM` | `openConfirm(handle:stateid:seqid:)` | |
| `OPEN_DOWNGRADE` | `openDowngrade(handle:stateid:share:deny:)` | |
| `CLOSE` | `close(handle:stateid:)` | |
| `REMOVE` | `remove(parent:name:)` | |
| `RENAME` | `rename(srcParent:srcName:dstParent:dstName:)` | |
| `LINK` | `link(target:parent:name:)` | |
| `LOCK` | `lock(handle:type:range:owner:reclaim:stateid:)` | |
| `LOCKT` | `lockTest(handle:type:range:owner:)` | |
| `LOCKU` | `unlock(handle:range:stateid:)` | |
| `SETCLIENTID` / `SETCLIENTID_CONFIRM` | — | library-internal |
| `RENEW` | — | library-internal |
| `RELEASE_LOCKOWNER` | — | library-internal (a lock-owner GC signal to the user) |
| `DELEGRETURN` / `DELEGPURGE` | — | library-internal |
| `OPENATTR` / ACL-related | — | hard-coded NFS4ERR_NOTSUPP |
| `SECINFO` | — | hard-coded AUTH_SYS response |
| `VERIFY` / `NVERIFY` | The library compares against the result of `getattr(handle:)` | no user call |
| `ILLEGAL` / others | — | NFS4ERR_OP_ILLEGAL |

The callback channel (CB_COMPOUND, CB_RECALL) is sent by the library as a separate client-side NFSv4 callback RPC, and user code does not participate.
