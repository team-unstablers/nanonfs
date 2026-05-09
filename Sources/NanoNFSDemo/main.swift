import Foundation
import Logging
import NanoNFS

// In-memory read-write demo file system.
//
// Layout:
//     /            (directory)
//     /hello.txt   ("Hello, NFS world!\n")
//     /readme      (longer description)
//     ...everything users create on top
//
// Usage (no sudo required with the recommended option set below):
//   swift run NanoNFSDemo
//   mkdir -p ~/nanonfs_test
//   mount_nfs -o vers=4,port=14049,mountport=14049,tcp,rsize=1048576,wsize=1048576,dsize=1048576,actimeo=30,noatime,async \
//        127.0.0.1:/ ~/nanonfs_test
//   ls ~/nanonfs_test
//   echo hi > ~/nanonfs_test/test.txt
//   umount ~/nanonfs_test

actor DemoFS: NFSServer {
    private final class Entry {
        var fileid: UInt64
        var type: NFSObjectType
        var mode: UInt32
        var uid: UInt32
        var gid: UInt32
        var content: Data        // empty for directories
        var children: [String: NFSFileHandle]   // dir entries
        var parent: NFSFileHandle?
        var atime: NFSTime
        var mtime: NFSTime
        var ctime: NFSTime

        init(fileid: UInt64,
             type: NFSObjectType,
             mode: UInt32,
             uid: UInt32,
             gid: UInt32,
             content: Data,
             children: [String: NFSFileHandle],
             parent: NFSFileHandle?,
             atime: NFSTime,
             mtime: NFSTime,
             ctime: NFSTime) {
            self.fileid = fileid
            self.type = type
            self.mode = mode
            self.uid = uid
            self.gid = gid
            self.content = content
            self.children = children
            self.parent = parent
            self.atime = atime
            self.mtime = mtime
            self.ctime = ctime
        }
    }

    private var entries: [NFSFileHandle: Entry] = [:]
    private var nextID: UInt64 = 1
    private let writeVerifier: UInt64 = UInt64.random(in: 1...UInt64.max)

    private static let rootFh = NFSFileHandle(Data([0x00, 0x00, 0x00, 0x01]))

    init() {
        // Bootstrap: root, hello.txt, readme.
        let now = NFSTime.now()
        nextID = 2
        let helloFh = Self.makeHandle(2)
        nextID = 3
        let readmeFh = Self.makeHandle(3)

        entries[Self.rootFh] = Entry(
            fileid: 1, type: .directory, mode: 0o755, uid: 501, gid: 20,
            content: Data(), children: ["hello.txt": helloFh, "readme": readmeFh],
            parent: nil,
            atime: now, mtime: now, ctime: now
        )
        entries[helloFh] = Entry(
            fileid: 2, type: .regularFile, mode: 0o644, uid: 501, gid: 20,
            content: Data("Hello, NFS world!\n".utf8), children: [:],
            parent: Self.rootFh,
            atime: now, mtime: now, ctime: now
        )
        entries[readmeFh] = Entry(
            fileid: 3, type: .regularFile, mode: 0o644, uid: 501, gid: 20,
            content: Data("""
                nanonfs demo file system.

                Read, write, create, delete — everything is in-memory.
                Restart the demo to reset.

                """.utf8),
            children: [:],
            parent: Self.rootFh,
            atime: now, mtime: now, ctime: now
        )
    }

    private func mintHandle() -> NFSFileHandle {
        nextID &+= 1
        return Self.makeHandle(nextID)
    }

    private static func makeHandle(_ id: UInt64) -> NFSFileHandle {
        var bytes = Data(count: 8)
        bytes.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: id.bigEndian, as: UInt64.self)
        }
        return NFSFileHandle(bytes)
    }

    private func touch(_ handle: NFSFileHandle) {
        guard let e = entries[handle] else { return }
        let now = NFSTime.now()
        e.mtime = now
        e.ctime = now
    }

    private func stat(of handle: NFSFileHandle) throws -> NFSStat {
        guard let e = entries[handle] else { throw NFSError.badHandle }
        return NFSStat(
            type: e.type,
            mode: e.mode,
            nlink: e.type == .directory ? UInt32(2 + e.children.count) : 1,
            uid: e.uid,
            gid: e.gid,
            size: e.type == .directory ? UInt64(64 * (e.children.count + 2))
                                       : UInt64(e.content.count),
            used: e.type == .directory ? UInt64(64 * (e.children.count + 2))
                                       : UInt64(e.content.count),
            fileid: e.fileid,
            atime: e.atime, mtime: e.mtime, ctime: e.ctime
        )
    }

    // MARK: protocol

    func root() async throws -> NFSFileHandle { Self.rootFh }

    func access(handle: NFSFileHandle, mask: NFSAccess) async throws -> NFSAccess {
        // Demo grants everything the client asks about.
        return mask
    }

    func getattr(handle: NFSFileHandle) async throws -> NFSStat {
        try stat(of: handle)
    }

    func setattr(handle: NFSFileHandle, stateid: NFSStateID?, patch: NFSAttributesPatch) async throws -> NFSStat {
        guard let e = entries[handle] else { throw NFSError.badHandle }
        if let m = patch.mode { e.mode = m & 0xFFF }
        if let u = patch.uid { e.uid = u }
        if let g = patch.gid { e.gid = g }
        if let s = patch.size {
            guard e.type == .regularFile else { throw NFSError.isDirectory }
            let newSize = Int(s)
            if newSize < e.content.count {
                e.content.removeSubrange(newSize..<e.content.count)
            } else if newSize > e.content.count {
                e.content.reserveCapacity(newSize)
                e.content.append(contentsOf: repeatElement(UInt8(0), count: newSize - e.content.count))
            }
        }
        if let a = patch.atime { e.atime = a }
        if let m = patch.mtime { e.mtime = m }
        e.ctime = .now()
        return try stat(of: handle)
    }

    func lookup(parent: NFSFileHandle, name: String) async throws -> NFSFileHandle {
        guard let p = entries[parent] else { throw NFSError.badHandle }
        guard p.type == .directory else { throw NFSError.notDirectory }
        guard let child = p.children[name] else { throw NFSError.noEntry }
        return child
    }

    func lookupParent(of handle: NFSFileHandle) async throws -> NFSFileHandle {
        guard let e = entries[handle] else { throw NFSError.badHandle }
        return e.parent ?? Self.rootFh
    }

    func readdir(handle: NFSFileHandle, cookie: UInt64, cookieVerifier: UInt64,
                 maxEntries: Int) async throws -> NFSDirList {
        guard let e = entries[handle] else { throw NFSError.badHandle }
        guard e.type == .directory else { throw NFSError.notDirectory }
        let sortedChildren = e.children
            .compactMap { (name, fh) -> (name: String, fh: NFSFileHandle, entry: Entry)? in
                guard let child = entries[fh] else { return nil }
                return (name: name, fh: fh, entry: child)
            }
            .sorted { $0.name < $1.name }
        let startIndex: Int
        if cookie == 0 {
            startIndex = 0
        } else if let previous = sortedChildren.firstIndex(where: { $0.entry.fileid == cookie }) {
            startIndex = previous + 1
        } else {
            return NFSDirList(entries: [], nextCookie: nil, verifier: 1, eof: true)
        }

        let limit = max(1, maxEntries)
        let endIndex = min(startIndex + limit, sortedChildren.count)
        let batch = sortedChildren[startIndex..<endIndex]
        var out: [NFSDirEntry] = []
        out.reserveCapacity(batch.count)
        for child in batch {
            out.append(NFSDirEntry(
                fileid: child.entry.fileid,
                name: child.name,
                attrs: try? stat(of: child.fh),
                fileHandle: child.fh
            ))
        }
        let eof = endIndex >= sortedChildren.count
        let nextCookie = eof ? nil : out.last?.fileid
        return NFSDirList(entries: out, nextCookie: nextCookie, verifier: 1, eof: eof)
    }

    func create(parent: NFSFileHandle, name: String, type: NFSObjectType,
                attrs: NFSAttributesPatch) async throws -> NFSFileHandle {
        guard let p = entries[parent], p.type == .directory else {
            throw NFSError.notDirectory
        }
        if p.children[name] != nil { throw NFSError.exists }
        let now = NFSTime.now()
        let fh = mintHandle()
        let newEntry = Entry(
            fileid: nextID,
            type: type,
            mode: attrs.mode ?? (type == .directory ? 0o755 : 0o644),
            uid: attrs.uid ?? 501,
            gid: attrs.gid ?? 20,
            content: Data(),
            children: [:],
            parent: parent,
            atime: now, mtime: now, ctime: now
        )
        entries[fh] = newEntry
        p.children[name] = fh
        p.mtime = now; p.ctime = now
        return fh
    }

    func remove(parent: NFSFileHandle, name: String) async throws {
        guard let p = entries[parent], p.type == .directory else {
            throw NFSError.notDirectory
        }
        guard let fh = p.children[name], let target = entries[fh] else {
            throw NFSError.noEntry
        }
        if target.type == .directory && !target.children.isEmpty {
            throw NFSError.notEmpty
        }
        entries.removeValue(forKey: fh)
        p.children.removeValue(forKey: name)
        let now = NFSTime.now()
        p.mtime = now; p.ctime = now
    }

    func rename(srcParent: NFSFileHandle, srcName: String,
                dstParent: NFSFileHandle, dstName: String) async throws {
        guard let src = entries[srcParent], src.type == .directory else {
            throw NFSError.notDirectory
        }
        guard let fh = src.children[srcName] else { throw NFSError.noEntry }

        // Source == destination directory: just rename within.
        if srcParent == dstParent {
            // If destination already exists and is a non-empty dir, the
            // RFC requires NFS4ERR_EXIST. Files are silently replaced.
            if let oldDst = src.children[dstName], let target = entries[oldDst] {
                if target.type == .directory && !target.children.isEmpty {
                    throw NFSError.exists
                }
                entries.removeValue(forKey: oldDst)
            }
            src.children.removeValue(forKey: srcName)
            src.children[dstName] = fh
            let now = NFSTime.now()
            src.mtime = now; src.ctime = now
            // Update child's parent pointer (unchanged but refresh ctime).
            if let childEntry = entries[fh] {
                childEntry.ctime = now
            }
            return
        }

        // Cross-directory move.
        guard let dst = entries[dstParent], dst.type == .directory else {
            throw NFSError.notDirectory
        }
        if let oldDst = dst.children[dstName], let target = entries[oldDst] {
            if target.type == .directory && !target.children.isEmpty {
                throw NFSError.exists
            }
            entries.removeValue(forKey: oldDst)
        }
        src.children.removeValue(forKey: srcName)
        dst.children[dstName] = fh
        let now = NFSTime.now()
        src.mtime = now; src.ctime = now
        dst.mtime = now; dst.ctime = now
        if let childEntry = entries[fh] {
            childEntry.parent = dstParent
            childEntry.ctime = now
        }
    }

    func link(target: NFSFileHandle, parent: NFSFileHandle, name: String) async throws {
        // Hard links not modelled in this demo (would require nlink tracking).
        throw NFSError.notSupported
    }

    func readlink(handle: NFSFileHandle) async throws -> String { throw NFSError.invalid }

    // MARK: stateful — OPEN family

    func open(parent: NFSFileHandle, name: String, share: NFSShareAccess, deny: NFSShareDeny,
              owner: NFSOpenOwner, wantDelegation: NFSDelegationHint,
              create: NFSCreateMode) async throws -> (handle: NFSFileHandle, result: NFSOpenResult) {
        guard let parentEntry = entries[parent], parentEntry.type == .directory else {
            throw NFSError.notDirectory
        }
        // Resolve / create the file.
        let fh: NFSFileHandle
        if let existing = parentEntry.children[name] {
            fh = existing
            switch create {
            case .open:
                break
            case .create(let patch):
                _ = try await setattr(handle: fh, stateid: nil, patch: patch)
            case .createExclusive:
                throw NFSError.exists
            }
        } else {
            switch create {
            case .open:
                throw NFSError.noEntry
            case .create(let patch):
                fh = try await self.create(parent: parent, name: name,
                                           type: .regularFile, attrs: patch)
            case .createExclusive:
                fh = try await self.create(parent: parent, name: name,
                                           type: .regularFile, attrs: NFSAttributesPatch())
            }
        }
        // Issue a stateid carrying the fileid in the high 8 bytes of `other`.
        var other = Data(count: 12)
        if let entry = entries[fh] {
            withUnsafeBytes(of: entry.fileid.bigEndian) { src in
                other.replaceSubrange(0..<8, with: Array(src))
            }
        }
        let stateid = NFSStateID(seqid: 1, other: other)
        return (fh, NFSOpenResult(stateid: stateid, rflags: [], delegation: .none))
    }

    func openConfirm(handle: NFSFileHandle, stateid: NFSStateID, seqid: UInt32) async throws -> NFSStateID {
        var s = stateid; s.seqid = seqid; return s
    }
    func openDowngrade(handle: NFSFileHandle, stateid: NFSStateID,
                       share: NFSShareAccess, deny: NFSShareDeny) async throws -> NFSStateID { stateid }
    func close(handle: NFSFileHandle, stateid: NFSStateID) async throws { /* no-op */ }

    // MARK: I/O

    func read(handle: NFSFileHandle, stateid: NFSStateID,
              offset: UInt64, count: Int) async throws -> NFSReadResult {
        guard let e = entries[handle], e.type == .regularFile else {
            throw NFSError.invalid
        }
        let off = Int(min(offset, UInt64(e.content.count)))
        let end = min(off + count, e.content.count)
        return NFSReadResult(data: e.content.subdata(in: off..<end), eof: end >= e.content.count)
    }

    func write(handle: NFSFileHandle, stateid: NFSStateID, offset: UInt64,
               stability: NFSWriteStability, data: Data) async throws -> NFSWriteResult {
        guard let e = entries[handle], e.type == .regularFile else {
            throw NFSError.invalid
        }
        let off = Int(offset)
        let end = off + data.count
        if e.content.count < end {
            e.content.reserveCapacity(end)
            e.content.append(contentsOf: repeatElement(UInt8(0), count: end - e.content.count))
        }
        e.content.replaceSubrange(off..<end, with: data)
        let now = NFSTime.now()
        e.mtime = now; e.ctime = now
        return NFSWriteResult(count: data.count, committed: stability,
                              writeVerifier: writeVerifier)
    }

    func commit(handle: NFSFileHandle, offset: UInt64, count: UInt64) async throws -> UInt64 {
        writeVerifier
    }

    // MARK: locking — grant everything (single-client demo)

    func lock(handle: NFSFileHandle, type: NFSLockType, range: NFSLockRange,
              owner: NFSLockOwner, reclaim: Bool, stateid: NFSStateID) async throws -> NFSStateID {
        NFSStateID(seqid: 1, other: Data(repeating: 0xCC, count: 12))
    }
    func lockTest(handle: NFSFileHandle, type: NFSLockType, range: NFSLockRange,
                  owner: NFSLockOwner) async throws -> NFSLockTestResult {
        NFSLockTestResult(outcome: .granted)
    }
    func unlock(handle: NFSFileHandle, range: NFSLockRange, stateid: NFSStateID) async throws -> NFSStateID {
        var s = stateid; s.seqid &+= 1; if s.seqid == 0 { s.seqid = 1 }; return s
    }
}

@main
struct NanoNFSDemo {
    static func main() async throws {
        var logger = Logger(label: "nanonfs.demo")
        // Show op-by-op debug output so failed COMPOUND ops are visible.
        if ProcessInfo.processInfo.environment["LOG_LEVEL"]?.lowercased() == "debug" {
            logger.logLevel = .debug
        } else {
            logger.logLevel = .info
        }

        let transportSelection = parseTransportArg(CommandLine.arguments)
        let transport = try resolveTransport(transportSelection, logger: logger)

        let listener = NFSServerListener(
            server: DemoFS(),
            bind: .loopback(port: 14049),
            transport: transport,
            logger: logger
        )
        logger.info("Demo NFS server starting on 127.0.0.1:14049 (in-memory R/W, transport=\(transportSelection.label))")
        logger.info("Mount with: mount_nfs -o vers=4,port=14049,mountport=14049,tcp,rsize=1048576,wsize=1048576,dsize=1048576,actimeo=30,noatime,async 127.0.0.1:/ ~/nanonfs_test")
        logger.info("Set LOG_LEVEL=debug to trace failing COMPOUND ops.")
        logger.info("Pick the transport with --transport=bsdSocket (default; always available) or --transport=nio (requires the NIO trait).")
        try await listener.run()
    }
}

private enum TransportSelection {
    case auto
    case nio
    case bsdSocket

    var label: String {
        switch self {
        case .auto: return "default"
        case .nio: return "nio"
        case .bsdSocket: return "bsdSocket"
        }
    }
}

private func parseTransportArg(_ argv: [String]) -> TransportSelection {
    for arg in argv.dropFirst() {
        if arg == "--transport=nio" { return .nio }
        if arg == "--transport=bsdSocket" || arg == "--transport=bsdsocket" { return .bsdSocket }
    }
    return .auto
}

private func resolveTransport(_ selection: TransportSelection, logger: Logger) throws -> NFSTransport {
    switch selection {
    case .auto:
        return .default
    case .nio:
        #if NIO
        return .nio()
        #else
        logger.error("--transport=nio requested but the NIO trait is disabled in this build.")
        throw DemoError.transportNotAvailable("nio")
        #endif
    case .bsdSocket:
        return .bsdSocket
    }
}

private enum DemoError: Error, CustomStringConvertible {
    case transportNotAvailable(String)

    var description: String {
        switch self {
        case .transportNotAvailable(let name):
            return "transport \(name) is not available in this build"
        }
    }
}
