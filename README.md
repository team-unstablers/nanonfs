# nanonfs

FUSE-like 한 API를 제공하는 로컬 액세스 (루프백) 전용 NFS 서버 — Swift Package.

> 이 문서 자체가 nanonfs의 **스펙 문서** 입니다. 모든 외부 동작·공개 API·구현 범위는 이 문서를 1차 출처로 삼습니다.
> 본 패키지의 와이어 프로토콜은 **NFSv4.0 (RFC 7530)** 한 종만 지원합니다. 패키지 루트의 `docs/rfc7530.txt` 가 정본 근거 문서입니다.

---

## 1. 왜 이딴 짓을?

macOS 에서는 FUSE 가 정식적으로 지원되지 않습니다.

대안인 `macFUSE` 는 커널 익스텐션을 요구하기 때문에 SIP / 시스템 익스텐션 승인 / 보안 부트 정책 등 사용자 환경에 침습적인 변경을 동반합니다. 반면 macOS 는 NFS 클라이언트(`mount_nfs`) 를 기본 탑재하고 있고, 이는 어떠한 커널 익스텐션 없이도 사용자 공간(user-space) 프로세스가 노출한 가상 파일 시스템을 마운트할 수 있게 해줍니다.

`nanonfs` 는 이 점을 이용합니다. 즉, FUSE 처럼 `lookup` / `read` / `write` 같은 콜백을 Swift 로 작성하면, 그 콜백들이 **루프백 NFS 서버** 로 노출되어 동일 머신의 `mount_nfs` 가 마운트할 수 있는 형태로 동작합니다.

목표는 정확히 다음 두 가지뿐입니다.

- **동일 머신** 내에서 `mount_nfs` 가 마운트할 수 있는 NFSv4.0 서버를 Swift 라이브러리로 제공한다.
- 사용자가 **FUSE 콜백 비슷한 추상화** 만으로 가상 파일 시스템을 작성할 수 있게 한다.

비목표 (non-goals):

- 멀티 호스트·프로덕션 NFS 서버 대체. **루프백 전용** 입니다.
- NFSv3, NFSv4.1, pNFS 지원.
- Kerberos / RPCSEC_GSS.
- ACL / Named Attributes (NFSv4 xattr).

---

## 2. 패키지 / 플랫폼

- Swift Package 이름 (repo 디렉토리): `nanonfs`
- Swift module / product 이름: **`NanoNFS`**
- `swift-tools-version`: `6.0`
- 대상 플랫폼: **macOS 14+** (다른 플랫폼은 지원하지 않습니다)
- Swift Concurrency: **strict concurrency** 모드, 모든 공개 타입은 `Sendable`
- 라이선스: **MIT**

### 의존성

| 패키지 | 용도 |
| --- | --- |
| `apple/swift-nio` | TCP 리스너 / 비동기 I/O |
| `apple/swift-log` | 로깅 퍼사드 |
| `apple/swift-atomics` | 클라이언트·세션 카운터 등 lockless 카운터 |

테스트는 **swift-testing** (`@Test`) 로 작성합니다. `mount_nfs` 연동 e2e 테스트는 macOS 환경 전제입니다.

### Sources 디렉토리 구조

```
Sources/NanoNFS/
├── Public/      # 공개 API (NFSServer, NFSStat, NFSError, NFSServerListener ...)
├── Wire/        # NFSv4 op 처리, COMPOUND 디스패치, stateid·clientid 관리
├── RPC/         # ONC RPC (RFC 5531) 메시지 인코딩, AUTH_SYS 파싱
├── XDR/         # XDR (RFC 4506) 인코더/디코더
└── Internal/    # 보조 유틸 (logging, async helpers, file handle 매핑 등)
```

`Public/` 외부에 대한 import 는 모두 `internal` 입니다. 사용자가 보는 표면은 `Public/` 한 곳뿐.

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
    // ... 기타 NFSServer 요구 메서드 전부 구현 ...
}

let listener = NFSServerListener(
    server: MyFS(),
    bind: .loopback(port: 14049)   // 기본 127.0.0.1:14049
)

try await listener.run()
```

이후 별도 셸에서:

```sh
sudo mount_nfs -o vers=4,port=14049,mountport=14049,tcp 127.0.0.1:/ /mnt/myfs
```

`mount_nfs` 호출은 라이브러리가 도와주지 않습니다 (사용자 책임). 단, `Bind` 설정으로 외부 인터페이스 바인딩을 명시적으로 막아 루프백 의도를 보장합니다.

---

## 4. Public API

본 절의 모든 시그니처가 공개 API의 정본입니다. 시그니처와 실제 코드가 어긋나면 본 문서를 정으로 봅니다 (구현이 따라옵니다).

### 4.1 식별자 / 값 타입

```swift
/// NFSv4 의 가변 길이 opaque file handle. 서버가 발급하고 서버가 해석한다.
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

/// NFSv4 시간 타입. 초 + 나노초.
public struct NFSTime: Hashable, Sendable {
    public var seconds: Int64
    public var nseconds: UInt32
    public static func now() -> NFSTime
}

/// 객체 종류 (NFSv4 nfs_ftype4).
public enum NFSObjectType: UInt32, Sendable {
    case regularFile = 1, directory, blockDevice, characterDevice,
         symbolicLink, socket, fifo, attributeDirectory, namedAttribute
}

/// FUSE-like POSIX 스타일 stat. NFSv4 FATTR4 비트맵과 라이브러리 내부에서 양방향 변환된다.
public struct NFSStat: Hashable, Sendable {
    public var type: NFSObjectType
    public var mode: UInt32           // POSIX permission bits
    public var nlink: UInt32
    public var uid: UInt32
    public var gid: UInt32
    public var size: UInt64
    public var used: UInt64           // bytes 실제 사용량
    public var fileid: UInt64         // inode-like 안정 식별자
    public var atime: NFSTime
    public var mtime: NFSTime
    public var ctime: NFSTime
    public var rdev: (major: UInt32, minor: UInt32)?
}

/// SETATTR 입력. Optional 인 필드만 갱신한다 (FATTR4 비트맵의 Swift 반영).
public struct NFSAttributesPatch: Sendable {
    public var mode: UInt32?
    public var uid: UInt32?
    public var gid: UInt32?
    public var size: UInt64?
    public var atime: NFSTime?        // .some(.now()) 면 SET_TO_SERVER_TIME 와 동치
    public var mtime: NFSTime?
}
```

### 4.2 권한 / 공유 / 락

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
    public var length: UInt64         // 0xFFFFFFFFFFFFFFFF 이면 EOF 까지
}

public enum NFSWriteStability: UInt32, Sendable {
    case unstable = 0
    case dataSync = 1
    case fileSync = 2
}
```

### 4.3 호출 결과 타입

```swift
public struct NFSReadResult: Sendable {
    public var data: Data
    public var eof: Bool
}

public struct NFSWriteResult: Sendable {
    public var count: Int
    public var committed: NFSWriteStability
    public var writeVerifier: UInt64  // COMMIT 검증에 사용
}

public struct NFSOpenResult: Sendable {
    public var stateid: NFSStateID
    public var rflags: NFSOpenFlags                // OPEN_CONFIRM 필요 여부 등
    public var delegation: NFSDelegationGrant      // .none 으로 두면 OK
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
    public var attrs: NFSStat?        // GETATTR 동시 응답용. nil 이면 라이브러리가 보충 호출
}

public struct NFSDirList: Sendable {
    public var entries: [NFSDirEntry]
    public var nextCookie: UInt64?    // nil 이면 더 없음
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

### 4.4 에러

```swift
/// NFSv4 NFS4ERR_* 에 대응하는 사용자 에러. 매핑되지 않은 throw 는 NFS4ERR_SERVERFAULT.
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

### 4.5 NFSServer 프로토콜

> **모든 메서드는 사용자가 직접 구현해야 합니다 (default 구현 없음)**. 지원하지 않는 동작은 `throw NFSError.notSupported` 또는 `.readOnly` 등으로 명시적으로 거부합니다.
>
> 모든 메서드는 `async throws`. 구현체는 `actor` 권장 (라이브러리가 동시 호출을 직렬화하지 않습니다 — 사용자가 actor 등의 격리로 보장하세요).

```swift
public protocol NFSServer: Sendable {

    // MARK: 루트
    /// 마운트의 루트 file handle (PUTROOTFH 응답에 쓰임).
    func root() async throws -> NFSFileHandle

    // MARK: 메타데이터
    func access(handle: NFSFileHandle, mask: NFSAccess) async throws -> NFSAccess
    func getattr(handle: NFSFileHandle) async throws -> NFSStat
    func setattr(handle: NFSFileHandle,
                 stateid: NFSStateID?,            // 사이즈 변경 시 OPEN stateid
                 patch: NFSAttributesPatch) async throws -> NFSStat

    // MARK: 디렉토리
    func lookup(parent: NFSFileHandle, name: String) async throws -> NFSFileHandle
    func lookupParent(of handle: NFSFileHandle) async throws -> NFSFileHandle
    func readdir(handle: NFSFileHandle,
                 cookie: UInt64,
                 cookieVerifier: UInt64,
                 maxEntries: Int) async throws -> NFSDirList

    // MARK: 생성 / 삭제 / 이동
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
    case open                                    // 열기만, 없으면 noEntry
    case create(NFSAttributesPatch)              // UNCHECKED
    case createExclusive(verifier: UInt64)       // EXCLUSIVE4
}
```

### 4.6 Listener / 바인딩

```swift
public struct NFSBind: Sendable {
    /// 127.0.0.1 / ::1 만 허용. 외부 인터페이스가 들어오면 init 단계에서 precondition.
    public static func loopback(port: UInt16 = 14049) -> NFSBind
    /// 명시적으로 외부 IP에 바인딩 — 루프백 의도를 깨뜨리는 escape hatch.
    /// 라이브러리는 이 모드에서 경고 로그를 남깁니다.
    public static func external(host: String, port: UInt16) -> NFSBind
}

public final class NFSServerListener: Sendable {
    public init(server: any NFSServer,
                bind: NFSBind = .loopback(),
                logger: Logger = Logger(label: "nanonfs"),
                eventLoopGroup: EventLoopGroup? = nil)

    /// swift-service-lifecycle 스타일. Task 가 cancel 되면 graceful shutdown 후 반환.
    public func run() async throws

    /// 현재 바인딩된 (host, port). run() 내부에서 바인딩이 끝난 뒤 값을 가집니다.
    public var boundAddress: SocketAddress? { get async }
}
```

- 기본 포트: **14049** (NFS 표준 2049 가 root 권한을 요구하기 때문에 high port).
- 기본 호스트: **127.0.0.1** 단독. `NFSBind.loopback` 외에는 의식적으로 `external(...)` 을 써야 합니다.
- 인증: **AUTH_SYS** 만 수락. AUTH_NONE / RPCSEC_GSS 는 NFS4ERR_WRONGSEC 으로 거부.
- 클라이언트 라이프사이클 (`SETCLIENTID` / `RENEW` / lease 만료) 은 **라이브러리가 자동 관리** — `NFSServer` 구현체에 노출되지 않습니다.
- Delegation 은 사용자가 `wantDelegation` 힌트를 주면 라이브러리가 발급/회수(CB_RECALL)를 자동 처리합니다.

---

## 5. 구현 범위 (Phase 1) / Roadmap

### Phase 1 (v0.1 — 첫 번째 동작 가능 버전)

- [ ] NFSv4.0 COMPOUND 디스패치
- [ ] AUTH_SYS / loopback 바인딩
- [ ] `PUTROOTFH` / `PUTFH` / `GETFH` / `SAVEFH` / `RESTOREFH`
- [ ] `LOOKUP` / `LOOKUPP` / `ACCESS` / `GETATTR` / `SETATTR`
- [ ] `READDIR` (cookie/verifier 포함)
- [ ] `READ` / `WRITE` / `COMMIT` (stability 인자 포함)
- [ ] `CREATE` / `REMOVE` / `RENAME` / `LINK` / `READLINK`
- [ ] `OPEN` / `OPEN_CONFIRM` / `OPEN_DOWNGRADE` / `CLOSE`
- [ ] `LOCK` / `LOCKT` / `LOCKU` / `RELEASE_LOCKOWNER`
- [ ] `SETCLIENTID` / `SETCLIENTID_CONFIRM` / `RENEW` (라이브러리 내부)
- [ ] Delegation 발급 + `CB_RECALL` (콜백 채널 포함)
- [ ] FATTR4 ↔ `NFSStat` 양방향 매핑 (필수 + 추천 어트리뷰트 일부)

### 명시적 비지원 (당분간)

- NFSv3, NFSv4.1+, pNFS
- ACL (NFSv4 ACL, FATTR4_ACL)
- Named Attributes (`OPENATTR`, NFSv4 xattr)
- RPCSEC_GSS / Kerberos
- 다중 호스트 / 외부 노출 (escape hatch 외)

### Roadmap (Phase 2 이후)

- 이름 비교를 위한 유니코드 정규화 옵션
- COMMIT 누락 검출 / writeVerifier 전략 옵션
- ACL / Named Attributes
- 성능 측정 / READ·WRITE 의 ByteBuffer 오버로드
- mount 헬퍼 (`mount_nfs` 서브프로세스 invoker, optional)

---

## 5.5 Demo / 수동 mount 검증

Phase 1 의 `swift test` 는 mock 기반 + loopback TCP 시뮬레이션 클라이언트로 RFC 7530 의 마운트 시퀀스 (SETCLIENTID → CONFIRM → PUTROOTFH/GETATTR → READDIR → LOOKUP/OPEN/READ) 가 끝까지 OK 로 흘러가는 것을 검증합니다.

진짜 macOS NFS 클라이언트 (`mount_nfs`) 로 검증하려면 **별도 데모 실행 + sudo 가 필요**합니다. 자동 테스트가 아닙니다.

```sh
# 1. 데모 서버 띄우기 (foreground, Ctrl+C 로 종료)
swift run NanoNFSDemo

# 2. 다른 터미널에서:
sudo mkdir -p /mnt/nanonfs
sudo mount_nfs -o vers=4,port=14049,mountport=14049,tcp,resvport=0 \
    127.0.0.1:/ /mnt/nanonfs

ls /mnt/nanonfs           # hello.txt, readme
cat /mnt/nanonfs/hello.txt

sudo umount /mnt/nanonfs
```

`mount_nfs` 가 "Operation not supported" 등으로 실패하면, 거의 항상 우리 서버가 클라이언트가 기대하는 어떤 op 또는 FATTR4 attr 를 채우지 못한 것이 원인입니다 — `swift run NanoNFSDemo` 의 로그 (`debug` 레벨로 올리려면 `LOG_LEVEL=debug swift run NanoNFSDemo`) 에 어느 op 에서 어떤 status 가 떨어졌는지가 찍힙니다.

---

## 6. Wire 매핑 (NFSv4 op ↔ NFSServer 메서드)

라이브러리는 단일 RPC 안의 COMPOUND 시퀀스를 op 단위로 풀어, 아래 표에 따라 `NFSServer` 메서드로 위임합니다. PUTFH 류 op 는 사용자 메서드를 호출하지 않고 내부 "현재 file handle" 상태만 갱신합니다.

| NFSv4 op | NFSServer 메서드 | 비고 |
| --- | --- | --- |
| `PUTROOTFH` | `root()` | 결과를 현재 fh 로 설정 |
| `PUTFH` | — | 현재 fh = 인자 fh (유효성은 `getattr` 로 lazy 검증) |
| `GETFH` | — | 현재 fh 를 응답에 복사 |
| `SAVEFH` / `RESTOREFH` | — | 내부 스택 |
| `ACCESS` | `access(handle:mask:)` | |
| `GETATTR` | `getattr(handle:)` | FATTR4 비트맵은 라이브러리가 변환 |
| `SETATTR` | `setattr(handle:stateid:patch:)` | size 갱신 시 stateid 필요 |
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
| `SETCLIENTID` / `SETCLIENTID_CONFIRM` | — | 라이브러리 내부 |
| `RENEW` | — | 라이브러리 내부 |
| `RELEASE_LOCKOWNER` | — | 라이브러리 내부 (사용자에게는 lock owner GC 신호) |
| `DELEGRETURN` / `DELEGPURGE` | — | 라이브러리 내부 |
| `OPENATTR` / ACL 관련 | — | NFS4ERR_NOTSUPP 고정 |
| `SECINFO` | — | AUTH_SYS 고정 응답 |
| `VERIFY` / `NVERIFY` | `getattr(handle:)` 결과로 라이브러리 비교 | 사용자 호출 없음 |
| `ILLEGAL` / 그 외 | — | NFS4ERR_OP_ILLEGAL |

콜백 채널 (CB_COMPOUND, CB_RECALL) 은 라이브러리가 별도 클라이언트 측 NFSv4 콜백 RPC 로 송출하며, 사용자 코드는 관여하지 않습니다.
