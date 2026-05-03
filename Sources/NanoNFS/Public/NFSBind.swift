import Foundation

/// Listener bind configuration. The default is loopback-only; binding to an
/// external interface requires the explicit `external(host:port:)` constructor
/// because the package's stated scope is loopback NFS.
public struct NFSBind: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case loopback
        case external
    }

    public let host: String
    public let port: UInt16
    public let kind: Kind

    private init(host: String, port: UInt16, kind: Kind) {
        self.host = host
        self.port = port
        self.kind = kind
    }

    /// Loopback bind — picks `127.0.0.1` (IPv4) by default. Listener will warn
    /// if the host is not a recognised loopback literal.
    public static func loopback(port: UInt16 = 14049) -> NFSBind {
        NFSBind(host: "127.0.0.1", port: port, kind: .loopback)
    }

    /// Explicit external bind. The listener logs a warning at start.
    public static func external(host: String, port: UInt16) -> NFSBind {
        NFSBind(host: host, port: port, kind: .external)
    }
}
